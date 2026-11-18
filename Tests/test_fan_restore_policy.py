"""Extract and execute only the pure fan snapshot policy.

Compiles Helper/SMC.swift's `BEGIN TESTABLE FAN SNAPSHOT` block on its own.
No IOKit, no SMC connection, no hardware writes, no Helper run.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Helper/SMC.swift").read_text()
block = source.split("// BEGIN TESTABLE FAN SNAPSHOT\n", 1)[1].split(
    "// END TESTABLE FAN SNAPSHOT", 1
)[0]

# The extracted block must stay pure: no driver, no session, no shared state.
for forbidden in ("IOKit", "SMCSession", "FanControl", "IOService"):
    assert forbidden not in block, f"snapshot block must stay pure ({forbidden})"
assert "import " not in block

# The SMC layer must capture and restore the versioned snapshot, and must
# restore only through the pure pre-write decision.
assert "static func currentSnapshot() -> FanSnapshotPolicy.Snapshot?" in source
assert "static func restore(" in source
assert "FanSnapshotPolicy.ownershipMismatch(" in source
assert "no fan was written" in source
assert "verifiedCurrent" in source

restore_smc = source.split("static func restore(\n        _ snapshot:", 1)[1].split(
    "// MARK: - Support probe", 1
)[0]
# Everything that can refuse runs before the first write.
first_write = restore_smc.index("try writeValue(")
for preflight in (
    "FanSnapshotPolicy.validate(snapshot)",
    "probeSupportLocked()",
    "snapshot.fans.count == fanCount",
    "let fresh = try snapshotLocked",
    "FanSnapshotPolicy.ownershipMismatch(",
    "resolved.append(",
):
    assert restore_smc.index(preflight) < first_write, f"{preflight} must precede writes"
# Manual fans enter forced mode before their target; automatic fans restore the
# target before handing the fan back.
manual_branch = restore_smc.split("if item.fan.modeRaw == 1 {", 1)[1].split("} else {", 1)[0]
assert manual_branch.index("writeValue(item.modeKey, bytes: [1]") < manual_branch.index(
    "writeValue(item.targetKey"
)
auto_branch = restore_smc.split("} else {", 1)[1].split("} catch {", 1)[0]
assert auto_branch.index("writeValue(item.targetKey") < auto_branch.index(
    "writeValue(item.modeKey, bytes: [item.fan.modeRaw]"
)
assert "bytes: [0]" not in auto_branch, "restore must preserve automatic mode 0 or 3 exactly"

operations = (root / "Helper/Operations.swift").read_text()
setter = operations.split("private static func setFanPercent", 1)[1].split(
    "private static func applyFanPercent", 1
)[0]
assert setter.index("FanControl.currentSnapshot()") < setter.index("BackupStore.save")
assert setter.index("BackupStore.save") < setter.index("applyFanPercent(target)")
assert setter.index("BackupStore.save") < setter.index("applyAutomaticFan()")
assert "FanSnapshotPolicy.encode(prior)" in setter
assert "FanSnapshotPolicy.unrecordedWrittenToken" in setter
assert 'details["exact"]' in setter

apply_percent = operations.split("private static func applyFanPercent", 1)[1].split(
    "private static func applyAutomaticFan", 1
)[0]
assert apply_percent.index("FanControl.setPercent") < apply_percent.index("FanControl.currentSnapshot()")
apply_auto = operations.split("private static func applyAutomaticFan", 1)[1].split(
    "private static func restoreFan", 1
)[0]
assert apply_auto.index("FanControl.restoreAutomatic") < apply_auto.index("FanControl.currentSnapshot()")

restore_fan = operations.split("private static func restoreFan", 1)[1].split(
    "// MARK: - Restore", 1
)[0]
assert "FanSnapshotPolicy.restoreDecision(" in restore_fan
assert restore_fan.index("restoreDecision(") < restore_fan.index("FanControl.restore(")
assert "fanTarget" not in operations
assert "percent:" not in restore_fan
assert "BackupStore.remove" not in restore_fan
assert "lease is retained" in restore_fan
component_restore = operations.split("private static func restoreComponent", 1)[1].split(
    "private static func restoreAll", 1
)[0]
assert component_restore.index("guard outcome.ok else") < component_restore.index("BackupStore.remove")

# The verified Touch ID policy block must remain untouched.
assert "// BEGIN TESTABLE TOUCH ID POLICY" in operations
assert "TouchIDHelperPolicy.operation," in operations
assert "legacyOperation" in operations

harness = r'''
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

func bytes(_ rpm: Double) -> [UInt8] {
    let bits = Float(rpm).bitPattern
    return [
        UInt8((bits >> 24) & 0xFF),
        UInt8((bits >> 16) & 0xFF),
        UInt8((bits >> 8) & 0xFF),
        UInt8(bits & 0xFF)
    ]
}

func fan(_ index: Int, mode: UInt8, rpm: Double, min: Double? = 1000,
         max: Double = 6000, suffix: String = "Md",
         targetType: UInt32 = FanSnapshotPolicy.fltType,
         modeType: UInt32 = 0x75693820,
         rawBytes: [UInt8]? = nil,
         storedRPM: Double? = nil) -> FanSnapshotPolicy.Fan {
    FanSnapshotPolicy.Fan(
        index: index,
        modeKey: suffix,
        modeType: modeType,
        modeRaw: mode,
        targetType: targetType,
        targetBytes: rawBytes ?? bytes(rpm),
        targetRPM: storedRPM ?? rpm,
        minimumRPM: min,
        maximumRPM: max
    )
}

func snapshot(_ fans: [FanSnapshotPolicy.Fan]) -> FanSnapshot {
    FanSnapshot(fans: fans)
}

func isLegacyManual(_ token: FanSnapshotPolicy.Token) -> Bool {
    if case .legacyManual = token { return true }
    return false
}

func isLegacyAutomatic(_ token: FanSnapshotPolicy.Token) -> Bool {
    if case .legacyAutomatic = token { return true }
    return false
}

func isInvalid(_ token: FanSnapshotPolicy.Token) -> Bool {
    if case .invalid = token { return true }
    return false
}

func refusal(_ decision: FanSnapshotPolicy.RestoreDecision) -> String? {
    if case .refuse(let message) = decision { return message }
    return nil
}

func restored(_ decision: FanSnapshotPolicy.RestoreDecision) -> FanSnapshot? {
    if case .restore(let snapshot) = decision { return snapshot }
    return nil
}

func automatic(_ decision: FanSnapshotPolicy.RestoreDecision) -> String? {
    if case .restoreAutomatic(let reason) = decision { return reason }
    return nil
}

// --- Round trip, including heterogeneous fans -----------------------------

let manual = fan(0, mode: 1, rpm: 3500, min: 1200, max: 5800)
let automaticFan = fan(1, mode: 0, rpm: 2400, min: nil, max: 6200, suffix: "md")
let heterogeneous = snapshot([manual, automaticFan])

guard let token = FanSnapshotPolicy.encode(heterogeneous) else {
    expect(false, "a complete heterogeneous snapshot must encode")
    fatalError()
}
expect(token.hasPrefix(FanSnapshotPolicy.tokenPrefix), "token is versioned")
expect(token.contains("\"version\":\"fanSnapshot.v1\""), "JSON records the version")
expect(FanSnapshotPolicy.decode(token) == .snapshot(heterogeneous), "JSON round trip preserves every fan")
expect(FanSnapshotPolicy.encode(heterogeneous) == token, "encoding is deterministic")
expect(FanSnapshotPolicy.validate(heterogeneous) == nil, "complete snapshot validates")

if case .snapshot(let decoded) = FanSnapshotPolicy.decode(token) {
    expect(decoded.fans[0].targetBytes == manual.targetBytes, "target bytes survive the round trip")
    expect(decoded.fans[0].modeKey == "Md", "resolved mode suffix survives")
    expect(decoded.fans[1].modeKey == "md", "md fallback survives")
    expect(decoded.fans[1].minimumRPM == nil, "absent minimum survives")
    expect(decoded.fans[1].maximumRPM == 6200, "maximum survives")
}

expect(FanSnapshotPolicy.summary(heterogeneous) == "mixed", "heterogeneous summary")
expect(FanSnapshotPolicy.summary(snapshot([fan(0, mode: 0, rpm: 1200),
                                           fan(1, mode: 0, rpm: 1400)])) == "auto",
       "all-automatic summary")
expect(FanSnapshotPolicy.summary(snapshot([fan(0, mode: 1, rpm: 3500),
                                           fan(1, mode: 1, rpm: 3000)])) == "manual",
       "all-manual summary")
expect(FanSnapshotPolicy.summary(snapshot([])) == "unknown", "empty summary")
expect(FanSnapshotPolicy.isAllAutomatic(snapshot([fan(0, mode: 0, rpm: 1200)])), "all automatic")
expect(!FanSnapshotPolicy.isAllAutomatic(heterogeneous), "mixed is not all automatic")

// --- Incomplete or unrepresentable snapshots are refused ------------------

func mustReject(_ bad: FanSnapshot, _ label: String) {
    expect(FanSnapshotPolicy.validate(bad) != nil, "\(label): validation must fail")
    expect(FanSnapshotPolicy.encode(bad) == nil, "\(label): must not encode")
}

expect(FanSnapshotPolicy.validate(snapshot([])) != nil, "no fans rejected")
mustReject(snapshot([]), "empty snapshot")
mustReject(snapshot([fan(0, mode: 2, rpm: 3500)]), "unknown raw mode")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, rawBytes: [0, 0, 1])]), "three target bytes")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, rawBytes: bytes(3000))]), "bytes and RPM disagree")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, targetType: 0x75693820)]), "target type not flt")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, modeType: 0)]), "mode type missing")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, suffix: "XX")]), "bad mode suffix")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, max: 0)]), "zero maximum")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, max: .nan)]), "nan maximum")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, min: -1)]), "negative minimum")
mustReject(snapshot([fan(0, mode: 1, rpm: 3500, min: .nan)]), "nan minimum")
mustReject(snapshot([fan(1, mode: 1, rpm: 3500)]), "non-contiguous index")
mustReject(snapshot((0...10).map { fan($0, mode: 1, rpm: 3500) }), "more than ten fans")

if case .snapshot(let base) = FanSnapshotPolicy.decode(token) {
    var wrongVersion = base
    wrongVersion.version = "fanSnapshot.v9"
    expect(FanSnapshotPolicy.encode(wrongVersion) == nil, "wrong version must not encode")
}

expect(isInvalid(FanSnapshotPolicy.decode("fanSnapshot.v1:{not json}")), "malformed JSON rejected")
expect(isInvalid(FanSnapshotPolicy.decode("")), "empty token rejected")
expect(isInvalid(FanSnapshotPolicy.decode("percent")), "unknown text rejected")
expect(isInvalid(FanSnapshotPolicy.decode(
    token.replacingOccurrences(of: "fanSnapshot.v1:", with: "fanSnapshot.v2:")
)), "unsupported version rejected")
let tampered = token.replacingOccurrences(of: "\"index\":0", with: "\"index\":3")
expect(isInvalid(FanSnapshotPolicy.decode(tampered)), "tampered index rejected")

// --- Legacy tokens --------------------------------------------------------

expect(isLegacyAutomatic(FanSnapshotPolicy.decode("auto")), "legacy auto")
expect(isLegacyAutomatic(FanSnapshotPolicy.decode(" AUTOMATIC ")), "legacy automatic, trimmed")
expect(isLegacyManual(FanSnapshotPolicy.decode("percent:65")), "legacy percent token")
expect(isLegacyManual(FanSnapshotPolicy.decode("70")), "legacy bare percent")
expect(isLegacyManual(FanSnapshotPolicy.decode(" PERCENT:70 ")), "legacy percent is case-insensitive")

let currentForLegacy = snapshot([fan(0, mode: 1, rpm: 3500), fan(1, mode: 0, rpm: 2400)])
let legacyManualDecision = FanSnapshotPolicy.restoreDecision(
    previousToken: "percent:65", writtenToken: "percent:65", current: currentForLegacy)
guard let legacyManualMessage = refusal(legacyManualDecision) else {
    expect(false, "legacy manual token must be refused")
    fatalError()
}
expect(legacyManualMessage.contains("percent:65"), "legacy refusal quotes the token")
expect(legacyManualMessage.contains("Nothing was written"), "legacy refusal says nothing was written")
expect(legacyManualMessage.contains("lease is retained"), "legacy refusal keeps the lease")
expect(legacyManualMessage.contains("manual fan restoration"), "legacy refusal asks for manual recovery")

let legacyAutoDecision = FanSnapshotPolicy.restoreDecision(
    previousToken: "auto", writtenToken: "percent:65", current: currentForLegacy)
guard let legacyAutoReason = automatic(legacyAutoDecision) else {
    expect(false, "proven-safe legacy automatic token must be honoured")
    fatalError()
}
expect(legacyAutoReason.contains("cannot flatten"), "legacy automatic explains why it is safe")
expect(FanSnapshotPolicy.restoreDecision(
    previousToken: "auto", writtenToken: "auto", current: currentForLegacy).isAutomatic,
    "legacy automatic is honoured")

extension FanSnapshotPolicy.RestoreDecision {
    var isAutomatic: Bool {
        if case .restoreAutomatic = self { return true }
        return false
    }
}

// --- Ownership / mismatch -------------------------------------------------

let writtenState = snapshot([fan(0, mode: 1, rpm: 3500), fan(1, mode: 0, rpm: 2400)])
let previousState = snapshot([fan(0, mode: 0, rpm: 2000), fan(1, mode: 1, rpm: 4200)])

expect(FanSnapshotPolicy.sameOwnedState(saved: writtenState, current: writtenState),
       "identical state is owned")
expect(restored(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: writtenState)) == previousState,
    "ownership match restores the exact heterogeneous prior state")

let manualDrift = snapshot([fan(0, mode: 1, rpm: 5000), fan(1, mode: 0, rpm: 2400)])
guard let driftMessage = refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: manualDrift)) else {
    expect(false, "a manual target changed elsewhere must refuse")
    fatalError()
}
expect(driftMessage.contains("changed outside Wakely"), "mismatch names the cause")
expect(driftMessage.contains("F0"), "mismatch names the fan")
expect(driftMessage.contains("Nothing was written"), "mismatch says nothing was written")
expect(driftMessage.contains("lease is retained"), "mismatch keeps the lease")

let modeDrift = snapshot([fan(0, mode: 0, rpm: 3500), fan(1, mode: 0, rpm: 2400)])
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: modeDrift)) != nil, "a mode changed elsewhere must refuse")

// An automatic fan's target is firmware-owned: drift there is not a mismatch.
let autoDrift = snapshot([fan(0, mode: 1, rpm: 3500), fan(1, mode: 0, rpm: 3200)])
expect(restored(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: autoDrift)) == previousState,
    "automatic target drift does not block restoration")

// Count changes cannot be represented exactly.
let fewerFans = snapshot([fan(0, mode: 1, rpm: 3500)])
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: fewerFans)) != nil, "fan count change must refuse")
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(fewerFans)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: writtenState)) != nil, "snapshot/current count change must refuse")

// A lease without a post-change snapshot cannot prove ownership.
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.unrecordedWrittenToken,
    current: writtenState)) != nil, "unrecorded written state must refuse")
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: "percent:65",
    current: writtenState)) != nil, "legacy written state must refuse")
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: "fanSnapshot.v1:{broken",
    current: writtenState)) != nil, "malformed written state must refuse")

// A malformed previous snapshot is refused, never approximated.
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: "fanSnapshot.v1:{broken",
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: writtenState)) != nil, "malformed previous snapshot must refuse")
expect(refusal(FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: snapshot([fan(0, mode: 2, rpm: 3500), fan(1, mode: 0, rpm: 2400)]))) != nil,
    "incomplete current state must refuse")

// Decisions are pure: the same inputs produce the same answer.
let firstDecision = FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: writtenState)
let secondDecision = FanSnapshotPolicy.restoreDecision(
    previousToken: FanSnapshotPolicy.encode(previousState)!,
    writtenToken: FanSnapshotPolicy.encode(writtenState)!,
    current: writtenState)
expect(firstDecision == secondDecision, "restore decisions are deterministic")

print("PASS: fan snapshot round-trips, incomplete/legacy/ownership refusals are pre-write")
'''

with tempfile.TemporaryDirectory(prefix="wakely-fan-restore-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text("import Foundation\n" + block + "\n" + harness)
    binary = work / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
        str(work / "main.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
print("PASS: fan restore policy is exact or refuses before any write")
