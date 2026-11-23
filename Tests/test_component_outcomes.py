"""Outcome and lifecycle guards for the component-audit fixes. No app actions."""
from pathlib import Path

r = Path(__file__).resolve().parents[1]
beh = (r / 'Sources/ComponentBehaviors.swift').read_text()
power = (r / 'Sources/PowerEngine.swift').read_text()
reset = (r / 'Sources/SleepUntilResetController.swift').read_text()
runtime = (r / 'Sources/ComponentRuntime.swift').read_text()
perms = (r / 'Sources/ComponentPermissionPolicy.swift').read_text()
components = (r / 'Sources/Components.swift').read_text()

# Password After Close: the private call is not proof; observe locked state.
assert 'await waitForObservedScreenLock()' in beh
assert 'ScreenLockObserver.readIsLocked() == true' in beh
assert 'the Lock Screen did not become active; Touch ID was left unchanged' in beh
assert 'return result == 0' not in power and 'request accepted by loginwindow' in power

# Sleep Timer: recover audio when the request cannot proceed.
assert 'another owner kept the session armed; audio restored' in beh
assert 'sleep request refused; audio restored' in beh
assert 'if !System.sleep()' in beh

# Keep Awake: explicit request wins over the saved default and is reset.
assert 'private var keepAwakeRequested = false' in beh
assert 'if !keepAwakeRequested {' in beh
assert 'keepAwakeRequested = false' in beh and 'keepAwakeIndefinite = false' in beh

# Sleep Until Reset: generation checks and owner-scoped arm/disarm.
assert 'lifecycleGeneration' in reset
assert 'generation == lifecycleGeneration, isEnabled(), isLidClosed()' in reset
assert 'requestAutomaticArm(owner: "sleepUntilReset"' in reset
assert 'releaseAutomaticArm(owner: "sleepUntilReset"' in reset
assert 'if let confirmed = await reconcile(planned: planned, generation: generation)' in reset
assert 'kept.append(instant)' in reset

# Custom runtime: first observation is a baseline and stored values are normalized.
assert 'var primed = false' in runtime
assert 'if !state.primed {' in runtime
assert 'resolvedValue(for:' in runtime
assert 'number.doubleValue.isFinite' in runtime
assert 'options.indices.contains(index)' in runtime

# Home Server core is helper-independent; firmware enhancement remains optional.
assert 'id != "homeServer"' in beh
assert 'if id == "homeServer" { return true }' in beh
assert 'capability(.autoRestartAfterPowerLoss)' in beh
assert '"homeServer"' not in perms.split('static let helperIDs: Set<String> = [', 1)[1].split(']', 1)[0]
assert 'seedStarterComponents' not in components
assert 'SeedComponents' not in components
print('PASS: lock observation, timer audio recovery, keep-awake request state, reset generations/ownership, custom baselines/values, helperless Home Server')
