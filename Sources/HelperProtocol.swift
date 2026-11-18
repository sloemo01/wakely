// HelperProtocol — the contract between the app and its privileged daemon.
//
// Kept dependency-free and compiled into both targets. Everything crosses the
// XPC boundary as JSON data so the interface needs no class allow-list and no
// custom NSSecureCoding graph.

import Foundation

public enum HelperService {
    public static let machServiceName = "dev.wakely.helper"
    public static let daemonPlistName = "dev.wakely.helper.plist"
    public static let agentPlistName = "dev.wakely.agent.plist"
    public static let daemonLabel = "dev.wakely.helper"
    public static let agentLabel = "dev.wakely.agent"

    /// Wire-protocol revision, separate from the helper's implementation
    /// version. Version 2 adds the request journal, `requestStatus` and
    /// `restoreSession`. Version 3 adds helper-owned one-off wakes:
    /// `scheduleWake`, `cancelWake` and the read-only `wakeSchedules`, with a
    /// durable ownership record behind them. Version 4 adds the component
    /// vocabulary; version 5 adds battery wake-source suppression for Sleep
    /// Means Sleep. A client must check the version before relying on operations
    /// introduced after its minimum.
    public static let protocolVersion = "5"
}

/// Every privileged action the daemon will perform. There is no generic shell.
public enum HelperOperation: String, Codable, CaseIterable, Sendable {
    case ping
    case status
    case lowPowerMode          // boolValue
    /// boolValue true suppresses supported battery wake sources and records
    /// every previous value. Undo through restoreComponent, never a raw false.
    case suppressWakeSources
    case fanPercent            // intValue 1...100, 0 restores automatic
    case touchIDUnlock         // boolValue: false disables unlock-with-Touch-ID
    case bootOnLidOpen         // boolValue: false keeps a shut-down Mac off
    case autoRestartAfterPowerLoss  // boolValue: pmset -c autorestart
    case restoreComponent         // componentID: put back the saved values
    /// Pre-rename wire spelling. Accepted so a v3 daemon, a v3 client and an
    /// existing request journal all keep working through the vocabulary change.
    case restoreComponentLegacy = "restoreModule"
    case restoreAll
    /// Query the journal for one request UUID (request.requestID). Read-only.
    case requestStatus
    /// Restore only session-scoped component leases, never persistent settings.
    case restoreSession
    /// Create one helper-owned wake at `dateValue` (Unix epoch seconds).
    /// Mutating: journaled and serialized.
    case scheduleWake
    /// Cancel one helper-owned wake matching `dateValue` (Unix epoch seconds,
    /// within 1 s of the ownership record). Mutating: journaled and serialized.
    case cancelWake
    /// List helper-owned wakes and whether each is currently present in
    /// `pmset -g sched`. Read-only: no ownership record is written and no
    /// mutation lock is taken.
    case wakeSchedules
}

/// The daemon's authoritative record of one request. These are proposed OSS
/// states; they are not recovered names from another implementation.
public enum HelperRequestState: String, Codable, CaseIterable, Sendable {
    case accepted
    case running
    case succeeded
    case failedBeforeMutation
    case failedWithRecoveryLease
    case interruptedUnknown

    /// No further transition is expected from the request itself. This says
    /// nothing about whether a retained lease still needs recovery.
    public var isTerminal: Bool {
        switch self {
        case .accepted, .running: return false
        case .succeeded, .failedBeforeMutation, .failedWithRecoveryLease,
             .interruptedUnknown: return true
        }
    }

    /// The record may still describe unresolved work and must be retained:
    /// accepted/running were interrupted, `interruptedUnknown` is unreconciled,
    /// and `failedWithRecoveryLease` still owns a saved lease.
    public var needsRecovery: Bool {
        switch self {
        case .accepted, .running, .interruptedUnknown, .failedWithRecoveryLease:
            return true
        case .succeeded, .failedBeforeMutation:
            return false
        }
    }
}

/// Which saved leases a request may touch during recovery. Session-scoped
/// settings are the ones the app re-establishes for the current session;
/// persistent settings survive a session and must never be restored merely
/// because the session ended. Pure data, so the app, watchdog and helper can
/// share one mapping.
public enum HelperRestoreScope: String, Codable, CaseIterable, Sendable {
    case sessionComponents
    case persistentComponents

    public static func scope(for operation: HelperOperation) -> HelperRestoreScope? {
        switch operation {
        case .lowPowerMode, .fanPercent, .touchIDUnlock:
            return .sessionComponents
        case .autoRestartAfterPowerLoss, .bootOnLidOpen, .suppressWakeSources:
            return .persistentComponents
        default:
            return nil
        }
    }

    /// BackupStore records the operation as a raw string. Touch ID has a
    /// versioned system-scope token as well as the legacy bare name; the legacy
    /// entry is still session-scoped but its own restore policy refuses it and
    /// keeps the lease for manual recovery.
    public static func scope(forStoredOperation name: String) -> HelperRestoreScope? {
        if let operation = HelperOperation(rawValue: name) {
            return scope(for: operation)
        }
        if name == "touchIDUnlock.system.v1" {
            return .sessionComponents
        }
        return nil
    }

    public func includes(_ operation: HelperOperation) -> Bool {
        HelperRestoreScope.scope(for: operation) == self
    }

    public func includes(storedOperation name: String) -> Bool {
        HelperRestoreScope.scope(forStoredOperation: name) == self
    }

    /// Every operation this scope owns. Derived from the one mapping above so
    /// a caller cannot drift from it.
    public var operations: [HelperOperation] {
        HelperOperation.allCases.filter { HelperRestoreScope.scope(for: $0) == self }
    }
}

public struct HelperRequest: Codable, Sendable {
    public var id: UUID
    public var operation: HelperOperation
    public var componentID: String
    public var boolValue: Bool?
    public var intValue: Int?
    /// UUID to look up for `requestStatus`. Kept separate from `id` so a query
    /// can name an earlier request without pretending to be that request.
    public var requestID: UUID?
    /// Absolute instant for `scheduleWake`/`cancelWake`, as Unix epoch seconds.
    /// Optional, so every older request JSON (and every operation that does not
    /// take a date) still decodes; a missing value means "no date supplied".
    public var dateValue: Double?
    /// Optional client protocol revision, for diagnostics and negotiation.
    public var protocolVersion: Int?

    public init(operation: HelperOperation, componentID: String = "",
                boolValue: Bool? = nil, intValue: Int? = nil,
                requestID: UUID? = nil, protocolVersion: Int? = nil,
                dateValue: Double? = nil) {
        self.id = UUID()
        self.operation = operation
        self.componentID = componentID
        self.boolValue = boolValue
        self.intValue = intValue
        self.requestID = requestID
        self.protocolVersion = protocolVersion
        self.dateValue = dateValue
    }
}

public struct HelperReply: Codable, Sendable {
    public var id: UUID
    public var ok: Bool
    public var message: String
    /// Values the daemon captured before changing anything, for the app to show
    /// and for restoration to target.
    public var details: [String: String]

    public init(id: UUID, ok: Bool, message: String, details: [String: String] = [:]) {
        self.id = id
        self.ok = ok
        self.message = message
        self.details = details
    }

    public static func failure(_ id: UUID, _ message: String) -> HelperReply {
        HelperReply(id: id, ok: false, message: message)
    }
}

/// NSXPC surface. JSON in, JSON out: no bespoke class allow-listing.
@objc public protocol HelperXPC {
    func perform(_ request: Data, reply: @escaping (Data) -> Void)
}

public enum HelperCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
