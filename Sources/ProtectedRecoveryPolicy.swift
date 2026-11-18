import Foundation

/// One unresolved protected mutation.
///
/// `requestID` is the UUID of the client request whose journal entry a
/// protocol-2 helper can answer authoritatively. A legacy v1 entry has no UUID
/// and is migrated as `transportUncertain: true`: a bare component name is not
/// evidence that its request finished, so it must never be treated as resolved
/// without a lease or an authoritative outcome.
struct ProtectedPendingRecovery: Codable, Equatable {
    var requestID: UUID?
    var transportUncertain: Bool

    init(requestID: UUID? = nil, transportUncertain: Bool = true) {
        self.requestID = requestID
        self.transportUncertain = transportUncertain
    }
}

/// Recovery obligations are not successful component application. In particular,
/// a transport timeout does not cancel a queued root-helper mutation.
enum ProtectedRecoveryPolicy {
    enum Decision: Equatable { case adoptLease, settledWithoutLease, retryProbe }

    /// Legacy path: status-lease inference only. Used by old callers and for a
    /// nil/unknown authoritative outcome, where the journal gave no answer.
    static func decision(transportUncertain: Bool, statusOK: Bool,
                         hasLeaseReport: Bool, reportsComponentLease: Bool) -> Decision {
        guard statusOK, hasLeaseReport else { return .retryProbe }
        if reportsComponentLease { return .adoptLease }
        // Status is concurrent with mutations. Absence cannot settle a request
        // whose completion was never received; it may save its lease later.
        return transportUncertain ? .retryProbe : .settledWithoutLease
    }

    /// Protocol-2 decision. An authoritative outcome wins over a concurrent
    /// status probe even when status is absent or reports a different lease.
    /// `nil` and `.unknown` deliberately fall through to the legacy decision:
    /// no journal entry is no evidence.
    static func decision(outcome: HelperRequestOutcome?,
                         transportUncertain: Bool,
                         statusOK: Bool,
                         hasLeaseReport: Bool,
                         reportsComponentLease: Bool) -> Decision {
        guard let outcome else {
            return decision(transportUncertain: transportUncertain,
                            statusOK: statusOK,
                            hasLeaseReport: hasLeaseReport,
                            reportsComponentLease: reportsComponentLease)
        }
        switch outcome {
        case .succeeded(let leaseComponent):
            return leaseComponent == nil ? .settledWithoutLease : .adoptLease
        case .failedWithRecoveryLease:
            return .adoptLease
        case .failedBeforeMutation:
            return .settledWithoutLease
        case .interruptedUnknown:
            // The journal cannot say whether a lease was saved. Only a live
            // lease report may adopt one; otherwise keep probing.
            return hasLeaseReport && reportsComponentLease ? .adoptLease : .retryProbe
        case .accepted, .running:
            return .retryProbe
        case .unknown:
            return decision(transportUncertain: transportUncertain,
                            statusOK: statusOK,
                            hasLeaseReport: hasLeaseReport,
                            reportsComponentLease: reportsComponentLease)
        }
    }

    /// v1 persisted only component ids. Every migrated entry is unresolved,
    /// transport-uncertain and has no request UUID to query.
    static func migrateLegacyPending(_ componentIDs: [String]) -> [String: ProtectedPendingRecovery] {
        var migrated: [String: ProtectedPendingRecovery] = [:]
        for id in componentIDs {
            migrated[id] = ProtectedPendingRecovery(requestID: nil, transportUncertain: true)
        }
        return migrated
    }

    static func fanForcedAfterInitialApply(componentID: String, replyOK: Bool) -> Bool {
        componentID == "fanBoost" && replyOK
    }
}
