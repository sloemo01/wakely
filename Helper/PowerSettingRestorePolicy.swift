import Foundation

/// Pure restoration policy shared by the pmset-backed helper operations.
/// A refused plan never writes and its caller must retain the recovery lease.
enum PowerSettingRestorePolicy {
    enum Plan: Equatable {
        case alreadyRestored
        case write(Int)
        case refuse(String)
    }

    static func plan(previous: String, written: String, current: Int?) -> Plan {
        guard let prior = token(previous), let owned = token(written) else {
            return .refuse("Invalid saved power setting value; the lease is retained.")
        }
        guard let current, (0...2).contains(current) else {
            return .refuse("Could not read current power setting; the lease is retained.")
        }
        if current == prior { return .alreadyRestored }
        guard current == owned else {
            return .refuse("Power setting ownership mismatch: refusing to overwrite an external change. The lease is retained.")
        }
        return .write(prior)
    }

    private static func token(_ text: String) -> Int? {
        switch text {
        case "0": return 0
        case "1": return 1
        case "2": return 2
        default: return nil
        }
    }
}
