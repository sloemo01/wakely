#!/bin/bash
# Live crash-recovery test for the per-user watchdog (Watchdog/main.swift).
#
# This runs the *real* agent binary against a *real* dying process, on purpose:
# unit tests cover the decision table, but only a killed process proves that the
# kernel identity check, the observation loop, the restore attempt and the exit
# status line up. Three cases:
#
#   A. unclean death while armed  -> notices the death, attempts restoreSession,
#                                    logs the failure (no usable helper), exits
#                                    1, keeps the marker so launchd retries.
#   B. clean clear while alive    -> exits 0 and never asks for a restore.
#   C. no liveness record         -> exits 0 immediately and says so.
#
# Safety posture, in order of importance:
#   * The agent's support directory is redirected with the test-only
#     WAKELY_SUPPORT_DIR seam (Watchdog/main.swift). The production
#     ~/Library/Application Support/Wakely is never used.
#   * If that seam ever regressed, CFFIXED_USER_HOME/HOME point the Foundation
#     fallback at a throwaway "home" inside the temp tree, so the fallback still
#     cannot reach the user's real Application Support data.
#   * Only /bin/sleep processes started here are killed. The PID is captured at
#     launch and its kernel start time is re-checked immediately before every
#     SIGKILL; a mismatch aborts instead of signalling.
#   * No sudo, no launchctl, no helper installation, no system setting change,
#     no signal to any app the test did not start.
#   * Each case has a 30 second budget and cleans up after itself.
#
# What this cannot prove: no privileged helper can answer here. Nothing starts
# a usable root daemon, so the restore attempt always fails. An SMAppService job
# may still be registered from earlier work and may fail to spawn; either way the
# helper-side restore itself is NOT exercised.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CACHE="${WAKELY_BUILD_CACHE:-$HOME/Library/Caches/Wakely/build}"
mkdir -p "$BUILD_CACHE"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wakely-crash-recovery.XXXXXX")"
WATCHDOG="$WORK/WakelyWatchdog-live"
STARTTIME="$WORK/starttime"
REAL_SUPPORT="${HOME}/Library/Application Support/Wakely"

export LC_ALL=C
export TZ=UTC

FAILURES=0
CASE_OK=1
CASE_DEADLINE=0
CASE_HOME=""
WATCHDOG_PID=""
SLEEP_PID=""
SLEEP_START=""
# The sleep process is only ever signalled while it is still this script's
# unreaped child: a PID cannot be reused until the child is reaped, so the
# identity re-check below is a second belt rather than the only one.
SLEEP_REAPED=0
REAPED_STATUS=0

note() { printf '  %s\n' "$*"; }
fail() { CASE_OK=0; printf '  FAIL: %s\n' "$*"; }

# ---------------------------------------------------------------------------
# Cleanup: only ever the two PIDs this script captured, and the sleep process
# only while its kernel start time still matches the one recorded at launch.
# ---------------------------------------------------------------------------

process_matches() { # pid expected_start_epoch
    local pid="$1" expected="${2:-}" current
    [[ -n "$expected" ]] || return 1
    [[ -x "$STARTTIME" ]] || return 1
    current="$("$STARTTIME" "$pid" 2>/dev/null)" || return 1
    python3 -c 'import sys
sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= 1.0 else 1)' \
        "$expected" "$current" 2>/dev/null
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n "$WATCHDOG_PID" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        # Still our unreaped child, so this cannot hit a reused PID.
        kill "$WATCHDOG_PID" 2>/dev/null
        wait "$WATCHDOG_PID" 2>/dev/null
    fi
    if [[ -n "$SLEEP_PID" ]] && [[ "$SLEEP_REAPED" == 0 ]] \
        && kill -0 "$SLEEP_PID" 2>/dev/null; then
        if process_matches "$SLEEP_PID" "${SLEEP_START:-}"; then
            kill -9 "$SLEEP_PID" 2>/dev/null
            wait "$SLEEP_PID" 2>/dev/null
        fi
    fi
    rm -rf "$WORK"
    exit "$status"
}
trap cleanup EXIT INT TERM

# Case A deliberately drives the real privileged path. If a helper process is
# somehow running, its restoreSession would change session settings, which this
# test must never cause. Refuse instead; stopping the helper is not this test's
# job (it never uses launchctl or sudo).
if pgrep -x WakelyHelper >/dev/null 2>&1; then
    printf 'REFUSING: a WakelyHelper process is running; Case A could perform a real privileged restore.\n' >&2
    printf 'This test only runs where the helper cannot answer; it never stops the helper itself.\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build the agent exactly the way build.sh does, plus a tiny kernel-start-time
# tool that shares the agent's sysctl code (used for verification and as the
# fallback writer described in the task).
# ---------------------------------------------------------------------------

printf '== compiling the watchdog into %s\n' "$WORK"
if ! xcrun swiftc \
    -swift-version 5 \
    -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_CACHE" \
    -framework AppKit \
    -framework Foundation \
    -o "$WATCHDOG" \
    "$ROOT/Sources/HelperProtocol.swift" \
    "$ROOT/Watchdog/Policy.swift" \
    "$ROOT/Watchdog/main.swift"; then
    printf 'FAIL: could not compile the watchdog\n' >&2
    exit 1
fi

cat > "$WORK/starttime.swift" <<'SWIFT'
import Darwin
import Foundation

// Same KERN_PROC_PID / p_starttime query as Sources/AppLiveness.swift and
// Watchdog/main.swift. Printed with microsecond precision so the JSON record
// carries the kernel's own value.
let arguments = CommandLine.arguments
guard arguments.count == 2, let pid = Int32(arguments[1]), pid > 0 else {
    FileHandle.standardError.write(Data("usage: starttime <pid>\n".utf8))
    exit(2)
}
var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
var info = kinfo_proc()
var size = MemoryLayout<kinfo_proc>.stride
let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
    guard let base = buffer.baseAddress else { return -1 }
    return sysctl(base, u_int(buffer.count), &info, &size, nil, 0)
}
guard result == 0,
      size >= MemoryLayout<kinfo_proc>.stride,
      info.kp_proc.p_pid == pid else { exit(1) }
let start = info.kp_proc.p_starttime
guard start.tv_sec > 0 else { exit(1) }
print(String(format: "%.6f",
             TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000))
SWIFT

if ! xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_CACHE" \
    -o "$STARTTIME" "$WORK/starttime.swift"; then
    printf 'FAIL: could not compile the start-time helper\n' >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

remaining_time() {
    local left=$((CASE_DEADLINE - SECONDS))
    if (( left < 1 )); then left=1; fi
    printf '%s' "$left"
}

file_contains() { # file needle
    [[ -f "$1" ]] && grep -Fq -- "$2" "$1"
}

assert_contains() { # file needle label
    if file_contains "$1" "$2"; then
        note "ok: $3"
    else
        fail "$3 (missing: $2)"
    fi
}

assert_not_contains() { # file needle label
    if file_contains "$1" "$2"; then
        fail "$3 (unexpected: $2)"
    else
        note "ok: $3"
    fi
}

assert_status() { # actual expected label
    if [[ "$1" == "$2" ]]; then
        note "ok: $3 (exit $1)"
    else
        fail "$3 (exit $1, expected $2)"
    fi
}

dump_log() { # log
    local log="$1"
    if [[ -f "$log" ]]; then
        printf '  --- %s (tail) ---\n' "$log"
        tail -n 15 "$log" | sed 's/^/  /'
        printf '  --- end log ---\n'
    else
        printf '  (no watchdog log at %s)\n' "$log"
    fi
}

wait_for_log() { # file needle timeout label
    local file="$1" needle="$2" timeout="$3" label="$4" i steps
    steps=$(( timeout * 10 ))
    for ((i = 0; i < steps; i++)); do
        if file_contains "$file" "$needle"; then
            note "ok: $label"
            return 0
        fi
        sleep 0.1
    done
    fail "$label (timed out after ${timeout}s)"
    return 1
}

wait_for_exit() { # pid timeout label
    local pid="$1" timeout="$2" label="$3" i steps state
    steps=$(( timeout * 10 ))
    for ((i = 0; i < steps; i++)); do
        state="$(ps -o state= -p "$pid" 2>/dev/null)" || state=""
        if [[ -z "${state// /}" || "$state" == Z* ]]; then
            note "ok: $label"
            return 0
        fi
        sleep 0.1
    done
    fail "$label (still running after ${timeout}s)"
    return 1
}

reap_status() { # pid -> fills REAPED_STATUS for the caller's shell
    REAPED_STATUS=0
    set +e
    wait "$1"
    REAPED_STATUS=$?
    set -e
}

# The app records the kernel start time; `ps -o lstart=` only has second
# resolution, so it must be within 1 s of the sysctl value before it is trusted.
# If it is not (or ps cannot report), fall back to the sysctl value itself.
ps_start_epoch() { # pid -> epoch seconds on stdout
    local pid="$1" raw
    raw="$(ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
    [[ -n "${raw// /}" ]] || return 1
    python3 - "$raw" <<'PY'
import datetime
import sys

raw = " ".join(sys.argv[1].split())
try:
    moment = datetime.datetime.strptime(raw, "%a %b %d %H:%M:%S %Y")
except ValueError:
    sys.exit(1)
print(f"{moment.timestamp():.6f}")
PY
}

resolve_start_time() { # pid -> "ps <epoch>" or "sysctl <epoch>"
    local pid="$1" kernel ps_epoch
    kernel="$("$STARTTIME" "$pid")" || { printf 'error 0\n'; return 1; }
    if ps_epoch="$(ps_start_epoch "$pid")"; then
        if python3 -c 'import sys
sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) <= 1.0 else 1)' \
            "$ps_epoch" "$kernel"; then
            printf 'ps %s\n' "$ps_epoch"
            return 0
        fi
    fi
    printf 'sysctl %s\n' "$kernel"
}

write_marker() { # path pid start_epoch generation
    python3 - "$@" <<'PY'
import json
import os
import sys
import time

path, pid, start, generation = (
    sys.argv[1],
    int(sys.argv[2]),
    float(sys.argv[3]),
    int(sys.argv[4]),
)
now = time.time()
record = {
    "schemaVersion": 1,
    "pid": pid,
    "processStartTime": start,
    "armed": True,
    "armedAt": now,
    "generation": generation,
    "updatedAt": now,
}
temporary = path + ".tmp"
with open(temporary, "w", encoding="utf-8") as handle:
    json.dump(record, handle, sort_keys=True)
os.chmod(temporary, 0o600)
os.replace(temporary, path)
PY
}

start_watchdog() { # support_dir case_dir
    local support="$1" case_dir="$2"
    if [[ "$support" == "$REAL_SUPPORT" ]]; then
        fail "refusing to run against the real support directory"
        return 1
    fi
    # WAKELY_SUPPORT_DIR is the seam under test; CFFIXED_USER_HOME/HOME are
    # the damage limiter if the seam ever regresses.
    WAKELY_SUPPORT_DIR="$support" \
    CFFIXED_USER_HOME="$CASE_HOME" \
    HOME="$CASE_HOME" \
        "$WATCHDOG" >"$case_dir/watchdog.out" 2>&1 &
    WATCHDOG_PID=$!
}

start_sleep() { # sets SLEEP_PID and SLEEP_START
    /bin/sleep 120 &
    SLEEP_PID=$!
    SLEEP_REAPED=0
    local resolved="" attempt
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if resolved="$(resolve_start_time "$SLEEP_PID" 2>/dev/null)"; then
            break
        fi
        resolved=""
        sleep 0.1
    done
    if [[ -z "$resolved" ]]; then
        fail "could not read the start time of sleep pid $SLEEP_PID"
        return 1
    fi
    local mode="${resolved%% *}"
    local start="${resolved#* }"
    if [[ "$mode" == "error" ]]; then
        fail "could not read the start time of sleep pid $SLEEP_PID"
        return 1
    fi
    SLEEP_START="$start"
    note "sleep pid $SLEEP_PID start $SLEEP_START (source: $mode)"
}

kill_sleep_verified() { # label
    local label="$1"
    if ! process_matches "$SLEEP_PID" "$SLEEP_START"; then
        fail "refusing to signal pid $SLEEP_PID ($label): kernel start time no longer matches"
        return 1
    fi
    kill -9 "$SLEEP_PID"
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_REAPED=1
    SLEEP_PID=""
    note "ok: SIGKILL sent to the recorded sleep process ($label)"
}

# ---------------------------------------------------------------------------
# Case A — the app dies unclean while the session is armed; no helper exists.
# ---------------------------------------------------------------------------

run_case_a() {
    local case_dir="$WORK/case-a"
    local support="$case_dir/support"
    local log="$support/watchdog.log"
    mkdir -p "$case_dir" "$support"
    chmod 700 "$support"
    CASE_HOME="$case_dir/home"
    mkdir -p "$CASE_HOME"

    printf '\n== CASE A: unclean death with an armed session (helper absent)\n'
    if ! start_sleep; then return 1; fi
    if ! write_marker "$support/liveness.json" "$SLEEP_PID" "$SLEEP_START" 1; then
        fail "could not write the liveness record"
        return 1
    fi
    note "wrote liveness.json for pid $SLEEP_PID into the throwaway support dir"

    if ! start_watchdog "$support" "$case_dir"; then return 1; fi
    if ! wait_for_log "$log" "watching app pid $SLEEP_PID" "$(remaining_time)" \
        "agent announced it is watching the recorded process"; then
        dump_log "$log"
        return 1
    fi

    # Re-verify identity immediately before the signal. The window between this
    # check and kill(2) is the one unavoidable race; see the report.
    if ! kill_sleep_verified "case A"; then
        dump_log "$log"
        return 1
    fi

    if ! wait_for_exit "$WATCHDOG_PID" "$(remaining_time)" \
        "agent exited after the recorded process died"; then
        dump_log "$log"
        return 1
    fi
    reap_status "$WATCHDOG_PID"
    local status="$REAPED_STATUS"
    WATCHDOG_PID=""

    assert_status "$status" 1 "unclean death exits 1 so launchd retries"
    assert_contains "$log" "is gone with an armed session" \
        "agent noticed the recorded pid died"
    assert_contains "$log" "restoring session-scoped settings" \
        "agent attempted the session-scoped restore"
    assert_contains "$log" "session restore failed:" \
        "the failed restore was logged"
    assert_contains "$log" "ThrottleInterval" \
        "retry log names launchd's real retry cadence"
    assert_not_contains "$log" "settings restored:" \
        "the absent helper was not reported as a successful restore"

    if [[ -f "$support/liveness.json" ]]; then
        note "ok: the liveness record was left in place for launchd's retry"
    else
        fail "the liveness record was removed after a failed restore"
    fi
    if python3 -c 'import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    sys.exit(0 if json.load(handle).get("failures") == 1 else 1)' \
        "$support/watchdog-retries.json" 2>/dev/null; then
        note "ok: the retry counter recorded exactly one failed attempt"
    else
        fail "the retry counter is missing or does not record one failure"
    fi

    printf '  --- case A log ---\n'
    sed 's/^/  /' "$log"
    printf '  --- end case A log ---\n'
}

# ---------------------------------------------------------------------------
# Case B — the app clears the record while it is still alive (clean path).
# ---------------------------------------------------------------------------

run_case_b() {
    local case_dir="$WORK/case-b"
    local support="$case_dir/support"
    local log="$support/watchdog.log"
    mkdir -p "$case_dir" "$support"
    chmod 700 "$support"
    CASE_HOME="$case_dir/home"
    mkdir -p "$CASE_HOME"

    printf '\n== CASE B: clean clear while the recorded process is alive\n'
    if ! start_sleep; then return 1; fi
    if ! write_marker "$support/liveness.json" "$SLEEP_PID" "$SLEEP_START" 2; then
        fail "could not write the liveness record"
        return 1
    fi

    if ! start_watchdog "$support" "$case_dir"; then return 1; fi
    if ! wait_for_log "$log" "watching app pid $SLEEP_PID" "$(remaining_time)" \
        "agent announced it is watching the recorded process"; then
        dump_log "$log"
        return 1
    fi

    if ! process_matches "$SLEEP_PID" "$SLEEP_START"; then
        fail "recorded sleep pid changed identity before the clean clear"
        return 1
    fi
    if ! rm -f "$support/liveness.json"; then
        fail "could not remove the liveness record"
        return 1
    fi
    note "removed the liveness record while pid $SLEEP_PID is still alive"

    if ! wait_for_exit "$WATCHDOG_PID" "$(remaining_time)" \
        "agent exited after the record was cleared"; then
        dump_log "$log"
        return 1
    fi
    reap_status "$WATCHDOG_PID"
    local status="$REAPED_STATUS"
    WATCHDOG_PID=""

    assert_status "$status" 0 "a cleared record is a clean exit"
    assert_contains "$log" "liveness record cleared" \
        "agent logged the clean clear"
    assert_not_contains "$log" "restoring session-scoped settings" \
        "no restore was attempted for a clean clear"
    assert_not_contains "$log" "session restore failed:" \
        "no restore failure was logged for a clean clear"
    assert_not_contains "$log" "is gone with an armed session" \
        "the live process was not treated as dead"

    if [[ -f "$support/liveness.json" ]]; then
        fail "the removed liveness record reappeared"
    else
        note "ok: no liveness record was left behind"
    fi

    # The app is still running: prove the agent did not wait for it to die.
    if process_matches "$SLEEP_PID" "$SLEEP_START"; then
        note "ok: the recorded process was still alive when the agent exited"
    else
        fail "the recorded process died on its own; the clean-clear timing is invalid"
    fi
    kill_sleep_verified "case B cleanup" || true

    printf '  --- case B log ---\n'
    sed 's/^/  /' "$log"
    printf '  --- end case B log ---\n'
}

# ---------------------------------------------------------------------------
# Case C — there is nothing to watch; the agent must not invent work.
# ---------------------------------------------------------------------------

run_case_c() {
    local case_dir="$WORK/case-c"
    local support="$case_dir/support"
    local log="$support/watchdog.log"
    mkdir -p "$case_dir" "$support"
    chmod 700 "$support"
    CASE_HOME="$case_dir/home"
    mkdir -p "$CASE_HOME"

    printf '\n== CASE C: no liveness record\n'
    if ! start_watchdog "$support" "$case_dir"; then return 1; fi
    if ! wait_for_exit "$WATCHDOG_PID" "$(remaining_time)" \
        "agent exited with no record to observe"; then
        dump_log "$log"
        return 1
    fi
    reap_status "$WATCHDOG_PID"
    local status="$REAPED_STATUS"
    WATCHDOG_PID=""

    assert_status "$status" 0 "no record is an immediate clean exit"
    assert_contains "$log" "no liveness record" \
        "agent said there was no liveness record"
    assert_not_contains "$log" "session restore failed:" \
        "no restore was attempted without a record"

    # Seam check: WAKELY_SUPPORT_DIR accepts absolute paths only. A relative
    # value must be rejected outright, not resolved against the current
    # directory. The Foundation fallback is CASE_HOME, so this probe is still
    # confined to the temp tree. The probe is time-bounded like every other
    # launch and is a direct child, so it is safe to stop if it ever hangs.
    local probe_dir="$case_dir/probe"
    mkdir -p "$probe_dir"
    local probe_pid=0
    local probe_status=0
    local previous_dir="$PWD"
    cd "$probe_dir"
    WAKELY_SUPPORT_DIR="relative-support" \
    CFFIXED_USER_HOME="$CASE_HOME" \
    HOME="$CASE_HOME" \
        "$WATCHDOG" >"$probe_dir/out.log" 2>&1 &
    probe_pid=$!
    cd "$previous_dir"
    if wait_for_exit "$probe_pid" 5 "relative-override probe exited"; then
        reap_status "$probe_pid"
        probe_status="$REAPED_STATUS"
    else
        kill "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
        probe_status=124
    fi
    assert_status "$probe_status" 0 "a relative override is ignored, not fatal"
    if [[ -e "$probe_dir/relative-support" ]]; then
        fail "a relative WAKELY_SUPPORT_DIR was resolved against the current directory"
    else
        note "ok: a relative WAKELY_SUPPORT_DIR was rejected"
    fi
    local fallback_log="$CASE_HOME/Library/Application Support/Wakely/watchdog.log"
    if file_contains "$fallback_log" "no liveness record"; then
        note "ok: the rejected override fell back to the (throwaway) Application Support path"
    else
        fail "the rejected override did not fall back to the Application Support path"
    fi

    printf '  --- case C log ---\n'
    sed 's/^/  /' "$log"
    printf '  --- end case C log ---\n'
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

run_case() { # label function
    local label="$1" function="$2" status=0
    CASE_OK=1
    CASE_DEADLINE=$((SECONDS + 30))
    set +e
    "$function"
    status=$?
    set -e
    if (( status != 0 )); then
        CASE_OK=0
    fi
    if (( CASE_OK == 1 )); then
        printf 'CASE %s: PASS\n' "$label"
    else
        FAILURES=$((FAILURES + 1))
        printf 'CASE %s: FAIL\n' "$label"
    fi
    # Drop leftovers before the next case. Cleanup re-checks the sleep identity.
    if [[ -n "$WATCHDOG_PID" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
    WATCHDOG_PID=""
    if [[ -n "$SLEEP_PID" ]] && [[ "$SLEEP_REAPED" == 0 ]] \
        && kill -0 "$SLEEP_PID" 2>/dev/null; then
        if process_matches "$SLEEP_PID" "${SLEEP_START:-}"; then
            kill -9 "$SLEEP_PID" 2>/dev/null || true
            wait "$SLEEP_PID" 2>/dev/null || true
        fi
    fi
    SLEEP_PID=""
    SLEEP_START=""
    SLEEP_REAPED=0
}

printf '== wakely watchdog crash-recovery live test\n'

run_case A run_case_a
run_case B run_case_b
run_case C run_case_c

printf '\n'
if (( FAILURES == 0 )); then
    printf 'RESULT: all 3 live crash-recovery cases passed\n'
else
    printf 'RESULT: %d live crash-recovery case(s) failed\n' "$FAILURES"
fi
printf 'NOTE: the helper-side restore itself was NOT exercised: the root helper daemon was not installed or running in a usable form on this Mac, this test never installs or starts it, and no privileged restore was performed.\n'

if (( FAILURES != 0 )); then
    exit 1
fi
