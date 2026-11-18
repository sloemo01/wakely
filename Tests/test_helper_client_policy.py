"""Compile and run only the injected helper-client policy; no AppKit, SMAppService or XPC."""
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Sources/HelperClient.swift").read_text()
policy = source.split("// BEGIN TESTABLE HELPER POLICY\n", 1)[1].split(
    "// END TESTABLE HELPER POLICY", 1
)[0]

tests = (root / "Tests/HelperClientPolicy.swift").read_text()
generated = tests.split("// BEGIN GENERATED HELPER POLICY\n", 1)[1].split(
    "// END GENERATED HELPER POLICY", 1
)[0]
assert generated.strip("\n") == policy.strip("\n"), (
    "Tests/HelperClientPolicy.swift is out of sync with the testable policy block "
    "in Sources/HelperClient.swift; regenerate its generated section."
)
assert "import AppKit" not in policy and "NSWorkspace" not in policy, (
    "the testable block must not depend on AppKit"
)
assert "import ServiceManagement" not in policy and "SMAppService." not in policy, (
    "the testable block must not depend on ServiceManagement"
)
assert "NSXPCConnection" not in policy, "the testable block must not open XPC connections"
assert "register(" not in policy and "unregister(" not in policy, (
    "the testable block must not register or unregister a service"
)

assert "SMAppService" in policy, (
    "the policy must point at the supported SMAppService path"
)
assert "static func requiresAdministratorFallback" in policy, (
    "the fallback decision function must remain for existing callers"
)
fallback_body = policy.split("static func requiresAdministratorFallback", 1)[1].split(
    "\n    }", 1
)[0]
assert "guard signatureFailure" in fallback_body and "return true" in fallback_body, (
    "a signature failure must allow the explicit administrator install"
)
assert "func installWithAdministratorPrompt() async -> Result<Void, Error> {" in source, (
    "the administrator install entry point must remain present"
)
install_body = source.split(
    "func installWithAdministratorPrompt() async -> Result<Void, Error> {", 1
)[1].split("\n    }", 1)[0]
assert "administratorInstallPlan" in install_body, (
    "the administrator install must use the validated standalone helper plan"
)
assert "runAdministratorCommand" in install_body, (
    "the administrator install must use exactly one osascript authorization"
)
assert "peerURL" in install_body and "cdhash" in install_body, (
    "the administrator install must write the ad-hoc peer cdhash file"
)
assert "static func administratorInstallPlan(" in policy, (
    "the standalone administrator installer must be in the testable policy"
)
assert "static func installPlan(" in policy, (
    "the rejected BundleProgram builder must be retained with its validation tests"
)
assert "HelperInstallCommandBuilder.installPlan(" not in source, (
    "the rejected BundleProgram builder must not be wired to an install action"
)
assert "static func installPlan(" in policy, (
    "the rejected builder must be kept, unused, with its validation tests"
)
assert "HelperInstallCommandBuilder.installPlan(" not in source, (
    "the rejected install builder must not be wired to any install action"
)
assert 'details: ["transportUncertain": "yes"]' in source, (
    "transport failures must keep the transportUncertain tag"
)

# Protocol 3: helper-owned one-off wakes. The app-side surface is three narrow
# methods on the validated `perform` path, and the policy block validates the
# date/component shape before any XPC connection exists.
assert "func scheduleWake(at date: Date, componentID: String = \"sleepUntilReset\") async -> HelperRequestReceipt" in source, (
    "the component API must expose scheduleWake(at:) with the documented owner default"
)
assert "func cancelWake(at date: Date) async -> HelperRequestReceipt" in source, (
    "the component API must expose cancelWake(at:)"
)
assert "func wakeSchedules() async -> [OwnedWake]" in source, (
    "the component API must expose wakeSchedules()"
)
assert "func wakeScheduleSnapshot() async -> HelperWakeScheduleSnapshot" in source, (
    "reconciliation needs the reply outcome as well as the parsed wakes"
)
assert "operation: .scheduleWake" in source and "dateValue: date.timeIntervalSince1970" in source, (
    "scheduleWake must send the instant through the validated request path"
)
assert "operation: .cancelWake" in source and "operation: .wakeSchedules" in source, (
    "cancelWake and wakeSchedules must be plain validated requests"
)
assert "dateValue: request.dateValue" in source, (
    "perform() must pass the request's date into the pure policy"
)
assert "HelperWakeSchedulePolicy.parse(details:" in source, (
    "wakeSchedules details must be parsed by the pure policy"
)
wake_api = source.split("// MARK: - Helper-owned one-off wakes (protocol 3)", 1)[1].split(
    "private func perform(_ request: HelperRequest)", 1
)[0]
wake_api = re.sub(r"//[^\n]*", "", wake_api)
for forbidden in ("Process(", "NSXPCConnection", "/usr/bin/", "pmset"):
    assert forbidden not in wake_api, (
        f"the wake API must not reach {forbidden!r}; the helper owns the command"
    )
for entry in ('case "scheduleWake", "cancelWake":', 'case "wakeSchedules":'):
    assert entry in policy, f"the policy must validate {entry}"
assert "requires a wake time as Unix epoch seconds" in policy, (
    "scheduleWake/cancelWake must require a date"
)
assert "requires a finite wake time" in policy, (
    "a non-finite wake date must be rejected"
)
assert "does not take a date value" in policy, (
    "operations that own no date must reject a stray one"
)
assert "dateValue: Double? = nil" in policy, (
    "the defaulted date parameter keeps every older call site compiling"
)

with tempfile.TemporaryDirectory(prefix="wakely-helper-client-tests-") as directory:
    work = Path(directory)
    (work / "Tests.swift").write_text(tests)
    binary = work / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
        str(work / "Tests.swift"), "-o", str(binary)
    ], check=True)
    subprocess.run([str(binary)], check=True)
