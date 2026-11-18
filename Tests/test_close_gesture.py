"""Compile and run only the pure CloseGesturePolicy block from PowerEngine.swift.

No IOHIDManager, power assertion, audio device, app launch, permission prompt or
other hardware API is touched. The extracted block plus ArmPolicy is compiled
with the app-free tests and executed once.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/PowerEngine.swift").read_text()
marker = "// BEGIN TESTABLE CLOSE GESTURE\n"
end_marker = "// END TESTABLE CLOSE GESTURE"
if marker not in source or end_marker not in source:
    raise SystemExit("missing // BEGIN/END TESTABLE CLOSE GESTURE in Sources/PowerEngine.swift")
policy = source.split(marker, 1)[1].split(end_marker, 1)[0]
arm_policy = (root / "Sources/ArmPolicy.swift").read_text()
tests = (root / "Tests/CloseGesturePolicyTests.swift").read_text()

with tempfile.TemporaryDirectory(prefix="wakely-close-gesture-tests-") as directory:
    work = Path(directory)
    (work / "Tests.swift").write_text(
        "import Foundation\n" + arm_policy + "\n" + policy + "\n" + tests
    )
    binary = work / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-parse-as-library",
        "-module-cache-path", str(work / "cache"),
        str(work / "Tests.swift"), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
