import Foundation

// The app target defines this enum in Sources/HelperClient.swift. The recovery
// policy test is compiled from ProtectedRecoveryPolicy.swift alone (see
// Tests/run-tests.sh), so this harness mirrors the wire vocabulary. The parser
// that produces these cases is tested separately by test_helper_client_policy.py.
enum HelperRequestOutcome: Equatable {
    case succeeded(leaseComponent: String?)
    case failedBeforeMutation
    case failedWithRecoveryLease(leaseComponent: String?)
    case interruptedUnknown
    case accepted
    case running
    case unknown
}

@main
struct ProtectedRecoveryPolicyTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        typealias P = ProtectedRecoveryPolicy
        legacyForwarding()
        authoritativeMatrix()
        precedence()
        legacyMigration()
        // Initial forced target must be eligible for the idle governor's handback.
        expect(P.fanForcedAfterInitialApply(componentID: "fanBoost", replyOK: true),
               "a confirmed initial fan write owns the governor handback")
        expect(!P.fanForcedAfterInitialApply(componentID: "fanBoost", replyOK: false),
               "a failed fan write does not own the governor handback")
        expect(!P.fanForcedAfterInitialApply(componentID: "lowPowerWhileClosed", replyOK: true),
               "only fanBoost starts forced fan state")
        print("Protected recovery tests passed (authoritative outcomes, legacy fallback, migration, fan state)")
    }

    /// Every old call must keep its exact answer now that it is a forwarding
    /// overload into the authoritative form with a nil outcome.
    static func legacyForwarding() {
        typealias P = ProtectedRecoveryPolicy
        for transportUncertain in [false, true] {
            for statusOK in [false, true] {
                for hasLeaseReport in [false, true] {
                    for reportsComponentLease in [false, true] {
                        let old = P.decision(
                            transportUncertain: transportUncertain,
                            statusOK: statusOK,
                            hasLeaseReport: hasLeaseReport,
                            reportsComponentLease: reportsComponentLease)
                        let forwarded = P.decision(
                            outcome: nil,
                            transportUncertain: transportUncertain,
                            statusOK: statusOK,
                            hasLeaseReport: hasLeaseReport,
                            reportsComponentLease: reportsComponentLease)
                        expect(old == forwarded,
                               "nil outcome must forward to the legacy decision")
                        let unknown = P.decision(
                            outcome: .unknown,
                            transportUncertain: transportUncertain,
                            statusOK: statusOK,
                            hasLeaseReport: hasLeaseReport,
                            reportsComponentLease: reportsComponentLease)
                        expect(old == unknown,
                               ".unknown must keep the legacy decision exactly")
                    }
                }
            }
        }

        // Timeout before backup creation: concurrent status absence is NOT proof
        // of no future write; no invented lease and no repeated apply allowed.
        expect(P.decision(transportUncertain: true, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: false) == .retryProbe,
               "uncertain completion is not settled by status absence")
        // Daemon-completed failure before save: no lease => do not restore a
        // setting this component never owned.
        expect(P.decision(transportUncertain: false, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: false) == .settledWithoutLease,
               "a completed non-lease failure may settle without a lease")
    }

    static func authoritativeMatrix() {
        typealias P = ProtectedRecoveryPolicy

        // .succeeded: adopt only when the outcome itself names a lease.
        expect(P.decision(outcome: .succeeded(leaseComponent: "fanBoost"),
                          transportUncertain: true, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: false) == .adoptLease,
               "succeeded with a lease adopts it")
        expect(P.decision(outcome: .succeeded(leaseComponent: nil),
                          transportUncertain: true, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: true) == .settledWithoutLease,
               "succeeded without a lease settles")

        // .failedWithRecoveryLease always adopts, even without a named component.
        expect(P.decision(outcome: .failedWithRecoveryLease(leaseComponent: "fanBoost"),
                          transportUncertain: true, statusOK: false,
                          hasLeaseReport: false, reportsComponentLease: false) == .adoptLease,
               "failedWithRecoveryLease adopts a named lease")
        expect(P.decision(outcome: .failedWithRecoveryLease(leaseComponent: nil),
                          transportUncertain: true, statusOK: false,
                          hasLeaseReport: false, reportsComponentLease: false) == .adoptLease,
               "failedWithRecoveryLease still owns recovery")

        // .failedBeforeMutation never invents ownership.
        expect(P.decision(outcome: .failedBeforeMutation,
                          transportUncertain: true, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: true) == .settledWithoutLease,
               "failedBeforeMutation settles even when status reports a lease")

        // .interruptedUnknown needs a live lease report to adopt.
        expect(P.decision(outcome: .interruptedUnknown,
                          transportUncertain: true, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: true) == .adoptLease,
               "interruptedUnknown adopts an observed component lease")
        expect(P.decision(outcome: .interruptedUnknown,
                          transportUncertain: true, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: false) == .retryProbe,
               "interruptedUnknown keeps probing without its lease")
        expect(P.decision(outcome: .interruptedUnknown,
                          transportUncertain: true, statusOK: false,
                          hasLeaseReport: false, reportsComponentLease: false) == .retryProbe,
               "interruptedUnknown with no status is unresolved")

        // Non-terminal journal states keep probing regardless of status.
        for outcome in [HelperRequestOutcome.accepted, .running] {
            expect(P.decision(outcome: outcome,
                              transportUncertain: false, statusOK: true,
                              hasLeaseReport: true, reportsComponentLease: true) == .retryProbe,
                   "accepted/running are not settled by a concurrent status")
        }

        // .unknown is the documented legacy fallback.
        expect(P.decision(outcome: .unknown,
                          transportUncertain: false, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: true) == .adoptLease,
               ".unknown falls back to a reported component lease")
        expect(P.decision(outcome: .unknown,
                          transportUncertain: true, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: false) == .retryProbe,
               ".unknown does not settle an uncertain request")
        expect(P.decision(outcome: .unknown,
                          transportUncertain: false, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: false) == .settledWithoutLease,
               ".unknown keeps the legacy settled case")
        expect(P.decision(outcome: .unknown,
                          transportUncertain: false, statusOK: false,
                          hasLeaseReport: true, reportsComponentLease: true) == .retryProbe,
               ".unknown without a successful status keeps probing")
    }

    /// An authoritative answer wins even when the concurrent status probe is
    /// absent or says the opposite.
    static func precedence() {
        typealias P = ProtectedRecoveryPolicy
        expect(P.decision(outcome: .succeeded(leaseComponent: nil),
                          transportUncertain: false, statusOK: false,
                          hasLeaseReport: false, reportsComponentLease: false) == .settledWithoutLease,
               "authoritative success without lease settles without status")
        expect(P.decision(outcome: .failedWithRecoveryLease(leaseComponent: nil),
                          transportUncertain: false, statusOK: false,
                          hasLeaseReport: false, reportsComponentLease: false) == .adoptLease,
               "authoritative recovery lease wins over absent status")
        expect(P.decision(outcome: .failedBeforeMutation,
                          transportUncertain: false, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: true) == .settledWithoutLease,
               "authoritative pre-mutation failure beats a concurrent lease report")
        expect(P.decision(outcome: .succeeded(leaseComponent: "homeServer"),
                          transportUncertain: false, statusOK: true,
                          hasLeaseReport: true, reportsComponentLease: false) == .adoptLease,
               "the outcome's own lease is enough even when status omits it")
    }

    static func legacyMigration() {
        typealias P = ProtectedRecoveryPolicy
        let migrated = P.migrateLegacyPending(["fanBoost", "homeServer"])
        expect(migrated.count == 2, "every v1 component id migrates")
        for (id, record) in migrated {
            expect(!id.isEmpty, "migrated keys keep the component id")
            expect(record.requestID == nil, "v1 has no request UUID")
            expect(record.transportUncertain,
                   "a bare v1 id is unresolved, never evidence of completion")
        }
        expect(P.migrateLegacyPending([]).isEmpty, "empty v1 data migrates to empty v2")

        // v2 is a Codable record dictionary, so writing it round-trips ids.
        let id = UUID()
        let records = ["fanBoost": ProtectedPendingRecovery(requestID: id, transportUncertain: false),
                       "homeServer": ProtectedPendingRecovery(requestID: nil, transportUncertain: true)]
        guard let data = try? JSONEncoder().encode(records),
              let decoded = try? JSONDecoder().decode([String: ProtectedPendingRecovery].self, from: data) else {
            preconditionFailure("v2 records must encode and decode")
        }
        expect(decoded == records, "v2 record round trip preserves the UUID and uncertainty")
    }
}
