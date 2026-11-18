"""Extract and execute only pure policy; never run helper/bioutil or real backup IO."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Helper/Operations.swift").read_text()
block = source.split("// BEGIN TESTABLE TOUCH ID POLICY\n", 1)[1].split(
    "// END TESTABLE TOUCH ID POLICY", 1
)[0]
assert "Command.run" not in block and "Process(" not in block
assert "consoleUser" not in source and "launchctl" not in source
assert "Command.run(bioutilPath, TouchIDHelperPolicy.readArguments)" in source
assert "Command.run(bioutilPath, TouchIDHelperPolicy.writeArguments(enabled))" in source
assert "operation: TouchIDHelperPolicy.operation," in source
setter = source.split("private static func setTouchIDUnlock", 1)[1].split("private static func readTouchIDUnlock", 1)[0]
assert setter.index("BackupStore.save") < setter.index("try applyTouchIDUnlock")
restore = source.split("private static func restore(_ entry:", 1)[1].split("private static func booleanToken", 1)[0]
assert restore.index("entry.operation == TouchIDHelperPolicy.legacyOperation") < restore.index("readTouchIDUnlock()")
assert restore.index("TouchIDHelperPolicy.restoreError(", restore.index("entry.operation == TouchIDHelperPolicy.operation")) < restore.index("try applyTouchIDUnlock")
assert "BackupStore.remove" not in restore
assert "guard result.succeeded else { return nil }" in source.split("private static func readTouchIDUnlock", 1)[1].split("private static func applyTouchIDUnlock", 1)[0]
apply = source.split("private static func applyTouchIDUnlock", 1)[1].split("// MARK: - Boot", 1)[0]
assert apply.index("guard result.succeeded") < apply.index("readTouchIDUnlock()")
assert "guard after == enabled" in apply
component_restore = source.split("private static func restoreComponent", 1)[1].split("private static func restoreAll", 1)[0]
assert component_restore.index("guard outcome.ok else") < component_restore.index("BackupStore.remove")
all_restore = source.split("private static func restoreAll", 1)[1].split("private static func restore(_ entry:", 1)[0]
assert all_restore.index("if failures.isEmpty") < all_restore.index("BackupStore.remove")
# Existing upsert must preserve the first baseline/time for the same versioned key.
store = (root / "Helper/BackupStore.swift").read_text()
assert "$0.componentID == entry.componentID && $0.operation == entry.operation" in store
assert "merged.previous = entries[index].previous" in store
assert "merged.at = entries[index].at" in store
harness = (root / "Tests/TouchIDHelperPolicyTests.swift").read_text()
with tempfile.TemporaryDirectory(prefix="wakely-touchid-policy-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text("import Foundation\n" + block + "\n" + harness)
    binary = work / "tests"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(work / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("PASS: helper integration extraction guards and earliest lease baseline preservation")
