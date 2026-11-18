import Foundation

/// Original armSessionMode: 0 ends on opening; 1 survives opening.
/// This is an in-process lifetime, not a relaunch/restoration preference.
enum ArmSessionLifetime {
    case oneClose
    case persistent

    static func capsLock(oneClose: Bool) -> Self {
        oneClose ? .oneClose : .persistent
    }
}

/// Tracks manual and automatic arming intent independently of hardware state.
struct ArmPolicy {
    private(set) var sessionLifetime: ArmSessionLifetime?

    var shouldEndOnLidOpen: Bool { sessionLifetime == .oneClose }

    /// Only the first successful enable publishes the mode. Failed and repeated
    /// requests cannot change the lifetime of an existing session.
    mutating func recordActivation(lifetime: ArmSessionLifetime, succeeded: Bool) {
        guard succeeded, sessionLifetime == nil else { return }
        sessionLifetime = lifetime
    }

    mutating func endActiveSession() { sessionLifetime = nil }

    private(set) var manualHold = false
    private(set) var automaticOwners: Set<String> = []
    private(set) var suppressedOwners: Set<String> = []

    var wantsArm: Bool {
        manualHold || !automaticOwners.subtracting(suppressedOwners).isEmpty
    }

    mutating func requestManual() {
        manualHold = true
    }

    mutating func requestAutomatic(_ owner: String) {
        automaticOwners.insert(owner)
    }

    mutating func releaseAutomatic(_ owner: String) {
        automaticOwners.remove(owner)
        suppressedOwners.remove(owner)
    }

    /// Ends either an explicitly disarmed or an expired session. Existing
    /// automatic owners must release before a fresh request can arm again.
    mutating func endSession() {
        endActiveSession()
        manualHold = false
        suppressedOwners.formUnion(automaticOwners)
    }

    func isAutomaticOwner(_ owner: String) -> Bool {
        automaticOwners.contains(owner) && !suppressedOwners.contains(owner)
    }
}
