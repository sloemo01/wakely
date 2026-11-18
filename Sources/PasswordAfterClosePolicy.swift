// PasswordAfterClosePolicy — the pure lifecycle behind "Password After Close".
//
// No AppKit, IOKit, helper client, UserDefaults or system call lives here. The
// runtime in ComponentBehaviors owns the persisted phase and performs the effects;
// this file only answers "may this trigger hand Touch ID back yet?" so the
// matrix can be compiled and exercised without touching a real Mac.
//
// The lifecycle:
//
//   idle
//     └─ close (component on, no external display) ─► turnOffPending
//   turnOffPending
//     ├─ helper confirmed the write ──────────────► off
//     ├─ next unlock observed first ─────────────► idle  (no late turn-off)
//     └─ quit / disable ─────────────────────────► idle  (nothing to undo)
//   off
//     ├─ promised unlock / lid open or wake, not locked ─► restorePending
//     ├─ quit / disable ─────────────────────────────────► restorePending
//     └─ lid open or wake while still locked ────────────► off (wait)
//   restorePending
//     ├─ helper confirmed the restore ───────────► idle
//     └─ helper failed ──────────────────────────► restorePending (asked again)
//
// `turnOffPending` means "a close is standing but Touch ID may still be on".
// It is never turned off after an unlock and never restored while locked.

import Foundation

struct PasswordAfterClosePolicy {

    /// One close, one lifecycle. The id makes repeated notifications for the
    /// same close idempotent and lets a persisted phase be matched after a
    /// relaunch.
    enum Phase: Equatable {
        case idle
        case turnOffPending(closeID: UUID)
        case off(closeID: UUID)
        case restorePending(closeID: UUID)
    }

    /// Wire format for UserDefaults. Kept as plain strings so a phase survives
    /// a relaunch without making the policy depend on a persistence API.
    struct PersistedPhase: Equatable {
        let name: String
        let closeID: String?
    }

    static let idleName = "idle"
    static let turnOffPendingName = "turnOffPending"
    static let offName = "off"
    static let restorePendingName = "restorePending"

    // MARK: - Close gate

    /// Closing the lid is this component's whole trigger, so it applies even when
    /// Wakely is not armed. An external display means the close is a normal
    /// desktop session: the original promises that "closing the lid changes
    /// nothing" there.
    func shouldTurnOff(componentEnabled: Bool, externalDisplay: Bool) -> Bool {
        componentEnabled && !externalDisplay
    }

    // MARK: - Phase queries

    static func closeID(of phase: Phase) -> UUID? {
        switch phase {
        case .idle: return nil
        case .turnOffPending(let closeID), .off(let closeID), .restorePending(let closeID):
            return closeID
        }
    }

    /// A close with a hand-back still owed: Touch ID may be off, or was
    /// requested off but not confirmed. Idle has nothing to settle.
    static func owesHandBack(_ phase: Phase) -> Bool { closeID(of: phase) != nil }

    static func isTurnOffPending(_ phase: Phase) -> Bool {
        if case .turnOffPending = phase { return true }
        return false
    }

    /// Touch ID was confirmed off (or a restore is already in flight).
    static func hasAppliedTurnOff(_ phase: Phase) -> Bool {
        switch phase {
        case .off, .restorePending: return true
        case .idle, .turnOffPending: return false
        }
    }

    // MARK: - Restore triggers

    /// The promised unlock happened. This is the only trigger that says the
    /// user is demonstrably back; it restores only after the write landed.
    func shouldRestoreOnUnlock(phase: Phase) -> Bool {
        Self.hasAppliedTurnOff(phase)
    }

    /// Opening the lid restores only when the screen is provably not locked.
    /// A locked screen after opening means the password prompt is still up:
    /// touching Touch ID now would break the promise. `nil` (unreadable lock
    /// state) is treated exactly like "locked" here, never as unlocked.
    func shouldRestoreOnLidOpen(isLocked: Bool?, phase: Phase) -> Bool {
        guard isLocked == false else { return false }
        return Self.hasAppliedTurnOff(phase)
    }

    /// The same rule applies to a wake: an unlock is evidence, a wake is not.
    func shouldRestoreOnWake(isLocked: Bool?, phase: Phase) -> Bool {
        guard isLocked == false else { return false }
        return Self.hasAppliedTurnOff(phase)
    }

    /// Quitting and disabling are unconditional: they are never gated on the
    /// lock state. The caller still settles `turnOffPending` without a helper
    /// call, and only contacts the helper when a hand-back is owed.
    func shouldRestoreOnQuit(phase: Phase) -> Bool { true }

    func shouldRestoreOnDisable(phase: Phase) -> Bool { true }

    // MARK: - Late turn-off

    /// A close whose helper was unreachable stays pending. If any unlock is
    /// observed first, the late turn-off is dropped: Touch ID is never turned
    /// off after an unlock, even for a close that is still nominally standing.
    func shouldCancelLateTurnOff(unlockedSinceClose: Bool, phase: Phase) -> Bool {
        unlockedSinceClose && Self.isTurnOffPending(phase)
    }

    /// Retry a late turn-off only while the close still stands and the screen
    /// is locked. `lidClosed` covers a shut lid; an open lid with a locked
    /// screen is the just-reopened case. Any unlocked/unknown state means no
    /// retry, because turning Touch ID off then would be a new lockout rather
    /// than the promise made at close. The helper must be reachable to retry.
    func shouldRetryTurnOff(lidClosed: Bool, isLocked: Bool?, helperReachable: Bool,
                            phase: Phase) -> Bool {
        guard Self.isTurnOffPending(phase) else { return false }
        guard helperReachable else { return false }
        guard isLocked == true else { return false }
        return lidClosed || isLocked == true
    }

    // MARK: - Persistence format

    static func persist(_ phase: Phase) -> PersistedPhase {
        switch phase {
        case .idle:
            return PersistedPhase(name: idleName, closeID: nil)
        case .turnOffPending(let closeID):
            return PersistedPhase(name: turnOffPendingName, closeID: closeID.uuidString)
        case .off(let closeID):
            return PersistedPhase(name: offName, closeID: closeID.uuidString)
        case .restorePending(let closeID):
            return PersistedPhase(name: restorePendingName, closeID: closeID.uuidString)
        }
    }

    /// A missing, unknown or malformed record is idle, never a guessed phase.
    /// In particular a phase name without a usable close id cannot be acted on.
    static func restore(from name: String?, closeID: String?) -> Phase {
        guard let name, let rawID = closeID, let id = UUID(uuidString: rawID) else { return .idle }
        switch name {
        case turnOffPendingName: return .turnOffPending(closeID: id)
        case offName: return .off(closeID: id)
        case restorePendingName: return .restorePending(closeID: id)
        default: return .idle
        }
    }
}
