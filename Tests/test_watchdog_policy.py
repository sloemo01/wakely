"""Compile and run the pure watchdog policy; no launchd, XPC, AppKit or file system.

The agent's real I/O (liveness file, sysctl, privileged connection) is never
touched here. The Swift test main exercises the decision table, process
identity, retry bounds and the record wire format, and the source assertions
keep the app writer, the read-side mirror, the agent entry point, the plist and
build.sh aligned with the contract this wave promised. The same structural pass
also pins the relaunch fix (launchctl kickstart, with no -k), the test-only
support-directory seam, the truthful launchd retry wording, and the safety
properties of Tests/crash_recovery_live.sh.
"""
from pathlib import Path
import os
import plistlib
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

policy = (root / "Watchdog/Policy.swift").read_text()
main = (root / "Watchdog/main.swift").read_text()
app_liveness = (root / "Sources/AppLiveness.swift").read_text()
app_delegate = (root / "Sources/AppDelegate.swift").read_text()
build = (root / "build.sh").read_text()
live_path = root / "Tests/crash_recovery_live.sh"
live = live_path.read_text()

# --- Purity and posture of the agent's policy/entry point --------------------

assert "import AppKit" not in policy, "Watchdog/Policy.swift must stay Foundation-only"
assert "import ServiceManagement" not in policy, (
    "Watchdog/Policy.swift must not depend on ServiceManagement"
)
assert "NSXPCConnection" not in policy, "Watchdog/Policy.swift must not open XPC connections"
assert "FileManager" not in policy, "Watchdog/Policy.swift must not touch the file system"
assert "Process()" not in policy and "Process(" not in policy.replace("sameProcess(", ""), (
    "Watchdog/Policy.swift must not spawn processes"
)

assert ".restoreSession" in main, "the watchdog must ask for the session-scoped restore"
assert not re.search(r"\.restoreAll\b", main), (
    "crash recovery must never use restoreAll (persistent settings are not session state)"
)
assert "options: .privileged" in main, "the daemon connection must use the privileged option"
assert "HelperService.machServiceName" in main
assert "WatchdogPolicy.pollInterval" in main and "Thread.sleep" in main, (
    "the agent must observe the recorded process instead of exiting while the app runs"
)
assert '"liveness.json"' in main or '"liveness.json"' in policy, (
    "the agent must read the liveness record"
)
assert "WatchdogPolicy.shouldGiveUp" in main, "the retry budget must be enforced in the agent"
assert "watchdog.log" in main, "the existing watchdog log must be kept"

# --- App writer vs agent reader: same JSON field set -------------------------

record_block = app_liveness.split("struct LivenessRecord", 1)[1].split("enum AppLiveness {", 1)[0]
marker_block = policy.split("struct LivenessMarker", 1)[1].split("struct WatchdogRetryState", 1)[0]
record_fields = set(re.findall(r"^\s+var (\w+):", record_block, re.MULTILINE))
marker_fields = set(re.findall(r"^\s+var (\w+):", marker_block, re.MULTILINE))
assert record_fields, "could not find LivenessRecord fields"
assert record_fields == marker_fields, (
    "LivenessRecord and the watchdog's LivenessMarker drifted: "
    f"{sorted(record_fields)} vs {sorted(marker_fields)}"
)
for field in ("schemaVersion", "pid", "processStartTime", "armed", "armedAt",
              "generation", "updatedAt"):
    assert field in record_fields, f"liveness record is missing {field}"

# --- App hookup --------------------------------------------------------------

assert "AppLiveness.beginIdle()" in app_delegate
assert "AppLiveness.sync(armed: engine.isArmed, armedAt: engine.armedAt)" in app_delegate, (
    "the engine state change must publish the armed state and arm time"
)
assert "AppLiveness.beginTermination()" in app_delegate
termination = app_delegate.split("func applicationShouldTerminate", 1)[1]
assert termination.index("AppLiveness.beginTermination()") < termination.index(
    "AppLiveness.clear()"
), "termination must freeze the record before the final clear"
assert termination.index("AppLiveness.clear()") < termination.index(
    "reply(toApplicationShouldTerminate: true)"
), "the clean-quit clear must happen before the termination reply"
assert "installHelperFromMenu" not in app_delegate, (
    "the dead administrator-install menu action must stay removed"
)
assert "if case .installed = HelperClient.shared.installState" in app_delegate, (
    "the agent may only be registered when the privileged helper is installed"
)
assert "AppLiveness.registerAgentIfNeeded(helperInstalled: true)" in app_delegate
assert "func processStartTime(pid: Int32) -> TimeInterval?" in app_liveness
assert "KERN_PROC_PID" in app_liveness and "p_starttime" in app_liveness, (
    "PID reuse must be rejected with the kernel process start time"
)
assert "SMAppService.agent(plistName: HelperService.agentPlistName)" in app_liveness
assert "case requiresApproval" in app_liveness and "case notFound" in app_liveness
for marker in ("O_EXCL", "rename(", "0o600", "S_IFLNK"):
    assert marker in app_liveness, f"liveness storage is missing {marker}"
assert '"watchdog-retries.json"' in app_liveness and '"watchdog-retries.json"' in main, (
    "the app must reset the same retry counter the watchdog enforces"
)
assert "resetWatchdogRetryCounterLocked()" in app_liveness, (
    "a new app launch must start a fresh crash-recovery budget"
)

# --- launchd relaunch gap: kickstart, never -k ------------------------------

assert "static func kickstartAgentIfNeeded()" in app_liveness, (
    "a clean agent exit is not restarted; the app must kickstart a fresh one"
)
kickstart_block = app_liveness.split("static func kickstartAgentIfNeeded()", 1)[1]
kickstart_block = kickstart_block.split("private static let kickstartTimeout", 1)[0]
assert "SMAppService.agent(plistName: HelperService.agentPlistName)" in kickstart_block, (
    "kickstart must only run for this app's own agent"
)
assert "guard state.isEnabled else" in kickstart_block, (
    "kickstart must require an enabled (approved) agent, not merely a registered one"
)
assert 'process.executableURL = URL(fileURLWithPath: "/bin/launchctl")' in kickstart_block
assert 'process.arguments = ["kickstart", target]' in kickstart_block, (
    "the agent is started with `launchctl kickstart`, with no other arguments"
)
assert not re.search(r'["\']-k["\']|--kill', kickstart_block), (
    "kickstart must never pass -k: it would kill a watcher that is already running"
)
assert 'let target = "gui/\\(getuid())/\\(HelperService.agentLabel)"' in kickstart_block, (
    "the kickstart target must be the per-user GUI domain of this agent label"
)
assert "Task.detached" in kickstart_block, "launch must not block on launchctl"
assert "terminationHandler" in kickstart_block and "kickstartTimeout" in kickstart_block
assert "process.terminate()" in kickstart_block, (
    "the launchctl request must be bounded so a wedged launchd cannot hang"
)
assert "treated as benign" in kickstart_block, (
    "a non-zero launchctl status (already running, approval withdrawn) is not a failure"
)

register_index = app_delegate.index("AppLiveness.registerAgentIfNeeded(helperInstalled: true)")
kickstart_index = app_delegate.index("AppLiveness.kickstartAgentIfNeeded()")
assert register_index < kickstart_index, (
    "the launch Task must register first, then kickstart the agent"
)

# Approval status stays honest: the log describes what SMAppService reports
# after registration, and requiresApproval is named as such.
register_block = app_liveness.split("static func registerAgentIfNeeded", 1)[1]
assert "registered but not enabled" in register_block and "Login Items" in register_block, (
    "requiresApproval must be reported as unapproved, not as a working agent"
)
assert "status = service.status" in register_block, (
    "registration must re-read the real status instead of assuming success"
)
assert "case .requiresApproval: return .requiresApproval" in app_liveness
assert "var isEnabled: Bool { self == .enabled }" in app_liveness

# --- Test-only support directory seam (never honoured by the app) ----------

assert "WAKELY_SUPPORT_DIR" in main, "the watchdog needs a test-only support-dir override"
assert 'ProcessInfo.processInfo.environment["WAKELY_SUPPORT_DIR"]' in main
assert 'override.hasPrefix("/")' in main, "the override must be an absolute path"
assert "test-only" in main, "the override must be documented as test-only"
support_block = main.split("private func supportDirectory() -> URL {", 1)[1].split("\n}", 1)[0]
assert support_block.index("WAKELY_SUPPORT_DIR") < support_block.index(
    ".applicationSupportDirectory"
), "a valid override must win over the production Application Support path"
assert ".applicationSupportDirectory" in support_block
assert '"Wakely"' in support_block, (
    "without the override the agent must still read the app's production directory"
)
assert "WAKELY_SUPPORT_DIR" not in app_liveness, (
    "the app must not honour the test-only override; production always uses Application Support"
)

# --- Truthful launchd retry wording -----------------------------------------

retry_log_lines = [line for line in main.splitlines() if "session restore failed:" in line]
assert retry_log_lines, "the watchdog must log restore failures"
assert any("ThrottleInterval" in line and "cap hint" in line for line in retry_log_lines), (
    "the retry log must name launchd's ThrottleInterval and call the exponential value a hint"
)
assert not any("next launchd retry in about" in line for line in retry_log_lines), (
    "the old misleading 'about Ns' retry wording must be gone"
)
assert "ThrottleInterval" in policy
assert "launchdThrottleInterval: TimeInterval = 10" in policy, (
    "the policy constant must mirror the plist's 10 second ThrottleInterval"
)
assert "real cadence" in main or "real retry cadence" in main

# --- Live crash-recovery script: safety and coverage -----------------------

assert live_path.is_file(), "Tests/crash_recovery_live.sh must exist"
assert os.access(live_path, os.X_OK), "Tests/crash_recovery_live.sh must be executable"
assert live.startswith("#!/bin/bash")
assert "set -euo pipefail" in live
assert "xcrun swiftc" in live and "-framework AppKit" in live and "-framework Foundation" in live
for source in ("Sources/HelperProtocol.swift", "Watchdog/Policy.swift", "Watchdog/main.swift"):
    assert source in live, f"the live test must compile {source} into the watchdog"
assert "WAKELY_SUPPORT_DIR" in live, "the live test must redirect the watchdog's support dir"
assert 'REAL_SUPPORT="${HOME}/Library/Application Support/Wakely"' in live
assert 'if [[ "$support" == "$REAL_SUPPORT" ]]' in live, (
    "the live test must refuse to run against the user's real support directory"
)
assert "CFFIXED_USER_HOME" in live, (
    "the live test needs a throwaway Foundation home in case the override regresses"
)
assert "mktemp -d" in live
assert "ps -o lstart=" in live and "KERN_PROC_PID" in live and "python3" in live, (
    "the record's start time must come from ps and be checked against the same sysctl code"
)
assert "SLEEP_PID=$!" in live, "the sleep pid must be recorded at launch"
assert "kill_sleep_verified" in live and "kill -9" in live
assert "pgrep -x WakelyHelper" in live and "REFUSING" in live, (
    "the live test must refuse to run Case A while a real helper could answer"
)
kill_block = live.split("kill_sleep_verified() {", 1)[1].split("\n}", 1)[0]
assert "process_matches" in kill_block, (
    "every SIGKILL must be preceded by a kernel start-time identity check"
)
assert kill_block.index("process_matches") < kill_block.index("kill -9")
assert not re.search(r"^\s*sudo\b", live, re.MULTILINE), "the live test must never use sudo"
assert not re.search(r"^\s*killall\b", live, re.MULTILINE)
assert not re.search(r"^\s*launchctl\b", live, re.MULTILINE), (
    "the live test must not install, kickstart or otherwise touch launchd jobs"
)
assert "CASE_DEADLINE=$((SECONDS + 30))" in live, "each case needs a 30 second budget"
assert "$(remaining_time)" in live
assert 'WAKELY_SUPPORT_DIR="relative-support"' in live and (
    "relative WAKELY_SUPPORT_DIR" in live
), "the live test must prove a relative override is rejected"
for label in ("A", "B", "C"):
    assert f"run_case {label} run_case_" in live
assert "printf 'CASE %s: PASS\\n'" in live and "printf 'CASE %s: FAIL\\n'" in live
assert "NOT exercised" in live and (
    "root helper daemon was not installed or running in a usable form" in live
), "the live test must state that the helper-side restore was not exercised"
assert live.index("RESULT:") < live.index("NOTE: the helper-side restore"), (
    "the no-helper caveat must be the final printed line"
)
note_line = [line for line in live.splitlines() if "NOTE:" in line and "NOT exercised" in line]
assert note_line and "never installs or starts it" in note_line[-1]

# --- launchd job -------------------------------------------------------------

agent = plistlib.loads((root / "Resources/dev.wakely.agent.plist").read_bytes())
assert agent["Label"] == "dev.wakely.agent"
assert agent["BundleProgram"] == "Contents/MacOS/WakelyWatchdog", (
    "BundleProgram must stay bundle-relative, never a user-writable absolute path"
)
assert not agent["BundleProgram"].startswith("/")
assert agent["RunAtLoad"] is True
assert agent["KeepAlive"] == {"SuccessfulExit": False}
assert agent["ThrottleInterval"] == 10
assert agent["AssociatedBundleIdentifiers"] == ["dev.wakely.app"]

assert "Watchdog/Policy.swift" in build, "build.sh must compile the watchdog policy"
assert re.search(
    r"Sources/HelperProtocol\.swift\s+Watchdog/Policy\.swift\s+Watchdog/main\.swift", build
), "build.sh watchdog compile line must include Policy.swift"

# --- Compiled policy tests ---------------------------------------------------

tests = r'''
import Darwin
import Foundation

var failures = 0

func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// 1. Complete decision table.
struct DecisionCase {
    let hasMarker: Bool
    let appAlive: Bool
    let armed: Bool
    let expected: WatchdogDecision
}

let table: [DecisionCase] = [
    DecisionCase(hasMarker: false, appAlive: false, armed: false, expected: .noMarker),
    DecisionCase(hasMarker: false, appAlive: false, armed: true, expected: .noMarker),
    DecisionCase(hasMarker: false, appAlive: true, armed: false, expected: .noMarker),
    DecisionCase(hasMarker: false, appAlive: true, armed: true, expected: .noMarker),
    DecisionCase(hasMarker: true, appAlive: true, armed: false, expected: .wait),
    DecisionCase(hasMarker: true, appAlive: true, armed: true, expected: .wait),
    DecisionCase(hasMarker: true, appAlive: false, armed: false, expected: .cleanExit),
    DecisionCase(hasMarker: true, appAlive: false, armed: true, expected: .restoreSession),
]
for item in table {
    let actual = WatchdogPolicy.decide(hasMarker: item.hasMarker,
                                       appAlive: item.appAlive,
                                       armed: item.armed)
    expect(actual == item.expected,
           "decide(hasMarker: \(item.hasMarker), appAlive: \(item.appAlive), armed: \(item.armed))")
}

// 2. Record decoding, round trip, tolerance and corruption.
let marker = LivenessMarker(pid: 4242,
                             processStartTime: 1_700_000_000.25,
                             armed: true,
                             armedAt: 1_700_000_001.5,
                             generation: 9,
                             updatedAt: 1_700_000_002.75)
let encoded = try! JSONEncoder().encode(marker)
let decoded = try! JSONDecoder().decode(LivenessMarker.self, from: encoded)
expect(decoded == marker, "record JSON round trip")
expect(WatchdogPolicy.readMarker(encoded) == .record(marker), "readMarker accepts a written record")
expect(WatchdogPolicy.readMarker(nil) == .absent, "missing data is absent, not corrupt")
expect(WatchdogPolicy.readMarker(Data()) == .corrupt, "empty data is corrupt")

let withUnknown = Data("""
{"schemaVersion":1,"pid":77,"processStartTime":123.5,"armed":true,"armedAt":124,
 "generation":2,"updatedAt":125,"futureField":{"nested":true},"extra":"ignored"}
""".utf8)
if case .record(let unknown) = WatchdogPolicy.readMarker(withUnknown) {
    expect(unknown.pid == 77 && unknown.armed && unknown.generation == 2,
           "unknown JSON fields are ignored")
    expect(WatchdogPolicy.decision(for: .record(unknown), appAlive: false) == .restoreSession,
           "armed record with the app gone restores")
    expect(WatchdogPolicy.decision(for: .record(unknown), appAlive: true) == .wait,
           "armed record with the app alive waits")
} else {
    expect(false, "unknown JSON fields are ignored")
}

let legacy = Data(#"{"schemaVersion":1,"pid":9,"armed":false}"#.utf8)
if case .record(let old) = WatchdogPolicy.readMarker(legacy) {
    expect(old.pid == 9 && old.armed == false, "legacy record without optional fields decodes")
    expect(old.processStartTime == nil, "legacy record has no start time")
    expect(old.generation == 0 && old.updatedAt == 0, "legacy record defaults")
    expect(WatchdogPolicy.decision(for: .record(old), appAlive: false) == .cleanExit,
           "unarmed legacy record with the app gone is a clean exit")
} else {
    expect(false, "legacy record without optional fields decodes")
}

expect(WatchdogPolicy.readMarker(Data(#"{"schemaVersion":2,"pid":1,"armed":true}"#.utf8)) == .corrupt,
       "a future schema version is corrupt, never guessed")
expect(WatchdogPolicy.readMarker(Data(#"{"schemaVersion":1,"pid":0,"armed":true}"#.utf8)) == .corrupt,
       "a non-positive pid is corrupt")
if case .record(let noStart) = WatchdogPolicy.readMarker(Data(#"{"schemaVersion":1,"pid":1,"armed":true}"#.utf8)) {
    expect(noStart.processStartTime == nil, "a migration record without a start time is readable")
    expect(noStart.armed, "a migration record keeps its armed flag")
} else {
    expect(false, "a migration record without a start time is readable")
}
expect(WatchdogPolicy.readMarker(Data(#"{"schemaVersion":1,"pid":"1","armed":true}"#.utf8)) == .corrupt,
       "wrong types are corrupt")
expect(WatchdogPolicy.readMarker(Data(#"{"pid":1,"arm"#.utf8)) == .corrupt,
       "truncated JSON is corrupt")

// Corrupt records are never success.
expect(WatchdogPolicy.decision(for: .corrupt, appAlive: false) == .restoreSession,
       "corrupt record with the app gone restores the session")
expect(WatchdogPolicy.decision(for: .corrupt, appAlive: true) == .wait,
       "corrupt record with a live instance waits")
expect(WatchdogPolicy.decision(for: .absent, appAlive: false) == .noMarker,
       "no record is noMarker")

// 3. Process identity and PID reuse.
expect(WatchdogPolicy.sameProcess(markerPID: 7, markerStart: 100, currentStart: 100.5),
       "same pid and start within one second")
expect(WatchdogPolicy.sameProcess(markerPID: 7, markerStart: 100, currentStart: 101.0),
       "exactly one second apart is accepted")
expect(!WatchdogPolicy.sameProcess(markerPID: 7, markerStart: 100, currentStart: 101.01),
       "more than one second apart is a different process")
expect(!WatchdogPolicy.sameProcess(markerPID: 7, markerStart: nil, currentStart: 100),
       "nil recorded start is never the same process")
expect(!WatchdogPolicy.sameProcess(markerPID: 7, markerStart: 100, currentStart: nil),
       "nil current start is never the same process")
expect(!WatchdogPolicy.sameProcess(markerPID: 7, markerStart: .nan, currentStart: 100),
       "not-a-number start is rejected")
expect(WatchdogPolicy.sameProcess(markerPID: 7, markerStart: 100, currentPID: 7, currentStart: 100.2),
       "pid and start agree")
expect(!WatchdogPolicy.sameProcess(markerPID: 7, markerStart: 100, currentPID: 8, currentStart: 100),
       "a reused pid is rejected even with a matching start time")

expect(WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: 100, livePID: 7, liveStart: 100.2),
       "live recorded instance")
expect(!WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: 100, livePID: 7, liveStart: 400),
       "pid reuse means the recorded instance is gone")
expect(!WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: 100, livePID: nil, liveStart: nil),
       "no live process means gone")
expect(!WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: 100, livePID: 8, liveStart: 100),
       "a different live pid means gone")
expect(WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: nil, livePID: 7, liveStart: 100),
       "unverifiable identity with a live pid fails safe to alive")
expect(!WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: nil, livePID: nil, liveStart: nil),
       "unverifiable identity becomes gone only with no live process")
expect(WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: 100, livePID: 7, liveStart: nil),
       "a live pid without a readable start fails safe to alive")
expect(!WatchdogPolicy.appInstanceAlive(markerPID: 7, markerStart: 100, livePID: 7, liveStart: 400),
       "a readable but different start is a reused pid, not the recorded instance")

// 4. Retry budget.
let delays: [TimeInterval] = [2, 4, 8, 16, 32, 60]
for (index, expected) in delays.enumerated() {
    let failures = index + 1
    expect(WatchdogPolicy.nextRetryDelay(failures: failures) == expected,
           "retry delay for \(failures) failure(s)")
}
expect(WatchdogPolicy.nextRetryDelay(failures: 0) == 2, "zero failures starts at the initial delay")
expect(WatchdogPolicy.nextRetryDelay(failures: -3) == 2, "negative failures start at the initial delay")
expect(WatchdogPolicy.nextRetryDelay(failures: 7) == 60, "the delay is capped at 60 seconds")
expect(WatchdogPolicy.nextRetryDelay(failures: 1000) == 60, "the cap is global")
expect(WatchdogPolicy.maximumRestoreFailures == 6, "six attempts per crash episode")
expect(!WatchdogPolicy.shouldGiveUp(failures: 0), "no give-up before any failure")
expect(!WatchdogPolicy.shouldGiveUp(failures: 5), "no give-up on the fifth failure")
expect(WatchdogPolicy.shouldGiveUp(failures: 6), "give up on the sixth failure")
expect(WatchdogPolicy.shouldGiveUp(failures: 1000), "give-up is monotonic")
expect(WatchdogPolicy.launchdThrottleInterval == 10,
       "the launchd retry constant mirrors the plist's ThrottleInterval")

// 5. Retry counter wire format.
let retry = WatchdogRetryState(failures: 4, updatedAt: 111)
let retryData = try! JSONEncoder().encode(retry)
expect((try? JSONDecoder().decode(WatchdogRetryState.self, from: retryData)) == retry,
       "retry counter round trip")
let legacyRetry = Data(#"{"failures":2}"#.utf8)
let oldRetry = try? JSONDecoder().decode(WatchdogRetryState.self, from: legacyRetry)
expect(oldRetry?.schemaVersion == 1 && oldRetry?.failures == 2,
       "retry counter migration defaults")
expect((try? JSONDecoder().decode(WatchdogRetryState.self,
                                  from: Data(#"{"failures":1,"future":true}"#.utf8)))?.failures == 1,
       "retry counter ignores unknown fields")
expect((try? JSONDecoder().decode(WatchdogRetryState.self, from: Data("not json".utf8))) == nil,
       "a corrupt retry counter is detected")

// 6. Agent cadence and timeout are bounded.
expect(WatchdogPolicy.pollInterval == 1, "one-second observation cadence")
expect(WatchdogPolicy.restoreTimeout == 8, "bounded helper timeout")

if failures > 0 {
    print("\(failures) watchdog policy test(s) failed")
    exit(1)
}
print("all watchdog policy tests passed")
'''

with tempfile.TemporaryDirectory(prefix="wakely-watchdog-tests-") as directory:
    work = Path(directory)
    swift_main = work / "main.swift"   # top-level code needs this file name
    swift_main.write_text(tests)
    binary = work / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
        str(root / "Watchdog/Policy.swift"), str(swift_main),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
