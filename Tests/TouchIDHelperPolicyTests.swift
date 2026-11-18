import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

expect(TouchIDHelperPolicy.path == "/usr/bin/bioutil", "fixed executable")
expect(TouchIDHelperPolicy.readArguments == ["-r", "-s"], "exact original system read")
expect(TouchIDHelperPolicy.writeArguments(false) == ["-w", "-s", "-u", "0"], "exact disable")
expect(TouchIDHelperPolicy.writeArguments(true) == ["-w", "-s", "-u", "1"], "exact enable")
expect(TouchIDHelperPolicy.parse(" \tBiometrics for unlock: \t1\r\n") == true, "trim configured field")
expect(TouchIDHelperPolicy.parse("Biometrics for unlock:0") == false, "zero")
expect(TouchIDHelperPolicy.parse("Effective Biometrics for unlock: 0\nBiometrics for unlock: 1") == true, "effective is not configured")
for text in ["", "Touch ID for unlock: 1", "Other unlock: 1", "biometrics for unlock: 1", "Biometrics for unlock: 2", "Biometrics for unlock: true", "Biometrics for unlock: 1 extra", "Biometrics for unlock: (1)", "Biometrics for unlock: 01", "Biometrics for unlock: 1\nBiometrics for unlock: 0", "Biometrics for unlock: 1\nBiometrics for unlock: 1"] {
    expect(TouchIDHelperPolicy.parse(text) == nil, "fail closed: \(text)")
}
for previous in ["0", "1"] {
    for written in ["0", "1"] {
        let current = written == "1"
        expect(TouchIDHelperPolicy.restoreError(operation: TouchIDHelperPolicy.operation, previous: previous, written: written, current: current) == nil, "owned system lease can restore")
        expect(TouchIDHelperPolicy.restoreError(operation: TouchIDHelperPolicy.operation, previous: previous, written: written, current: !current)?.contains("ownership mismatch") == true, "external changes retained")
    }
}
expect(TouchIDHelperPolicy.restoreError(operation: "touchIDUnlock", previous: "1", written: "0", current: false)?.contains("manual recovery") == true, "legacy lease quarantined")
expect(TouchIDHelperPolicy.restoreError(operation: "touchIDUnlock.system.v2", previous: "1", written: "0", current: false) != nil, "unknown versions rejected")
expect(TouchIDHelperPolicy.restoreError(operation: TouchIDHelperPolicy.operation, previous: "1", written: "0", current: nil) != nil, "read failure retains lease")
for invalid in ["true", "yes", " 1", "2", ""] {
    expect(TouchIDHelperPolicy.restoreError(operation: TouchIDHelperPolicy.operation, previous: invalid, written: "0", current: false) != nil, "bad baseline")
    expect(TouchIDHelperPolicy.restoreError(operation: TouchIDHelperPolicy.operation, previous: "1", written: invalid, current: false) != nil, "bad ownership value")
}
print("PASS: pure Touch ID helper command, parser, version and ownership policy; no bioutil execution")
