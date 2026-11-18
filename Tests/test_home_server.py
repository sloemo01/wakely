#!/usr/bin/env python3
"""Structural checks for Home Server relaunch/login/rearm (M7).

Source-shape checks only; the behaviour matrix lives in
Tests/HomeServerPolicyTests.swift. Nothing here installs or removes a login item,
arms, reads AC power, calls a helper, or writes preferences. Forbidden API names
are assembled from fragments so this file does not contain the literals it
forbids.
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
    text = path.read_text()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def block(source: str, marker: str) -> str:
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


policy_path = sources / "HomeServerPolicy.swift"
login_path = sources / "LoginItem.swift"
power_path = sources / "PowerEngine.swift"
delegate_path = sources / "AppDelegate.swift"
behaviors_path = sources / "ComponentBehaviors.swift"
policy_tests = tests / "HomeServerPolicyTests.swift"

for path in (policy_path, login_path, power_path, delegate_path, behaviors_path,
             policy_tests):
    check(path.is_file() and path.stat().st_size > 0, f"{path.name} exists and is not empty")

policy = swift_source(policy_path)
login = swift_source(login_path)
power = swift_source(power_path)
delegate = swift_source(delegate_path)
behaviors = swift_source(behaviors_path)
policy_tests_text = swift_source(policy_tests)

# --- Pure policy surface ---------------------------------------------------

for signature in [
    "static func shouldArmAtLaunch(componentEnabled: Bool, onCharger: Bool) -> Bool",
    "static func shouldIgnoreControlDisarm(componentEnabled: Bool, onCharger: Bool) -> Bool",
    "static func shouldIgnoreDisarm(componentEnabled: Bool, onCharger: Bool,",
    "static func shouldRegisterLoginItem(enabledComponentIDs: Set<String>) -> Bool",
    "static func classifyDisarm(_ reason: String) -> DisarmClass",
]:
    check(signature in policy, f"policy declares {signature.split('(')[0].strip()}")

check('"homeServer", "passwordAfterClose", "sleepUntilReset"' in policy,
      "the login item covers exactly the three restart-sensitive components")
check("static let maximumPerHour = 5" in policy,
      "the rearm budget is five per hour")
check("static let window: TimeInterval = 3600" in policy,
      "the rearm window is one hour")
for signature in ["func canRearm(now: Date) -> Bool",
                  "mutating func recordRearm(now: Date) -> Bool",
                  "mutating func prune(now: Date)",
                  "func rearmCount(now: Date) -> Int"]:
    check(signature in policy, f"budget exposes {signature.split('(')[0].strip()}")

classifier = body(policy, "static func classifyDisarm(")
for name in ("quitReasons", "lowBatteryReasons", "batteryBudgetReasons", "thermalReasons",
             "componentDisabledReasons", "helperRemovedReasons", "controlReasons"):
    check(f"{name})" in classifier or f"{name}" in classifier,
          f"classifier consults the {name} allowlist")
check(classifier.index("helperRemovedReasons") < classifier.index("controlReasons"),
      "safety classes are checked before control, so safety always wins")
check("return .control" in classifier and "return .unrecognized" in classifier,
      "a control stop is classified, and everything else is unrecognized")

disarm_gate = body(policy, "static func shouldIgnoreDisarm(")
check("guard !shuttingDown else { return false }" in disarm_gate,
      "an orderly quit is never ignored")
check("shouldIgnoreControlDisarm(" in disarm_gate,
      "the ignore gate needs the component and AC power")
check("classifyDisarm(reason) == .control" in disarm_gate,
      "only a control-class reason may be ignored")

# --- PowerEngine honor matrix ----------------------------------------------

engine_disarm = body(power, "func disarm(reason: String = \"you\")")
check("HomeServerPolicy.shouldIgnoreDisarm(" in engine_disarm,
      "disarm consults the Home Server policy")
check("shuttingDown: shuttingDown" in engine_disarm,
      "disarm tells the policy about an orderly quit")
check("componentEnabled: ComponentEngine.shared.isEnabled(\"homeServer\")" in engine_disarm,
      "the ignore path reads the real Home Server enablement")
check("onCharger: !onBattery()" in engine_disarm,
      "the ignore path reads the real power source")
check('"arming control ignored: Home Server keeps Wakely armed"' in engine_disarm,
      "the ignored control disarm is logged in the original wording")
check("policy.endSession()" in engine_disarm and "deactivate(reason: reason)" in engine_disarm,
      "a non-ignored stop still ends the session and releases resources")
check("restoreAll" not in engine_disarm and "restoreAll" not in delegate,
      "Home Server never uses the broad restoreAll sweep")

# --- Persistent session lifetime ------------------------------------------

hold = body(behaviors, "private func hold(")
check('id == "homeServer"' in hold and ".persistent" in hold,
      "Home Server holds a persistent session, not a one-close arm")
check("HomeServerAutomation.automaticArmAllowed()" in hold,
      "the Home Server hold obeys the persisted rearm budget")
check("HomeServerPolicy.loginItemComponentIDs.contains(id)" in behaviors,
      "built-in enablement is published only for the three restart-sensitive ids")
check("HomeServerAutomation.automaticArmAllowed =" in delegate,
      "the app points the component hold at the persisted rearm budget")

# --- AppDelegate launch / enablement / rearm ------------------------------

check(".componentEnablementChanged" in delegate,
      "the app observes component enablement changes")
check("LoginItem.sync(enabledComponentIDs: ComponentEngine.shared.enabledIDs" in delegate,
      "enablement changes re-evaluate the login item")
check('armHomeServerIfNeeded(reason: "launch")' in delegate,
      "launch evaluates the documented Home Server arm")
check('armHomeServerIfNeeded(reason: "Home Server enabled")' in delegate,
      "enabling Home Server arms it without waiting for a tick")
check("HomeServerPolicy.shouldArmAtLaunch(componentEnabled: enabled, onCharger: onCharger)" in delegate,
      "launch arming is gated by the pure policy")
check("rearmBudget.canRearm(now: Date())" in delegate and
      "rearmBudget.recordRearm(now: Date())" in delegate,
      "automatic rearms consume the persisted budget")
check('private static let rearmBudgetKey = "homeServer.rearmTimes"' in delegate,
      "the rearm budget survives a relaunch")
check("func loadRearmBudget()" in delegate and "func saveRearmBudget()" in delegate,
      "the rearm budget is loaded and saved")
check("guard !terminating, !engine.isShuttingDown else { return }" in delegate,
      "launch arming stops once termination began")
check('releaseAutomaticArm(owner: "homeServer"' in delegate,
      "disabling Home Server releases its own automatic arm")
check("SMApp" + "Service" not in delegate,
      "AppDelegate never talks to ServiceManagement directly")

# --- LoginItem -------------------------------------------------------------

for case in (".enabled", ".requiresApproval", ".notFound", ".unknown"):
    check(f"case {case}" in login, f"login-item status maps {case}")
check("switch SMApp" + "Service.mainApp.status" in login,
      "the login-item status comes from SMAppService.mainApp")
check("case .notRegistered, .notFound: return .notFound" in login,
      "an unregistered item is reported as not found, not enabled")
check("try SMApp" + "Service.mainApp.register()" in login,
      "registration goes through the system API")
check("try SMApp" + "Service.mainApp.unregister()" in login,
      "removal goes through the system API")
check("func ensureRegistered(reason: String) -> Bool" in login,
      "registration is best-effort and reports its result")
check("func unregister(reason: String)" in login, "removal is available and honest")
sync = body(login, "static func sync(")
check("HomeServerPolicy.shouldRegisterLoginItem(enabledComponentIDs: enabledComponentIDs)" in sync,
      "login-item registration is gated on the pure component policy")
check("guard ownsRegistration else { return }" in sync,
      "removal only happens for an item this build registered")
check("unregister(reason: reason)" in sync,
      "the no-enabled-component case can remove the owned item")
approval = body(login, "private static func logApproval(reason: String)")
check("awaiting approval in System Settings > Login Items; running without relaunch protection" in approval,
      "pending approval is reported in the original wording")
check("macOS asks you once to allow Wakely in Login Items" in approval,
      "the approval log explains the one system prompt")

# --- Tests are side-effect free --------------------------------------------

forbidden = [
    "SMApp" + "Service",
    "Login" + "Item.",
    "Power" + "Engine",
    "Component" + "Engine",
    "Helper" + "Client",
    "Pro" + "tectedComponents",
    "User" + "Defaults",
    "CGSession",
    "/usr/bin/" + "pmset",
    "nv" + "ram",
    "su" + "do",
]
hits = [token for token in forbidden if token in policy_tests_text]
check(not hits, f"HomeServerPolicyTests.swift names no live/system API ({hits})")

self_text = Path(__file__).read_text()
for token in ("import " + "subprocess", "subprocess." + "run", "os." + "system",
              "Po" + "pen", "check_" + "output"):
    check(token not in self_text, f"structural checks do not use {token}")

check("import AppKit" not in policy and "import IOKit" not in policy
      and "SMApp" + "Service" not in policy,
      "HomeServerPolicy imports no UI, hardware or ServiceManagement framework")
check("UserDefaults" not in policy,
      "the pure policy does not persist anything itself")

if failures:
    print(f"\n{len(failures)} structural check(s) failed")
    sys.exit(1)

print("\nPASS: all Home Server structural checks; no login item or power event was touched")
