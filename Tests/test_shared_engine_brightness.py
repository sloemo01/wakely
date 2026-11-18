"""Compile and run only the injected brightness controller; no app/hardware APIs."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/PowerEngine.swift").read_text()
controller = source.split("// BEGIN TESTABLE BRIGHTNESS CONTROLLER\n", 1)[1].split(
    "// END TESTABLE BRIGHTNESS CONTROLLER", 1
)[0]
tests = (root / "Tests/SharedEngineBrightnessTests.swift").read_text()
with tempfile.TemporaryDirectory(prefix="wakely-brightness-tests-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text("import Foundation\n" + controller + "\n" + tests)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(work / "cache"),
        str(work / "main.swift"), "-o", str(work / "tests")
    ], check=True)
    subprocess.run([str(work / "tests")], check=True)
