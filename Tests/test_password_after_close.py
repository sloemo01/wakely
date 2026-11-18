#!/usr/bin/env python3
"""Structural checks for the Password After Close lifecycle (M5).

These are source-shape checks, not behaviour tests: the behaviour matrix lives in
Tests/PasswordAfterClosePolicyTests.swift, which links the pure policy alone.
Nothing here launches the app, reads the live session, calls a helper, invokes
bioutil, or touches Touch ID. Forbidden API names are assembled from fragments so
this file does not itself contain the literals it forbids.
"""
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
sources = root / "Sources"
tests = root / "Tests"

failures = []


def check(condition: bool, message: str) -> None:
    if condition:
        print(f"PASS: {message}")
    else:
        print(f"FAIL: {message}")
        failures.append(message)


def swift_source(path: Path) -> str:
    """Read Swift with comments removed; enough for brace-balanced extraction."""
    text = path.read_text()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def block(source: str, marker: str) -> str:
    """Return the brace-balanced declaration starting at `marker`."""
    at = source.index(marker)
    start = source.index("{", at)
    depth = 0
    for index in range(start, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[at:index + 1]
    raise AssertionError(f"unbalanced block at {marker!r}")


def body(source: str, signature: str) -> str:
    return block(source, signature)


policy_path = sources / "PasswordAfterClosePolicy.swift"
observer_path = sources / "ScreenLockObserver.swift"
behaviors_path = sources / "ComponentBehaviors.swift"
power_path = sources / "PowerEngine.swift"
delegate_path = sources / "AppDelegate.swift"
policy_tests = tests / "PasswordAfterClosePolicyTests.swift"

for path in (policy_path, observer_path, behaviors_path, power_path, delegate_path,
             policy_tests):
    check(path.is_file() and path.stat().st_size > 0, f"{path.name} exists and is not empty")

policy = swift_source(policy_path)
observer = swift_source(observer_path)
behaviors = swift_source(behaviors_path)
power = swift_source(power_path)
delegate = swift_source(delegate_path)
policy_tests_text = swift_source(policy_tests)

# --- The pure policy owns the state machine -------------------------------

required_phases = [
    "case idle",
    "case turnOffPending(closeID: UUID)",
    "case off(closeID: UUID)",
    "case restorePending(closeID: UUID)",
]
for phase in required_phases:
    check(phase in policy, f"phase declared: {phase}")

required_predicates = [
    "func shouldTurnOff(componentEnabled: Bool, externalDisplay: Bool) -> Bool",
    "func shouldRestoreOnUnlock(phase: Phase) -> Bool",
    "func shouldRestoreOnLidOpen(isLocked: Bool?, phase: Phase) -> Bool",
    "func shouldRestoreOnWake(isLocked: Bool?, phase: Phase) -> Bool",
    "func shouldRestoreOnQuit(phase: Phase) -> Bool",
    "func shouldRestoreOnDisable(phase: Phase) -> Bool",
    "func shouldCancelLateTurnOff(unlockedSinceClose: Bool, phase: Phase) -> Bool",
    "func shouldRetryTurnOff(lidClosed: Bool, isLocked: Bool?, helperReachable: Bool,",
]
for signature in required_predicates:
    check(signature in policy, f"policy predicate present: {signature.split('(')[0]}")

check("componentEnabled && !externalDisplay" in policy,
      "close gate is enabled && no external display")
check("guard isLocked == false else { return false }" in policy,
      "lid-open and wake restoration require a proven unlocked screen")
check("unlockedSinceClose && Self.isTurnOffPending(phase)" in policy,
      "a late turn-off is cancelable by an observed unlock")
retry = body(policy, "func shouldRetryTurnOff(")
check("helperReachable" in retry and "isLocked == true" in retry and "lidClosed" in retry,
      "retry needs the close standing, a locked screen and a reachable helper")
check("turnOffPending" in retry or "isTurnOffPending(phase)" in retry,
      "only a pending (unconfirmed) turn-off may be retried")

# --- Screen lock observer is read-only and timer-bounded ------------------

check("CGSessionCopyCurrentDictionary()" in observer,
      "lock state comes from the login session dictionary")
check("CGSSessionScreenIsLocked" in observer,
      "the observer reads CGSSessionScreenIsLocked")
check("static func interpret(" in observer,
      "lock interpretation is a pure function")
check("if let value = dictionary[screenLockedKey]" in observer,
      "a present lock key is read first")
check("onConsoleKey" in observer and "return false" in observer,
      "an absent key in a console session is unlocked (measured macOS behaviour)")
check("return nil" in observer,
      "unreadable or non-console state is reported as unknown")
start = body(observer, "func start()")
stop = body(observer, "func stop()")
poll = body(observer, "func poll()")
check("guard !isRunning else { return }" in start,
      "the observer can start only once")
check("timer?.invalidate()" in stop and "isRunning = false" in stop,
      "stop invalidates the timer and clears the running flag")
check("guard isRunning else { return lastKnown }" in poll,
      "polling does nothing unless the observer was started")
check("Timer(timeInterval: Self.pollInterval" in start,
      "polling uses the one-second interval")
check("NSWorkspace" not in observer and "DistributedNotification" not in observer,
      "no distributed notifications or workspace observers are required")
check("Accessibility" not in observer and "AXIsProcessTrusted" not in observer,
      "reading lock state needs no Accessibility permission")

# --- Component wiring ---------------------------------------------------------

lid = body(behaviors, "func lidChanged(closed: Bool)")
check("PasswordAfterCloseController.shared.lidDidClose()" in lid,
      "a real lid close drives the password-after-close path")
check("PasswordAfterCloseController.shared.lidDidOpen()" in lid,
      "a lid open drives the lock-aware restore path")
close_at = lid.index("PasswordAfterCloseController.shared.lidDidClose()")
open_at = lid.index("PasswordAfterCloseController.shared.lidDidOpen()")
check(close_at < open_at, "close and open triggers sit in their own branches")

component_stop = body(behaviors, "func stop()")
check("PasswordAfterCloseController.shared.didQuit()" in component_stop,
      "quit triggers the promised Touch ID restore")
wake_branch = body(behaviors, "func start()")
check("PasswordAfterCloseController.shared.lidDidWake()" in wake_branch,
      "system wake is a restore trigger")
tick = body(behaviors, "private func tick()")
check("PasswordAfterCloseController.shared.tick()" in tick,
      "the component tick drives the late turn-off retry")

teardown = body(behaviors, "private func teardown(_ id: String)")
check('case "passwordAfterClose": PasswordAfterCloseController.shared.didDisable()' in teardown,
      "disabling the component settles its hand-back")

check("PasswordAfterCloseController.shared.didLaunch()" in delegate,
      "app launch finishes or undoes a persisted phase")

# --- Locked-screen safety --------------------------------------------------

controller = body(behaviors, "final class PasswordAfterCloseController")
controller_body = block(behaviors, "final class PasswordAfterCloseController")
lid_open = body(controller_body, "func lidDidOpen()")
check("case true:" in lid_open and "case false:" in lid_open and "case nil:" in lid_open,
      "lid open distinguishes locked, unlocked and unknown")
check("settleWhileUnlocked(trigger: \"lid open\")" in lid_open,
      "lid open restores only through the proven-unlocked branch")
locked_branch = lid_open.split("case true:", 1)[1].split("case false:", 1)[0]
check("settleWhileUnlocked" not in locked_branch,
      "the locked lid-open branch never restores")
wake = body(controller_body, "func lidDidWake()")
check("guard ScreenLockObserver.isLocked == false else" in wake,
      "wake restoration requires a proven unlocked screen")
retry_tick = body(controller_body, "func tick()")
check("guard ScreenLockObserver.isLocked == false else { return }" in retry_tick,
      "a retried restore never runs while locked")
check("settleWhileUnlocked(trigger: \"tick\")" in retry_tick,
      "an unlock seen by the tick cancels the late turn-off")

# The generic session sweep must not undo the promise while the screen is up.
session_end = body(behaviors, "func sessionDidEnd()")
check('excluding: ["passwordAfterClose"]' in session_end,
      "session end excludes the password hand-back from the generic restore")
check('excluding: ["passwordAfterClose"]' in lid,
      "lid open excludes the password hand-back from the generic restore")

# --- Quit / disable ---------------------------------------------------------

did_quit = body(controller_body, "func didQuit()")
check("setPhase(.restorePending(closeID: closeID))" in did_quit,
      "quit marks a confirmed turn-off as restore-pending")
check("await self.restore(closeID: closeID, reason: \"Wakely quit\")" in did_quit,
      "quit actually asks the helper to restore")
check("Wakely quit before the late turn-off finished" in did_quit,
      "quitting an unconfirmed turn-off is reported, not faked")

did_disable = body(controller_body, "func didDisable()")
check('restore(component: "passwordAfterClose", reason: "component disabled")' in did_disable,
      "disable restores a confirmed Touch ID change")

# --- Never off after an unlock --------------------------------------------

apply_turn_off = body(controller_body, "private func applyTurnOff(closeID: UUID)")
check("if unlockedSinceClose {" in apply_turn_off,
      "a confirmed write is undone when an unlock was observed first")
check("unlocked before the late turn-off finished" in apply_turn_off,
      "the late-turn-off race is logged in the original wording")
unlock = body(controller_body, "private func unlockObserved()")
check("unlocked since the close that found the helper away; no late turn-off" in unlock,
      "an unlock cancels a pending write with the original reason")
pending_branch = unlock.split("case .turnOffPending(let closeID):", 1)[1].split("case .off", 1)[0]
check("pendingTurnOffWasApplied()" in pending_branch,
      "an unlock checks whether the armed-session path already wrote the change")
check("no late turn-off" in pending_branch and "setPhase(.idle)" in pending_branch,
      "an unwritten pending turn-off is cancelled with the original reason")
check("unlocked before the late turn-off finished" in pending_branch,
      "an actually-applied pending turn-off is restored instead of cancelled")

# --- Persistence and narrow helper path -----------------------------------

check('"passwordAfterClose.phase"' in controller_body,
      "the phase is persisted for a relaunch")
check('"passwordAfterClose.closeID"' in controller_body,
      "the close id is persisted with the phase")
check("restoreAll" not in controller_body,
      "the password path never uses the broad restoreAll sweep")
check("passwordAfterCloseDidClose()" in controller_body,
      "the close path uses the narrow protected-component apply")
check("passwordAfterCloseRestore()" in controller_body,
      "the restore path uses the narrow protected-component restore")
narrow_apply = body(behaviors, "func passwordAfterCloseDidClose()")
check("beginShutdown" not in narrow_apply and "shuttingDown" in narrow_apply,
      "the narrow apply respects the shutdown flag")
check("applying.contains(id)" in narrow_apply and "restoring.contains(id)" in narrow_apply,
      "the narrow apply respects the apply/restore interlocks")
narrow_restore = body(behaviors, "func passwordAfterCloseRestore()")
check("restoring.insert(id)" in narrow_restore,
      "the narrow restore registers with the termination drain")

# --- PowerEngine lock request ----------------------------------------------

check("func lockScreenNow(reason: String) -> Bool" in power,
      "the power engine exposes an internal lockScreenNow")
lock = body(power, "func lockScreenNow(reason: String) -> Bool")
check("sendLockScreenRequest(reason: reason)" in lock,
      "lockScreenNow uses the existing login.framework request path")
check("lastLockScreenRequest" in lock,
      "a recent armed-close lock is not repeated")
armed = body(power, "private func requestLockScreen()")
check('sendLockScreenRequest(reason: "close")' in armed,
      "an armed close still uses the original close log path")
send = body(power, "private func sendLockScreenRequest(reason: String) -> Bool")
check('"SACLockScreenImmediate"' in send and "login.framework" in send,
      "the native Lock Screen request keeps its login.framework implementation")

# --- Tests are side-effect free --------------------------------------------

# The pure Swift test must not link or name a live backend. Comments are already
# stripped above, so the only hits would be real references.
forbidden = [
    "SMApp" + "Service",
    "CGSession" + "CopyCurrentDictionary",
    "SACLock" + "ScreenImmediate",
    "bio" + "util",
    "touchID" + "Unlock",
    "Pro" + "tectedComponents",
    "Power" + "Engine",
    "ScreenLock" + "Observer",
    "User" + "Defaults",
    "Helper" + "Client",
    "/usr/bin/" + "pmset",
    "nv" + "ram",
    "su" + "do",
]
hits = [token for token in forbidden if token in policy_tests_text]
check(not hits, f"PasswordAfterClosePolicyTests.swift names no live/system API ({hits})")

# The structural checks themselves must never execute a command or talk to a
# system service: only pathlib/re/sys are imported.
self_text = Path(__file__).read_text()
for token in ("import " + "subprocess", "subprocess." + "run", "os." + "system",
              "Po" + "pen", "check_" + "output"):
    check(token not in self_text, f"structural checks do not use {token}")

check("UserDefaults" not in policy and "UserDefaults" not in policy_tests_text,
      "the policy and its Swift tests never touch preferences")
check("import AppKit" not in policy and "import IOKit" not in policy,
      "the policy imports no UI or hardware framework")
check("import AppKit" not in observer or "import IOKit" not in observer,
      "the observer needs only Foundation and CoreGraphics")
check("Foundation" in policy and "CoreGraphics" in observer,
      "the pure files keep their minimal imports")

if failures:
    print(f"\n{len(failures)} structural check(s) failed")
    sys.exit(1)

print(f"\nPASS: all Password After Close structural checks; no system call was made")
