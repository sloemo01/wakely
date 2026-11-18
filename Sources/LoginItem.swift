// LoginItem — the relaunch/login registration for the components that need
// Wakely back after a restart.
//
// Home Server, Password After Close and Sleep Until Reset share one login item
// (`SMAppService.mainApp`). Registration is gated on HomeServerPolicy; removal
// only happens when no such component is enabled and this build owns the item, so
// a login item the user added by hand is left alone.
//
// Everything here is best-effort and honest: the system may require approval in
// System Settings > Login Items, and a failed registration is logged rather than
// blocking launch. Tests never execute this file (it is compiled for type
// checking only; the pure policy tests link HomeServerPolicy alone).

import Foundation
import ServiceManagement

@MainActor
enum LoginItem {

    enum Status: String, Equatable {
        case enabled
        case requiresApproval
        case notFound
        case unknown

        var label: String {
            switch self {
            case .enabled: return "registered and enabled"
            case .requiresApproval: return "awaiting approval in System Settings > Login Items"
            case .notFound: return "not registered"
            case .unknown: return "status unknown"
            }
        }

        /// The system knows about an item (even a pending one).
        var exists: Bool { self == .enabled || self == .requiresApproval }
    }

    /// Marks an item this build registered. It is the only evidence used to
    /// decide that removal is ours to perform; a pre-existing item is left to
    /// whoever created it.
    private static let ownedKey = "loginItem.registeredByWakely"
    private static var lastLoggedStatus: Status?

    // MARK: - Status

    static func status() -> Status {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // `.notRegistered` and `.notFound` both mean "no usable item": one is
        // absent, the other could not be found. Neither is a successful launch.
        case .notRegistered, .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    private static var ownsRegistration: Bool {
        get { UserDefaults.standard.bool(forKey: ownedKey) }
        set { UserDefaults.standard.set(newValue, forKey: ownedKey) }
    }

    // MARK: - Register / unregister

    /// Register when needed. Returns true only when the system reports the item
    /// enabled right now; pending approval is reported, not claimed.
    @discardableResult
    static func ensureRegistered(reason: String) -> Bool {
        let before = status()
        switch before {
        case .enabled:
            logStatus(before, reason: reason, changed: false)
            return true
        case .requiresApproval:
            logApproval(reason: reason)
            return false
        case .notFound, .unknown:
            break
        }

        do {
            try SMAppService.mainApp.register()
        } catch {
            Diagnostics.log("relaunch agent: registration failed (\(reason)): \(error.localizedDescription)")
            return false
        }

        let after = status()
        if after.exists { ownsRegistration = true }
        switch after {
        case .enabled:
            logStatus(after, reason: reason, changed: true)
            return true
        case .requiresApproval:
            logApproval(reason: reason)
            return false
        case .notFound, .unknown:
            Diagnostics.log("relaunch agent: registration did not take effect (\(reason)); \(after.label)")
            return false
        }
    }

    /// Remove the item this build owns. Never called while a relevant component is
    /// enabled: `sync` is the gate, and this method is also safe if it is.
    static func unregister(reason: String) {
        guard status().exists else {
            ownsRegistration = false
            return
        }
        do {
            try SMAppService.mainApp.unregister()
            ownsRegistration = false
            Diagnostics.log("relaunch agent: removed (\(reason))")
        } catch {
            Diagnostics.log("relaunch agent: removal failed (\(reason)): \(error.localizedDescription)")
        }
    }

    // MARK: - Component enablement gate

    /// Keep one login item while any restart-sensitive component is on. When none
    /// is on, remove it only if this build registered it (the ownership marker),
    /// so a login item the user added through the separate launch-at-login
    /// preference is never removed from here.
    static func sync(enabledComponentIDs: Set<String>, reason: String) {
        // A user who removed the item by hand must not leave a stale claim that
        // would make a later unregister look meaningful.
        if !status().exists, ownsRegistration { ownsRegistration = false }

        if HomeServerPolicy.shouldRegisterLoginItem(enabledComponentIDs: enabledComponentIDs) {
            ensureRegistered(reason: reason)
            return
        }
        guard ownsRegistration else { return }
        unregister(reason: reason)
    }

    // MARK: - Logging

    private static func logStatus(_ status: Status, reason: String, changed: Bool) {
        // Avoid repeating the same line on every unrelated component flip.
        guard changed || lastLoggedStatus != status else { return }
        lastLoggedStatus = status
        Diagnostics.log("relaunch agent: \(status.label) (\(reason))")
    }

    private static func logApproval(reason: String) {
        guard lastLoggedStatus != .requiresApproval else { return }
        lastLoggedStatus = .requiresApproval
        Diagnostics.log("relaunch agent: awaiting approval in System Settings > Login Items; running without relaunch protection (\(reason)). macOS asks you once to allow Wakely in Login Items.")
    }
}
