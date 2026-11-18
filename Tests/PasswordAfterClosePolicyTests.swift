import Foundation

/// Standalone matrix for PasswordAfterClosePolicy. Compiled with the policy file
/// alone: no AppKit, no ScreenLockObserver, no helper, no UserDefaults, no device.
@main
struct PasswordAfterClosePolicyTests {
    static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard condition() else { fatalError(message, file: file, line: line) }
    }

    static func main() {
        let tests: [(String, () -> Void)] = [
            ("close gate needs the component and no external display", closeGate),
            ("phase identity and hand-back debt", phaseIdentity),
            ("persisted phase round-trips and malformed records are idle", persistence),
            ("unlock restores only a confirmed turn-off", unlockTrigger),
            ("lid open restores only when provably unlocked", lidOpenMatrix),
            ("wake restores only when provably unlocked", wakeMatrix),
            ("quit and disable are unconditional", quitAndDisable),
            ("late turn-off is cancelled by any unlock", cancelLateTurnOff),
            ("late turn-off retries only while the close stands and is locked", retryMatrix),
            ("close -> pending -> unlock cancels without a write", lateTurnOffLifecycle),
            ("close -> off -> locked lid open waits for unlock", lockedLidLifecycle),
            ("close -> off -> quit restores", quitLifecycle),
            ("close -> pending -> disable cancels an unwritten change", disableLifecycle),
        ]
        for (name, test) in tests {
            test()
            print("PASS: \(name)")
        }
        print("\(tests.count) PasswordAfterClosePolicy tests passed")
    }

    // MARK: - Gates

    static func closeGate() {
        let policy = PasswordAfterClosePolicy()
        expect(policy.shouldTurnOff(componentEnabled: true, externalDisplay: false),
               "an enabled component on a plain close must turn Touch ID off")
        expect(!policy.shouldTurnOff(componentEnabled: true, externalDisplay: true),
               "an external display makes the close a normal desktop session")
        expect(!policy.shouldTurnOff(componentEnabled: false, externalDisplay: false),
               "a disabled component must not act on a close")
        expect(!policy.shouldTurnOff(componentEnabled: false, externalDisplay: true),
               "a disabled component does nothing even with an external display")
    }

    static func phaseIdentity() {
        typealias P = PasswordAfterClosePolicy
        let id = UUID()
        expect(P.closeID(of: .idle) == nil, "idle has no close id")
        expect(!P.owesHandBack(.idle), "idle owes no hand-back")
        expect(!P.hasAppliedTurnOff(.idle), "idle has no applied turn-off")
        expect(P.isTurnOffPending(.idle) == false, "idle is not a pending turn-off")

        for phase in [P.Phase.turnOffPending(closeID: id), .off(closeID: id),
                      .restorePending(closeID: id)] {
            expect(P.closeID(of: phase) == id, "every non-idle phase keeps its close id")
            expect(P.owesHandBack(phase), "every non-idle phase owes a hand-back")
        }
        expect(P.isTurnOffPending(.turnOffPending(closeID: id)), "pending phase is pending")
        expect(!P.hasAppliedTurnOff(.turnOffPending(closeID: id)),
               "a pending turn-off has not written anything")
        expect(P.hasAppliedTurnOff(.off(closeID: id)), "off is a confirmed write")
        expect(P.hasAppliedTurnOff(.restorePending(closeID: id)),
               "a restore in flight still represents a written turn-off")
        expect(P.isTurnOffPending(.off(closeID: id)) == false, "off is not pending")
        expect(P.isTurnOffPending(.restorePending(closeID: id)) == false,
               "restore pending is not pending turn-off")
    }

    static func persistence() {
        typealias P = PasswordAfterClosePolicy
        let id = UUID()
        let phases: [P.Phase] = [.idle, .turnOffPending(closeID: id), .off(closeID: id),
                                 .restorePending(closeID: id)]
        for phase in phases {
            let record = P.persist(phase)
            let restored = P.restore(from: record.name, closeID: record.closeID)
            expect(restored == phase, "phase \(record.name) must round-trip through persistence")
        }
        expect(P.persist(.idle).closeID == nil, "idle persists no close id")
        expect(P.restore(from: nil, closeID: id.uuidString) == .idle,
               "a missing phase name is idle")
        expect(P.restore(from: "off", closeID: nil) == .idle,
               "a phase without a close id cannot be acted on")
        expect(P.restore(from: "off", closeID: "not-a-uuid") == .idle,
               "a malformed close id is idle, never a guess")
        expect(P.restore(from: "somethingElse", closeID: id.uuidString) == .idle,
               "an unknown phase name is idle")
    }

    // MARK: - Restore triggers

    static func unlockTrigger() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        expect(policy.shouldRestoreOnUnlock(phase: .off(closeID: id)),
               "the promised unlock restores a confirmed turn-off")
        expect(policy.shouldRestoreOnUnlock(phase: .restorePending(closeID: id)),
               "a pending restore is asked again on the next unlock")
        expect(!policy.shouldRestoreOnUnlock(phase: .turnOffPending(closeID: id)),
               "an unlock while the turn-off is unconfirmed cancels, it does not restore")
        expect(!policy.shouldRestoreOnUnlock(phase: .idle), "idle has nothing to restore")
    }

    static func lidOpenMatrix() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        let applied: [P.Phase] = [.off(closeID: id), .restorePending(closeID: id)]
        for phase in applied {
            expect(policy.shouldRestoreOnLidOpen(isLocked: false, phase: phase),
                   "lid open with a proven unlocked screen restores \(phase)")
            expect(!policy.shouldRestoreOnLidOpen(isLocked: true, phase: phase),
                   "lid open while the password prompt is up must not restore \(phase)")
            expect(!policy.shouldRestoreOnLidOpen(isLocked: nil, phase: phase),
                   "an unknown lock state must never be treated as unlocked (\(phase))")
        }
        for phase in [P.Phase.turnOffPending(closeID: id), .idle] {
            for locked in [false, true, nil] as [Bool?] {
                expect(!policy.shouldRestoreOnLidOpen(isLocked: locked, phase: phase),
                       "lid open cannot restore a phase with no applied turn-off")
            }
        }
    }

    static func wakeMatrix() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        let applied: [P.Phase] = [.off(closeID: id), .restorePending(closeID: id)]
        for phase in applied {
            expect(policy.shouldRestoreOnWake(isLocked: false, phase: phase),
                   "a wake with a proven unlocked screen restores \(phase)")
            expect(!policy.shouldRestoreOnWake(isLocked: true, phase: phase),
                   "a wake with the screen locked keeps Touch ID off (\(phase))")
            expect(!policy.shouldRestoreOnWake(isLocked: nil, phase: phase),
                   "a wake with an unknown lock state keeps Touch ID off (\(phase))")
        }
        for phase in [P.Phase.turnOffPending(closeID: id), .idle] {
            for locked in [false, true, nil] as [Bool?] {
                expect(!policy.shouldRestoreOnWake(isLocked: locked, phase: phase),
                       "a wake cannot restore a phase with no applied turn-off")
            }
        }
    }

    static func quitAndDisable() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        for phase in [P.Phase.idle, .turnOffPending(closeID: id), .off(closeID: id),
                      .restorePending(closeID: id)] {
            expect(policy.shouldRestoreOnQuit(phase: phase),
                   "quit is unconditional, regardless of the lock or phase")
            expect(policy.shouldRestoreOnDisable(phase: phase),
                   "disable is unconditional, regardless of the lock or phase")
        }
    }

    static func cancelLateTurnOff() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        expect(policy.shouldCancelLateTurnOff(unlockedSinceClose: true,
                                              phase: .turnOffPending(closeID: id)),
               "an unlock before the late turn-off must cancel it")
        expect(!policy.shouldCancelLateTurnOff(unlockedSinceClose: false,
                                               phase: .turnOffPending(closeID: id)),
               "no unlock observed means the late turn-off may still be retried")
        expect(!policy.shouldCancelLateTurnOff(unlockedSinceClose: true,
                                               phase: .off(closeID: id)),
               "a confirmed turn-off is restored, not cancelled")
        expect(!policy.shouldCancelLateTurnOff(unlockedSinceClose: true,
                                               phase: .restorePending(closeID: id)),
               "a pending restore is not a pending turn-off")
        expect(!policy.shouldCancelLateTurnOff(unlockedSinceClose: true, phase: .idle),
               "idle has no late turn-off to cancel")
    }

    static func retryMatrix() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        let pending = P.Phase.turnOffPending(closeID: id)

        expect(policy.shouldRetryTurnOff(lidClosed: true, isLocked: true,
                                         helperReachable: true, phase: pending),
               "a shut lid with a locked screen and a reachable helper retries")
        expect(policy.shouldRetryTurnOff(lidClosed: false, isLocked: true,
                                         helperReachable: true, phase: pending),
               "a just-reopened session that is still locked retries")
        expect(!policy.shouldRetryTurnOff(lidClosed: true, isLocked: false,
                                          helperReachable: true, phase: pending),
               "an unlocked screen means the close no longer stands")
        expect(!policy.shouldRetryTurnOff(lidClosed: false, isLocked: false,
                                          helperReachable: true, phase: pending),
               "an open, unlocked lid never retries a turn-off")
        expect(!policy.shouldRetryTurnOff(lidClosed: true, isLocked: nil,
                                          helperReachable: true, phase: pending),
               "an unknown lock state never retries")
        expect(!policy.shouldRetryTurnOff(lidClosed: true, isLocked: true,
                                          helperReachable: false, phase: pending),
               "an unreachable helper cannot apply a retry")
        for phase in [P.Phase.off(closeID: id), .restorePending(closeID: id), .idle] {
            expect(!policy.shouldRetryTurnOff(lidClosed: true, isLocked: true,
                                              helperReachable: true, phase: phase),
                   "only turnOffPending may retry")
        }
    }

    // MARK: - Lifecycle simulations

    static func lateTurnOffLifecycle() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        // Close, helper away.
        var phase = P.Phase.turnOffPending(closeID: id)
        expect(P.owesHandBack(phase), "the close is still standing")
        expect(!policy.shouldRetryTurnOff(lidClosed: true, isLocked: true,
                                          helperReachable: false, phase: phase),
               "with the helper away there is no retry to make yet")
        expect(policy.shouldRetryTurnOff(lidClosed: true, isLocked: true,
                                         helperReachable: true, phase: phase),
               "once the helper is back, a close that still stands retries")
        // The user unlocks before the helper returns.
        expect(policy.shouldCancelLateTurnOff(unlockedSinceClose: true, phase: phase),
               "the unlock cancels the pending write")
        phase = .idle
        expect(!P.owesHandBack(phase), "nothing remains owed after the cancel")
        expect(!P.hasAppliedTurnOff(phase), "no Touch ID write is claimed after a cancel")
    }

    static func lockedLidLifecycle() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        var phase = P.Phase.turnOffPending(closeID: id)
        // Helper confirmed the write.
        phase = .off(closeID: id)
        // Lid opens onto the password prompt.
        expect(!policy.shouldRestoreOnLidOpen(isLocked: true, phase: phase),
               "a locked lid open keeps Touch ID off")
        expect(!policy.shouldRestoreOnWake(isLocked: true, phase: phase),
               "a locked wake keeps Touch ID off")
        // The promised unlock happens.
        expect(policy.shouldRestoreOnUnlock(phase: phase), "the unlock restores")
        phase = .restorePending(closeID: id)
        expect(policy.shouldRestoreOnUnlock(phase: phase),
               "a restore that failed is asked again on the next unlock")
        phase = .idle
        expect(!P.owesHandBack(phase), "a confirmed restore settles the lifecycle")
    }

    static func quitLifecycle() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        let phase = P.Phase.off(closeID: id)
        expect(policy.shouldRestoreOnQuit(phase: phase), "quit restores the confirmed turn-off")
        expect(P.hasAppliedTurnOff(phase), "quit has a write to undo")
        let pending = P.Phase.turnOffPending(closeID: id)
        expect(policy.shouldRestoreOnQuit(phase: pending),
               "quit is unconditional, but the caller has no write to undo")
        expect(!P.hasAppliedTurnOff(pending), "the pending write is never reported as applied")
    }

    static func disableLifecycle() {
        typealias P = PasswordAfterClosePolicy
        let policy = P()
        let id = UUID()
        let pending = P.Phase.turnOffPending(closeID: id)
        expect(policy.shouldRestoreOnDisable(phase: pending), "disable is unconditional")
        expect(!P.hasAppliedTurnOff(pending),
               "a pending turn-off is cancelled without inventing a restore")
        let off = P.Phase.off(closeID: id)
        expect(policy.shouldRestoreOnDisable(phase: off), "disable restores a confirmed turn-off")
        expect(P.hasAppliedTurnOff(off), "a confirmed turn-off is present to restore")
    }
}
