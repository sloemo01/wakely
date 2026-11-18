"""Compile and run only the injected power lifecycle helpers; no hardware APIs."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/PowerEngine.swift").read_text()
helpers = source.split("// BEGIN TESTABLE POWER LIFECYCLE HELPERS\n", 1)[1].split(
    "// END TESTABLE POWER LIFECYCLE HELPERS", 1
)[0]
tests = (root / "Tests/PowerEngineLifecycleTests.swift").read_text()
with tempfile.TemporaryDirectory(prefix="wakely-lifecycle-tests-") as directory:
    work = Path(directory)
    (work / "Tests.swift").write_text("import Foundation\n" + helpers + "\n" + tests)
    binary = work / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-parse-as-library",
        "-module-cache-path", str(work / "cache"),
        str(work / "Tests.swift"), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
