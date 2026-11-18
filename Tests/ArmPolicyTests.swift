import Foundation

/// Standalone tests: compiled with ArmPolicy.swift, without the app or hardware APIs.
@main
struct ArmPolicyTests {
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
            ("idle state", testIdle),
            ("one-close opening ends arm and suppresses owners", testOneCloseOpening),
            ("persistent opening retains arm intent and lifetime", testPersistentOpening),
            ("only first successful activation publishes lifetime", testActivationLifetime),
            ("Caps preference maps true to one-close and false to persistent", testCapsLifetime),
            ("explicit disarm suppresses current owners", testExplicitDisarm),
            ("false/true edge permits a fresh automatic request", testFreshEdge),
            ("overlapping automatic owners release independently", testOverlap),
            ("manual takeover survives automatic release", testManualTakeover),
            ("manual request preserves suppression", testManualPreservesSuppression),
            ("timer session end suppresses current owners", testTimerEnd),
            ("new owner can arm while previous owner stays suppressed", testNewOwner),
        ]
        for (name, test) in tests {
            test()
            print("PASS: \(name)")
        }
        print("\(tests.count) ArmPolicy tests passed")
    }

    static func testOneCloseOpening() {
        var policy = ArmPolicy()
        policy.requestManual()
        policy.requestAutomatic("power")
        policy.recordActivation(lifetime: .oneClose, succeeded: true)
        expect(policy.shouldEndOnLidOpen, "Mode0 must end on opening")
        if policy.shouldEndOnLidOpen { policy.endSession() }
        expect(policy.sessionLifetime == nil && !policy.wantsArm, "Opening must end a one-close arm")
        expect(policy.suppressedOwners == ["power"], "Opening mode0 retains existing owner suppression")
    }

    static func testPersistentOpening() {
        var policy = ArmPolicy()
        policy.requestManual()
        policy.requestAutomatic("power")
        policy.recordActivation(lifetime: .persistent, succeeded: true)
        expect(!policy.shouldEndOnLidOpen, "Mode1 must survive opening")
        if policy.shouldEndOnLidOpen { policy.endSession() }
        expect(policy.sessionLifetime == .persistent && policy.wantsArm, "Opening must retain the persistent arm")
        expect(policy.manualHold && policy.isAutomaticOwner("power") && policy.suppressedOwners.isEmpty,
               "Opening mode1 must not end or suppress ownership")
        policy.endSession()
        expect(policy.sessionLifetime == nil && !policy.wantsArm, "Explicit/safety stop still ends mode1")
    }

    static func testActivationLifetime() {
        for first in [ArmSessionLifetime.oneClose, .persistent] {
            let other: ArmSessionLifetime = first == .oneClose ? .persistent : .oneClose
            var policy = ArmPolicy()
            policy.recordActivation(lifetime: other, succeeded: false)
            expect(policy.sessionLifetime == nil, "Failed first enable must not publish lifetime")
            policy.recordActivation(lifetime: first, succeeded: true)
            policy.recordActivation(lifetime: other, succeeded: true)
            expect(policy.sessionLifetime == first, "Repeated successful arm must preserve first lifetime")
            policy.recordActivation(lifetime: other, succeeded: false)
            expect(policy.sessionLifetime == first, "Failed arm must preserve active lifetime")
            policy.endActiveSession()
            policy.recordActivation(lifetime: other, succeeded: true)
            expect(policy.sessionLifetime == other, "A genuinely new session may choose a new lifetime")
        }
    }

    static func testCapsLifetime() {
        expect(ArmSessionLifetime.capsLock(oneClose: true) == .oneClose, "capsLockOneClose true requests mode0")
        expect(ArmSessionLifetime.capsLock(oneClose: false) == .persistent, "capsLockOneClose false requests mode1")
    }

    static func testIdle() {
        var policy = ArmPolicy()
        expect(!policy.manualHold && !policy.wantsArm, "Initial state must be idle")
        expect(policy.automaticOwners.isEmpty && policy.suppressedOwners.isEmpty, "Initial owner sets must be empty")
        expect(!policy.isAutomaticOwner("missing"), "Unknown owner must not be active")
        policy.releaseAutomatic("missing")
        policy.endSession()
        expect(!policy.wantsArm && policy.suppressedOwners.isEmpty, "Idle releases and session ends must be harmless")
    }

    static func testExplicitDisarm() {
        var policy = ArmPolicy()
        policy.requestAutomatic("power")
        policy.requestAutomatic("component")
        policy.requestManual()
        policy.endSession()
        expect(!policy.manualHold && !policy.wantsArm, "Explicit disarm must clear manual intent and suppress auto intent")
        expect(policy.automaticOwners == ["power", "component"], "Disarm must retain current automatic conditions")
        expect(policy.suppressedOwners == policy.automaticOwners, "Every current owner must be suppressed")
        expect(!policy.isAutomaticOwner("power") && !policy.isAutomaticOwner("component"), "Suppressed owners must not count as active")
        policy.requestAutomatic("power")
        expect(!policy.wantsArm, "Repeated true condition must not bypass explicit disarm")
    }

    static func testFreshEdge() {
        var policy = ArmPolicy()
        policy.requestAutomatic("power")
        policy.endSession()
        policy.releaseAutomatic("power")
        expect(policy.automaticOwners.isEmpty && policy.suppressedOwners.isEmpty, "False edge must clear ownership and suppression")
        expect(!policy.wantsArm, "False edge alone must stay disarmed")
        policy.requestAutomatic("power")
        expect(policy.wantsArm && policy.isAutomaticOwner("power"), "A fresh true edge must arm")
    }

    static func testOverlap() {
        var policy = ArmPolicy()
        policy.requestAutomatic("power")
        policy.requestAutomatic("component")
        policy.requestAutomatic("component")
        expect(policy.automaticOwners.count == 2, "Automatic requests must be idempotent")
        policy.releaseAutomatic("power")
        expect(policy.wantsArm && policy.isAutomaticOwner("component"), "Releasing one owner must preserve the other")
        expect(!policy.isAutomaticOwner("power"), "Released owner must no longer be active")
        policy.releaseAutomatic("component")
        expect(!policy.wantsArm, "Releasing the final owner must disarm without a manual hold")
    }

    static func testManualTakeover() {
        var policy = ArmPolicy()
        policy.requestAutomatic("power")
        policy.requestManual()
        policy.requestManual()
        policy.releaseAutomatic("power")
        expect(policy.manualHold && policy.wantsArm, "Manual takeover must survive release of the final automatic owner")
        expect(policy.automaticOwners.isEmpty, "Manual ownership must be independent of automatic ownership")
        policy.endSession()
        expect(!policy.wantsArm, "Ending session must release the manual hold")
    }

    static func testManualPreservesSuppression() {
        var policy = ArmPolicy()
        policy.requestAutomatic("power")
        policy.endSession()
        policy.requestManual()
        expect(policy.manualHold && policy.wantsArm, "A new manual request must arm")
        expect(policy.suppressedOwners == ["power"], "Manual request must not clear automatic suppression")
        expect(!policy.isAutomaticOwner("power"), "Manual arming must not revive a suppressed automatic owner")
        policy.endSession()
        expect(!policy.wantsArm && policy.suppressedOwners == ["power"], "Ending the manual session must leave prior automatic intent suppressed")
    }

    static func testTimerEnd() {
        var policy = ArmPolicy()
        policy.requestAutomatic("power")
        policy.requestManual()
        // A timer expiry uses the same endSession transition as explicit disarm.
        policy.endSession()
        policy.endSession()
        policy.requestAutomatic("power")
        expect(!policy.wantsArm && !policy.manualHold, "Timer expiry must prevent immediate rearming by a still-true condition")
        expect(policy.suppressedOwners == ["power"], "Repeated session end must preserve suppression")
        policy.releaseAutomatic("power")
        policy.requestAutomatic("power")
        expect(policy.wantsArm, "A fresh condition after timer expiry must be eligible again")
    }

    static func testNewOwner() {
        var policy = ArmPolicy()
        policy.requestAutomatic("power")
        policy.endSession()
        policy.requestAutomatic("component")
        expect(policy.wantsArm && policy.isAutomaticOwner("component"), "A newly active owner must be eligible")
        expect(!policy.isAutomaticOwner("power"), "Old owner must stay suppressed")
        policy.releaseAutomatic("component")
        expect(!policy.wantsArm, "Suppressed old ownership must not keep a new session armed")
        policy.endSession()
        expect(policy.suppressedOwners == ["power"], "Session end must retain suppression for remaining current owners")
    }
}
