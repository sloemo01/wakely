#!/usr/bin/env python3
"""Structural checks for the Sleep Until Reset wiring (M6b).

These are source-shape checks, not behaviour tests. The timing matrix lives in
Tests/UsageResetPolicyTests.swift and the fixture-driven reader matrix in
Tests/SleepUntilResetReaderTests.swift; both link the pure files only. Nothing
here launches the app, reads a transcript, talks to a helper, schedules a wake,
runs pmset or touches a power setting.

The string checks below are deliberately narrow. Where a check depends on a
particular spelling (a function signature, a reason phrase, a fixed constant)
it is noted as BRITTLE in its message; those are the checks most likely to need
an update because the code was renamed, not because it regressed. The important
behavioural claims are asserted structurally: the controller only ever cancels
wakes the helper records as owned by this component, it never schedules on battery,
and it never names a scheduler or a privileged command itself.
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


controller_path = sources / "SleepUntilResetController.swift"
reader_path = sources / "UsageResetReader.swift"
policy_path = sources / "UsageResetPolicy.swift"
behaviors_path = sources / "ComponentBehaviors.swift"
client_path = sources / "HelperClient.swift"
policy_tests = tests / "UsageResetPolicyTests.swift"
reader_tests = tests / "SleepUntilResetReaderTests.swift"

for path in (controller_path, reader_path, policy_path, behaviors_path,
             client_path, policy_tests, reader_tests):
    check(path.is_file() and path.stat().st_size > 0, f"{path.name} exists and is not empty")

controller = swift_source(controller_path)
reader = swift_source(reader_path)
policy = swift_source(policy_path)
behaviors = swift_source(behaviors_path)
client = swift_source(client_path)
policy_tests_text = swift_source(policy_tests)
reader_tests_text = swift_source(reader_tests)

controller_body = block(controller, "final class SleepUntilResetController")

# --- The controller is the component's only app-side owner -------------------

check("@MainActor" in controller, "the controller is main-actor isolated")
check("static let shared = SleepUntilResetController()" in controller,
      "the controller is a single shared instance")
check("static let componentID = \"sleepUntilReset\"" in controller,
      "the controller names the component it owns")
check("func start()" in controller_body and "func replan(reason: String = \"replan\") async" in controller_body,
      "the controller exposes start and replan")
check("UsageResetPolicy.plan(resets:" in controller_body,
      "the controller plans through the pure policy")
check("UsageResetPolicy.replanKey(resets:" in controller_body,
      "the controller uses the pure replan key for change detection")
check("static let replanInterval: TimeInterval = 15 * 60" in controller_body,
      "the controller replans every fifteen minutes (BRITTLE: exact spelling)")
check("reader.read()" in controller_body,
      "reset data comes from the bounded reader")
check("Task.detached" in controller_body,
      "the transcript scan runs off the main actor")
check('diagnostics("' in controller_body and "print(" not in controller_body,
      "the controller logs through the injected diagnostics seam only")

# --- Only helper-owned wakes are ever touched -----------------------------

check("snapshot.wakes.filter(Self.isOurs)" in controller_body,
      "reconciliation and cancellation both filter to owned wakes")
check(controller_body.count("snapshot.wakes.filter(Self.isOurs)") >= 3,
      "launch adoption, reconciliation and cancellation all filter to owned wakes")
is_ours = body(controller_body, "private static func isOurs(")
check("wake.kind == \"wake\"" in is_ours and "createdBy" in is_ours and "componentID" in is_ours,
      "ownership is the helper's component label plus the wake kind, never a date")
cancel_calls = re.findall(r"cancelWake\(at:\s*([^)]*)\)", controller_body)
check(cancel_calls and all(call.strip() == "wake.at" for call in cancel_calls),
      f"every cancel names an owned wake instant only ({cancel_calls})")
check("cancelall" not in controller_body.lower(),
      "the broad cancelall sweep is never named")
check("helper.wakeScheduleSnapshot()" in controller_body,
      "the controller asks the helper what it already owns before changing anything")
reconcile = body(controller_body, "private func reconcile(")
check("guard snapshot.ok else" in reconcile,
      "an unreadable owned set stops reconciliation instead of duplicating events")
check("helper.scheduleWake(at: instant)" in reconcile,
      "a missing wake is scheduled through the validated helper API")
check("helper.cancelWake(at: wake.at)" in reconcile,
      "an unplanned wake is canceled through the helper's ownership match")
check("HelperRequest(" not in controller_body and "NSXPCConnection" not in controller_body,
      "the controller does not hand-build requests or open XPC itself")

# --- Lid open / disable / quit cancel owned wakes -------------------------

lid_open = body(controller_body, "func lidDidOpen()")
check("endSession(reason: \"the lid opened\"" in lid_open,
      "a lid open ends this component's stay-awake session (BRITTLE: reason text)")
check("cancelOwnedWakes(reason: \"the lid opened\")" in lid_open,
      "a lid open cancels the owned wakes (BRITTLE: reason text)")

did_disable = body(controller_body, "func didDisable()")
check("stopTimers()" in did_disable, "disable stops both timers")
check("cancelOwnedWakes(reason: \"the component was turned off\")" in did_disable,
      "disable cancels the owned wakes (BRITTLE: reason text)")
check("guard !isQuitting else { return }" in did_disable,
      "the quit path owns its own cancellation; disable does not duplicate it")

did_quit = body(controller_body, "func didQuit()")
check("cancelOwnedWakes(reason: \"Wakely quit\")" in did_quit,
      "quit cancels the owned wakes (BRITTLE: reason text)")
check("stopTimers()" in did_quit, "quit stops both timers")
check("Task {" in did_quit,
      "the quit cancellation is fire-and-forget so quitting cannot block on an absent helper")

# --- Wake: battery goes back to sleep, AC arms ----------------------------

did_wake = body(controller_body, "func didWake()")
check("guard isEnabled() else { return }" in did_wake,
      "a disabled component does nothing on a wake")
check("guard isLidClosed() else { return }" in did_wake,
      "an open lid does nothing on a wake")
check("UsageResetPolicy.shouldWakeOnBattery(at: instant, onBattery: onBattery())" in did_wake,
      "the battery decision is the pure policy with the measured source")
battery_at = did_wake.index("if UsageResetPolicy.shouldWakeOnBattery")
battery_branch = did_wake[battery_at:].split("return", 1)[0]
check("disarm(" in battery_branch,
      "a battery wake disarms with a reason")
check("requestSleep()" in battery_branch,
      "a battery wake goes back to sleep")
check("scheduleWake" not in battery_branch,
      "nothing is scheduled on battery")
check(not re.search(r"(?<!dis)arm\(\)", battery_branch),
      "a battery wake never arms the session")
check("arm()" in did_wake[did_wake.index("let wasArmed"):],
      "an AC wake arms the persistent session")
check("source: \"sleep until reset\"" in controller_body,
      "the arm source is the documented feature name (BRITTLE: exact phrase)")
check("lifetime: .persistent" in controller_body,
      "the wake session is persistent, not tied to one close")
check("startEvaluation()" in did_wake,
      "the grace and cap evaluator starts after an AC wake")

# --- Four-hour cap and session end ---------------------------------------

evaluation = body(controller_body, "private func startEvaluation()")
check("Task.sleep" in evaluation, "the evaluator is a bounded polling task")
check("self.isEnabled()" in evaluation and "self.isLidClosed()" in evaluation,
      "the evaluator stops when the component is off or the lid opens")
evaluate = body(controller_body, "private func evaluate()")
check("UsageResetPolicy.shouldEndAfterWake(" in evaluate,
      "the only end decision is the pure policy")
check("lastWorkAt" in evaluate and "waitingSince" in evaluate,
      "the evaluator tracks the last work and the waiting stamp")
end_session = body(controller_body, "private func endSession(")
check("disarm(reason)" in end_session, "ending our session disarms with the policy reason")
check("if sleep, !isArmed()" in end_session,
      "a sleep request is refused while another hold is armed")
check("static let maximumSessionDuration: TimeInterval = 4 * 60 * 60" in policy,
      "the four-hour cap lives in the pure policy")

# --- The app never calls a scheduler or a privileged command -------------

for name, text in (("controller", controller), ("reader", reader), ("policy", policy)):
    for forbidden in ("/usr/bin/pmset", "pmset ", "IOPMSchedulePowerEvent",
                      "Process(", "NSTask", "osascript", "launchctl", "sudo",
                      "NSXPCConnection"):
        check(forbidden not in text,
              f"{name} does not reach {forbidden!r} (BRITTLE: literal token)")

check("HelperComponentAPI" in controller_body,
      "the controller goes through the narrow component API")
client_raw = client_path.read_text()
wake_api = client_raw.split("// MARK: - Helper-owned one-off wakes (protocol 3)", 1)[1].split(
    "private func perform(_ request: HelperRequest)", 1
)[0]
wake_api = re.sub(r"//[^\n]*", "", wake_api)
for forbidden in ("Process(", "pmset", "/usr/bin/", "NSXPCConnection"):
    check(forbidden not in wake_api,
          f"the client wake API does not reach {forbidden!r}; the helper owns the command")

# --- The reader is bounded, metadata-only and private --------------------

for constant in ("static let maximumTailBytes = 256 * 1024",
                 "static let maximumFileBytes = 64 * 1024 * 1024",
                 "static let maximumFilesPerRoot = 48",
                 "static let maximumRecordsPerFile = 2048"):
    check(constant in reader, f"reader bound present: {constant} (BRITTLE: exact number)")

check("O_NOFOLLOW" in reader,
      "transcripts are opened with O_NOFOLLOW, so a symlink is refused atomically")
check("isSymbolicLink == true" in reader,
      "symlinked roots and directories are refused")
check("skipDescendants()" in reader,
      "the enumerator does not descend into a symlinked directory")
check("URLSession" not in reader and "import Network" not in reader,
      "the reader makes no network request")
check("import AppKit" not in reader and "import IOKit" not in reader
      and "import ServiceManagement" not in reader,
      "the reader imports no UI, hardware or service framework")
check("Diagnostics" not in reader and "print(" not in reader,
      "the reader never logs a path, account or transcript line")
check("account" in reader and "accountLabel" in reader,
      "an account label exists only for dedupe")
account_fn = body(reader, "private static func safeAccount(")
check('""' not in account_fn and "128" in account_fn,
      "account labels are bounded and charset-restricted")
read_body = body(reader, "func read()")
check("homeDirectoryForCurrentUser" not in read_body,
      "read() never resolves a real home; the roots come from the caller")
check("struct Roots" in reader and "static func live(home:" in reader,
      "the live roots are an explicit caller-supplied value")
check("private static func messageTexts(" in reader,
      "message text is read through one narrow extractor")
check("results.append(UsageLimitReset(" in reader,
      "only a reset value leaves the parser; message text is not retained")
check("resetsAt" in reader and "provider" in reader,
      "only provider, optional account and the instant are modelled")
check("Equatable" in reader and "struct UsageLimitReset" in reader,
      "the reset value type is plain data and Equatable")

# --- Policy contract ------------------------------------------------------

check("static func plan(resets: [UsageLimitReset], now: Date) -> [Date]" in policy,
      "the plan signature is pure (BRITTLE: exact signature)")
check("static func replanKey(resets: [UsageLimitReset]) -> String" in policy,
      "the replan key signature is pure (BRITTLE: exact signature)")
check("static func shouldWakeOnBattery(at date: Date, onBattery: Bool = true) -> Bool" in policy,
      "the battery decision is pure and defaults toward sleep (BRITTLE: exact signature)")
check("static func shouldEndAfterWake(now: Date," in policy
      and "sessionStartedAt: Date," in policy
      and "working: Int," in policy
      and "waiting: Int," in policy,
      "the end decision takes counts and the session start")
check("static let wakeDelay: TimeInterval = 60" in policy,
      "wake delay is one minute (proven)")
check("static let maximumSessionDuration: TimeInterval = 4 * 60 * 60" in policy,
      "session cap is four hours (proven)")
check("static let waitingLimit: TimeInterval = 15 * 60" in policy,
      "waiting limit is fifteen minutes (proven)")
check("static let wakeGrace: TimeInterval = 3 * 60" in policy,
      "the grace is three minutes and documented as OSS policy (BRITTLE: exact number)")
check("static let maximumEvents = 8" in policy,
      "at most eight owned wakes (OSS policy)")
check("static let maximumHorizon: TimeInterval = 7 * 24 * 60 * 60" in policy,
      "the horizon is seven days (OSS policy)")
policy_raw = policy_path.read_text()
check("OSS POLICY" in policy_raw and "PROVEN" in policy_raw,
      "the policy separates proven contract from OSS policy")

# --- ComponentBehaviors wiring ----------------------------------------------

component_start = body(behaviors, "func start()")
check("SleepUntilResetController.shared.start()" in component_start,
      "launch resumes the controller for an enabled component")
check("SleepUntilResetController.shared.didWake()" in component_start,
      "the existing wake observer calls the controller's wake path")
check("case .installed = HelperClient.shared.installState { return true }" in component_start,
      "the relaunch filter keeps helper-backed components only while installed")

component_stop = body(behaviors, "func stop()")
check("SleepUntilResetController.shared.didQuit()" in component_stop,
      "the quit path calls didQuit")

lid = body(behaviors, "func lidChanged(closed: Bool)")
check("SleepUntilResetController.shared.lidDidOpen()" in lid,
      "a lid open calls the controller's cancel path")
close_at = lid.index("PasswordAfterCloseController.shared.lidDidClose()")
open_at = lid.index("SleepUntilResetController.shared.lidDidOpen()")
check(close_at < open_at, "the lid-open call sits in the open branch")

teardown = body(behaviors, "private func teardown(_ id: String)")
check('case "sleepUntilReset": SleepUntilResetController.shared.didDisable()' in teardown,
      "disabling the component calls didDisable (BRITTLE: case spelling)")

set_enabled = body(behaviors, "func setEnabled(_ id: String, _ on: Bool)")
check("let wakeOwner = id == SleepUntilResetController.componentID" in set_enabled,
      "the helper-needing gate names the one component allowed to enable without a protected setting")
check("guard !on || !definition.needsHelper || wakeOwner else" in set_enabled,
      "every other helper-needing component still refuses to enable")

apply_state = body(behaviors, "private func applyComponentState(_ id: String, _ on: Bool)")
check("SleepUntilResetController.shared.start()" in apply_state,
      "enabling the component starts the controller")
check("if id == SleepUntilResetController.componentID, on" in apply_state,
      "only the enable branch starts it; teardown owns the disable branch")

tick = body(behaviors, "private func tick()")
check('noopHelper("sleepUntilReset")' not in tick,
      "the component no longer reports itself as having no automatic path")

check("ProtectedComponents.shared" in behaviors,
      "ProtectedComponents is untouched and still owns its own path")
check("PasswordAfterCloseController.shared.didDisable()" in teardown,
      "Password After Close teardown is unchanged")

# --- The tests never touch a real scheduler -------------------------------

for token in ("HelperClient", "PowerEngine", "ComponentEngine", "UserDefaults",
              "IOPMSchedulePowerEvent", "Process(", "pmset", "homeDirectoryForCurrentUser",
              "NSWorkspace", "Diagnostics"):
    check(token not in policy_tests_text,
          f"the policy tests name no live system API ({token})")
for token in ("HelperClient", "PowerEngine", "ComponentEngine", "UserDefaults",
              "Process(", "pmset", "homeDirectoryForCurrentUser", "Diagnostics"):
    check(token not in reader_tests_text,
          f"the reader tests name no live system API ({token})")
check("UsageResetReader(roots:" in reader_tests_text,
      "the reader tests inject a temporary fixture root")
check("now: { now }" in reader_tests_text,
      "the reader tests inject a fixed clock")
check("temporaryDirectory" in reader_tests_text,
      "the reader tests write only into the temporary directory")
check("createSymbolicLink" in reader_tests_text and "truncate(atOffset:" in reader_tests_text,
      "the reader tests exercise the symlink and oversized-file fixtures")
check("UsageResetPolicy.plan" in policy_tests_text and "shouldEndAfterWake" in policy_tests_text,
      "the policy tests exercise planning and the end matrix")

# The structural checks themselves must never execute a command or talk to a
# system service: only pathlib/re/sys are imported.
self_text = Path(__file__).read_text()
for token in ("import " + "subprocess", "subprocess." + "run", "os." + "system",
              "Po" + "pen", "check_" + "output"):
    check(token not in self_text, f"structural checks do not use {token}")

if failures:
    print(f"\n{len(failures)} structural check(s) failed")
    sys.exit(1)

print("\nPASS: all Sleep Until Reset structural checks; no system call was made")
