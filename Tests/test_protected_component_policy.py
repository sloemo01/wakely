"""Compile and run only the injected protected-component policy; no AppKit, IOKit, helper or XPC."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/ComponentBehaviors.swift").read_text()
policy = source.split("// BEGIN TESTABLE PROTECTED POLICY\n", 1)[1].split(
    "// END TESTABLE PROTECTED POLICY", 1
)[0]

tests = (root / "Tests/ProtectedComponentPolicyTests.swift").read_text()
generated = tests.split("// BEGIN GENERATED PROTECTED POLICY\n", 1)[1].split(
    "// END GENERATED PROTECTED POLICY", 1
)[0]
assert generated.strip("\n") == policy.strip("\n"), (
    "Tests/ProtectedComponentPolicyTests.swift is out of sync with the testable policy block "
    "in Sources/ComponentBehaviors.swift; regenerate its generated section."
)
assert "import AppKit" not in policy and "NSWorkspace" not in policy, (
    "the testable block must not depend on AppKit"
)
assert "import IOKit" not in policy and "IOPMAssertion" not in policy, (
    "the testable block must not depend on IOKit"
)
assert "HelperClient.shared" not in policy and "HelperComponentAPI" not in policy and "NSXPCConnection" not in policy, (
    "the testable block must not reach the helper client or XPC"
)
assert "UserDefaults.standard" not in policy, "the testable block must not read preferences"
assert "Diagnostics." not in policy and "PowerEngine." not in policy, (
    "the testable block must not depend on runtime singletons"
)

with tempfile.TemporaryDirectory(prefix="wakely-protected-policy-tests-") as directory:
    work = Path(directory)
    (work / "Tests.swift").write_text(tests)
    binary = work / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library",
        "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
        str(work / "Tests.swift"), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
