"""Compile and run only the pure BootPreference policy; never run nvram or touch NVRAM."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Helper/Operations.swift").read_text()
block = source.split("// BEGIN TESTABLE BOOT POLICY\n", 1)[1].split(
    "// END TESTABLE BOOT POLICY", 1
)[0]
# The extracted block must be pure: no process, no NVRAM path, no backup store.
for forbidden in ["Command.run", "Process(", "nvramPath", "FileManager", "BackupStore"]:
    assert forbidden not in block, forbidden
assert "auto-boot" not in block.replace("`auto-boot`", "")

harness = r'''
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

func refuses(_ plan: BootPreferencePolicy.RestorePlan) -> Bool {
    if case .refuse = plan { return true }
    return false
}

// The one key and the three percent-encoded byte tokens.
expect(BootPreferencePolicy.key == "BootPreference", "single key")
expect(BootPreferencePolicy.tokens == ["%00", "%01", "%02"], "three byte tokens")
expect(BootPreferencePolicy.lidAndPowerToken == "%00", "lid+power is %00")
expect(BootPreferencePolicy.absentToken == "absent", "absent sentinel")
expect(BootPreferencePolicy.readArguments == ["-p"], "read is nvram -p")

// Parser: newline records, split at the FIRST tab only, exact key, exact token.
expect(BootPreferencePolicy.parse("boot-image-last\t5dc7af000:80000000\nBootPreference\t%00\n") == .state("%00"), "tab-split record")
expect(BootPreferencePolicy.parse("supervised\tfalse\nBootPreference\t%01\n") == .state("%01"), "later matching line")
expect(BootPreferencePolicy.parse("BootPreference\t%02") == .state("%02"), "%02 accepted")
expect(BootPreferencePolicy.parse("BootPreference\t%00\t\n") == .state("%00"), "trailing empty field still splits once")
expect(BootPreferencePolicy.parse("BootPreference\t  %00  ") == .state("%00"), "value trimmed of spaces")
expect(BootPreferencePolicy.parse("BootPreference\t%00\nBootPreference\t%01\n") == .state("%00"), "first matching line wins")

// Absent key is a valid state, not a failure.
expect(BootPreferencePolicy.parse("") == .absent, "empty output is absent")
expect(BootPreferencePolicy.parse("supervised\tfalse\n") == .absent, "missing key is absent")
expect(BootPreferencePolicy.parse("BootPreference %00\n") == .absent, "space-separated line is not a record")
expect(BootPreferencePolicy.parse(" BootPreference\t%00\n") == .absent, "key is not trimmed")
expect(BootPreferencePolicy.parse("bootpreference\t%00\n") == .absent, "key is case-sensitive")
expect(BootPreferencePolicy.parse("BootPreferenceX\t%00\n") == .absent, "key must match exactly")
expect(BootPreferencePolicy.parse("#BootPreference\t%00\n") == .absent, "prefixed key is not a record")

// Unreadable or unrecognised output is unsupported: never guessed.
expect(BootPreferencePolicy.parse("BootPreference\t%03\n") == .unsupported, "%03 rejected")
expect(BootPreferencePolicy.parse("BootPreference\ttrue\n") == .unsupported, "bool rejected")
expect(BootPreferencePolicy.parse("BootPreference\t\n") == .unsupported, "empty value rejected")
expect(BootPreferencePolicy.parse("BootPreference\t%0\t0\n") == .unsupported, "tab inside value rejected")
expect(BootPreferencePolicy.parse("BootPreference\t%00\textra\n") == .unsupported, "extra tab fields are rejected, not ignored")

// Only two fields can exist: the second field is the whole rest of the line.
expect(BootPreferencePolicy.parse("BootPreference\ta\tb\tc\n") == .unsupported, "many fields rejected")
expect(BootPreferencePolicy.parse("BootPreference\t%00 %01\n") == .unsupported, "two tokens in one value rejected")
expect(BootPreferencePolicy.parse("BootPreference\t%03\nBootPreference\t%00\n") == .unsupported, "first match decides; garbage is not skipped for a later line")

// Token round trip; the saved token grammar is exact, no trimming or folding.
for token in ["%00", "%01", "%02", "absent"] {
    expect(BootPreferencePolicy.token(token) == token, "token round trip \(token)")
}
for bad in ["", "0", "1", "true", "false", "%0", "%000", "%03", "%04", "%00 ", " %00", "absent ", " absent", "ABSENT", "%00\t", "lid+power"] {
    expect(BootPreferencePolicy.token(bad) == nil, "rejected token '\(bad)'")
}

// The request boolean is "boot allowed" (false keeps a shut-down Mac off):
// enabling stayOffWhenOpened sends false and must write the lid+power byte;
// allowing boot again restores the absent state by deleting the key.
expect(BootPreferencePolicy.writeToken(bootAllowed: false) == "%00", "component enable writes %00")
expect(BootPreferencePolicy.writeToken(bootAllowed: true) == "absent", "component disable deletes")
expect(BootPreferencePolicy.writeArguments(for: "%00") == ["BootPreference=%00"], "write argv")
expect(BootPreferencePolicy.writeArguments(for: "%01") == ["BootPreference=%01"], "other state argv")
expect(BootPreferencePolicy.writeArguments(for: "%02") == ["BootPreference=%02"], "power-only argv")
expect(BootPreferencePolicy.writeArguments(for: "absent") == ["-d", "BootPreference"], "delete argv")
for bad in ["", "%03", " false", "true", "ABSENT", "%00 "] {
    expect(BootPreferencePolicy.writeArguments(for: bad) == nil, "no argv for '\(bad)'")
}

// Restore plan: absent prior deletes, a value prior is written back.
expect(BootPreferencePolicy.restorePlan(previous: "absent", written: "%00", current: .state("%00")) == .delete, "absent prior deletes")
expect(BootPreferencePolicy.restorePlan(previous: "%01", written: "%00", current: .state("%00")) == .write("%01"), "value prior written back")
expect(BootPreferencePolicy.restorePlan(previous: "%02", written: "%01", current: .state("%01")) == .write("%02"), "power-only prior written back")
expect(BootPreferencePolicy.restorePlan(previous: "%00", written: "absent", current: .absent) == .write("%00"), "delete-then-restore replays value")
expect(BootPreferencePolicy.restorePlan(previous: "absent", written: "absent", current: .absent) == .delete, "absent stays absent")

// Refusals: unknown tokens, unreadable current, and the ownership mismatch.
expect(refuses(BootPreferencePolicy.restorePlan(previous: "%03", written: "%00", current: .state("%00"))), "unknown prior refused")
expect(refuses(BootPreferencePolicy.restorePlan(previous: "true", written: "%00", current: .state("%00"))), "bool prior refused")
expect(refuses(BootPreferencePolicy.restorePlan(previous: "absent", written: "false", current: .absent)), "unknown written refused")
expect(refuses(BootPreferencePolicy.restorePlan(previous: "absent", written: "%0", current: .absent)), "short written refused")
expect(refuses(BootPreferencePolicy.restorePlan(previous: "%00", written: "%00", current: .state("%01"))), "ownership mismatch refused")
expect(refuses(BootPreferencePolicy.restorePlan(previous: "%00", written: "%00", current: .absent)), "external delete refused")
expect(refuses(BootPreferencePolicy.restorePlan(previous: "absent", written: "%00", current: .unsupported)), "unreadable current refused")

if case .refuse(let message) = BootPreferencePolicy.restorePlan(previous: "%00", written: "%00", current: .state("%01")) {
    expect(message.contains("lease is retained"), "mismatch keeps the lease")
} else {
    expect(false, "mismatch must refuse")
}
print("PASS: BootPreference parser, token grammar and restore plans without touching NVRAM")
'''

with tempfile.TemporaryDirectory(prefix="wakely-boot-policy-") as directory:
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

# Integration guards: the daemon must use the policy, in the original's order.
setter = source.split("private static func setBootOnLidOpen", 1)[1].split(
    "private static func readBootPreference", 1
)[0]
assert "readBootPreference()" in setter
assert setter.index("readBootPreference()") < setter.index("BackupStore.save")
assert setter.index("BackupStore.save") < setter.index("try applyBootPreference")
assert 'prior = BootPreferencePolicy.absentToken' in setter
assert "BootPreferencePolicy.writeToken(bootAllowed: bootAllowed)" in setter
assert "private static func setBootOnLidOpen(_ bootAllowed: Bool" in source

reader = source.split("private static func readBootPreference", 1)[1].split(
    "private static func applyBootPreference", 1
)[0]
assert "Command.run(nvramPath, BootPreferencePolicy.readArguments)" in reader
assert "BootPreferencePolicy.parse(result.stdout)" in reader

apply = source.split("private static func applyBootPreference", 1)[1].split(
    "// MARK: - Fans", 1
)[0]
assert "BootPreferencePolicy.writeArguments(for: token)" in apply
assert "readBootPreference" not in apply, "a write must never be retracted by a read-back"

restore = source.split("case .bootOnLidOpen:\n                // The ownership check", 1)[1].split(
    "case .fanPercent:", 1
)[0]
assert restore.index("restorePlan(") < restore.index("applyBootPreference(")
assert 'try applyBootPreference(BootPreferencePolicy.absentToken)' in restore
assert "guard let enabled = booleanToken(entry.previous)" not in restore

# No auto-boot key/value anywhere in the helper; capability uses a read-only probe.
assert "auto-boot=" not in source
assert "auto-boot is not reported" not in source
assert 'switch readBootPreference()' in source and 'capability("bootOnLidOpen"' in source
assert "BootPreferencePolicy.readArguments" in source

# Public protocol case and UI text stay unchanged.
protocol = (root / "Sources/HelperProtocol.swift").read_text()
assert "case bootOnLidOpen         // boolValue: false keeps a shut-down Mac off" in protocol
assert "setBootOnLidOpen(false)" in (root / "Sources/ComponentBehaviors.swift").read_text()
capability = (root / "Sources/ComponentCapability.swift").read_text()
assert "BootPreference" in capability
assert "The Mac will stay off when the lid opens." in source
assert "The Mac will boot when the lid opens." in source

print("PASS: helper uses BootPreference (%00 to prevent lid+power boot, -d to restore absent)")
