// WatchdogPolicy — the pure decisions behind the per-user crash-recovery agent.
//
// The agent itself (Watchdog/main.swift) owns the I/O: it reads the app's
// liveness record, asks the kernel whether the recorded process is alive, and
// talks to the privileged daemon. Everything in this file is deterministic so
// it can be tested without launchd, XPC, the file system or a live process.
//
// Ownership model: the app publishes one liveness record for the current
// process. The watchdog observes that record while the app runs and, only when
// the recorded process is gone, asks the privileged daemon to restore *session*
// leases. Persistent settings are never restored here; the daemon's
// `restoreSession` scope enforces that on the root side.

import Foundation

/// What the watchdog should do for the record it just read.
enum WatchdogDecision: Equatable {
    /// There is no liveness record: the app never ran, or already cleared it.
    case noMarker
    /// The app is gone and the record says the session was not armed.
    case cleanExit
    /// The recorded app instance is still alive: keep observing.
    case wait
    /// The recorded app instance is gone while the session was armed.
    case restoreSession
}

/// What the watchdog could make of the on-disk record. A record it cannot read
/// is never "nothing happened": it is treated as an unclean exit with unknown
/// scope (see `decision(for:appAlive:)`).
enum LivenessMarkerRead: Equatable {
    case absent
    case record(LivenessMarker)
    case corrupt
}

/// Read-side mirror of the app's `LivenessRecord` (Sources/AppLiveness.swift).
///
/// The watchdog target does not compile the app (the app imports AppKit and
/// ServiceManagement, the agent must stay small and Foundation-only), so the
/// wire shape is repeated here. Tests/test_watchdog_policy.py asserts the two
/// field sets stay in sync, and this decoder is deliberately tolerant:
///
/// - unknown JSON fields are ignored (JSONDecoder's default),
/// - `processStartTime`, `armedAt`, `generation` and `updatedAt` may be absent
///   (a record from an older build is still usable, with a weaker identity
///   check),
/// - a missing `schemaVersion` is read as version 1,
/// - a version this build does not understand is corrupt, never guessed.
struct LivenessMarker: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var pid: Int32
    /// Kernel process start time, in seconds since the epoch. `nil` means the
    /// record did not carry one; the PID alone cannot prove identity.
    var processStartTime: TimeInterval?
    var armed: Bool
    var armedAt: TimeInterval?
    var generation: UInt64
    var updatedAt: TimeInterval

    init(schemaVersion: Int = LivenessMarker.currentSchemaVersion,
         pid: Int32,
         processStartTime: TimeInterval?,
         armed: Bool,
         armedAt: TimeInterval? = nil,
         generation: UInt64 = 0,
         updatedAt: TimeInterval = 0) {
        self.schemaVersion = schemaVersion
        self.pid = pid
        self.processStartTime = processStartTime
        self.armed = armed
        self.armedAt = armedAt
        self.generation = generation
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pid, processStartTime, armed, armedAt, generation, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? LivenessMarker.currentSchemaVersion
        self.schemaVersion = version
        self.pid = try container.decode(Int32.self, forKey: .pid)
        self.processStartTime = try container.decodeIfPresent(TimeInterval.self, forKey: .processStartTime)
        self.armed = try container.decode(Bool.self, forKey: .armed)
        self.armedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .armedAt)
        self.generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        self.updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
    }
}

/// The failure counter the agent keeps next to the liveness record.
struct WatchdogRetryState: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var failures: Int
    var updatedAt: TimeInterval

    init(schemaVersion: Int = WatchdogRetryState.currentSchemaVersion,
         failures: Int = 0,
         updatedAt: TimeInterval = 0) {
        self.schemaVersion = schemaVersion
        self.failures = failures
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, failures, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? WatchdogRetryState.currentSchemaVersion
        self.failures = max(0, try container.decodeIfPresent(Int.self, forKey: .failures) ?? 0)
        self.updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
    }
}

enum WatchdogPolicy {
    // MARK: - Observation cadence and restore budget

    /// How often the agent re-checks the recorded process and re-reads the
    /// record while waiting. One second keeps a clean quit responsive without
    /// measurable cost.
    static let pollInterval: TimeInterval = 1

    /// Upper bound on one helper round trip. A timeout is a failed restore, not
    /// a reason to try `restoreAll`.
    static let restoreTimeout: TimeInterval = 8

    /// Failed restores per crash episode before the agent stops asking launchd
    /// to retry. The marker is deliberately left behind: the next launch, the
    /// next app start, or journal reconciliation still sees that a session was
    /// interrupted.
    static let maximumRestoreFailures = 6

    /// The job's `ThrottleInterval`, mirrored from
    /// Resources/dev.wakely.agent.plist. launchd — not the agent — owns
    /// the real retry cadence: the agent exits 1 immediately and launchd starts
    /// it again no sooner than this. Kept here so the log can name the actual
    /// delay and the structural test can check the plist still agrees.
    static let launchdThrottleInterval: TimeInterval = 10

    // MARK: - Decision table

    /// The complete table:
    ///
    /// | hasMarker | appAlive | armed | decision        |
    /// |-----------|----------|-------|-----------------|
    /// | false     | any      | any   | noMarker        |
    /// | true      | true     | any   | wait            |
    /// | true      | false    | false | cleanExit       |
    /// | true      | false    | true  | restoreSession  |
    ///
    /// `appAlive` must describe the *recorded instance*, not merely "some
    /// process with that PID exists" (see `appInstanceAlive`).
    static func decide(hasMarker: Bool, appAlive: Bool, armed: Bool) -> WatchdogDecision {
        guard hasMarker else { return .noMarker }
        if appAlive { return .wait }
        return armed ? .restoreSession : .cleanExit
    }

    /// The record-shaped decision. A corrupt record cannot name a PID and
    /// cannot prove a clean exit, so it is treated as an armed marker for an
    /// instance that is gone: restore once rather than report success.
    static func decision(for read: LivenessMarkerRead, appAlive: Bool) -> WatchdogDecision {
        switch read {
        case .absent:
            return decide(hasMarker: false, appAlive: appAlive, armed: false)
        case .record(let marker):
            return decide(hasMarker: true, appAlive: appAlive, armed: marker.armed)
        case .corrupt:
            return decide(hasMarker: true, appAlive: appAlive, armed: true)
        }
    }

    /// Decode the record without touching the file system. Empty (or
    /// whitespace-only) data and unsupported versions are corrupt rather than
    /// absent: absence is a clean state, corruption is not.
    static func readMarker(_ data: Data?) -> LivenessMarkerRead {
        guard let data else { return .absent }
        guard !data.isEmpty else { return .corrupt }
        guard let marker = try? JSONDecoder().decode(LivenessMarker.self, from: data) else {
            return .corrupt
        }
        guard marker.schemaVersion >= 1,
              marker.schemaVersion <= LivenessMarker.currentSchemaVersion else {
            return .corrupt
        }
        guard marker.pid > 0 else { return .corrupt }
        return .record(marker)
    }

    // MARK: - Process identity

    /// True only when the start times describe the same process.
    ///
    /// `markerStart == nil` (a record that did not carry one) or
    /// `currentStart == nil` (the kernel did not report one) is false: without
    /// a start time the PID alone proves nothing and PID reuse cannot be
    /// rejected. A delta of exactly one second is accepted because the kernel
    /// timestamp and the JSON round trip are not guaranteed to be
    /// bit-identical; anything larger is a different process.
    static func sameProcess(markerPID: Int32,
                            markerStart: TimeInterval?,
                            currentStart: TimeInterval?) -> Bool {
        guard markerPID > 0,
              let markerStart, let currentStart,
              markerStart.isFinite, currentStart.isFinite else { return false }
        return abs(markerStart - currentStart) <= 1.0
    }

    /// Form used when the caller also knows the live PID. A PID mismatch is
    /// never the recorded process, even if the start times happen to match.
    static func sameProcess(markerPID: Int32,
                            markerStart: TimeInterval?,
                            currentPID: Int32,
                            currentStart: TimeInterval?) -> Bool {
        guard markerPID == currentPID else { return false }
        return sameProcess(markerPID: markerPID, markerStart: markerStart, currentStart: currentStart)
    }

    /// Whether the recorded instance is still alive.
    ///
    /// - A missing live process (`livePID == nil`) means gone.
    /// - A live PID that differs from the marker means the recorded process is
    ///   gone (the PID now belongs to something else).
    /// - A live PID without a readable start time cannot be verified; fail
    ///   safe and call it alive so the agent never restores underneath a
    ///   process it cannot rule out.
    /// - A record with no start time is treated as alive while its PID is
    ///   alive: the old record cannot disprove that this is the same instance.
    ///   Only "process is not alive" may turn an unverifiable record into
    ///   "app gone". This is intentionally conservative; the writer always
    ///   records a start time, so only a hand-edited or future record hits it.
    static func appInstanceAlive(markerPID: Int32,
                                 markerStart: TimeInterval?,
                                 livePID: Int32?,
                                 liveStart: TimeInterval?) -> Bool {
        guard let livePID, livePID == markerPID else { return false }
        guard let liveStart else { return true }
        guard let markerStart else { return true }
        return sameProcess(markerPID: markerPID,
                           markerStart: markerStart,
                           currentStart: liveStart)
    }

    // MARK: - Retry budget

    /// Advisory exponential values: 2, 4, 8, 16, 32, then 60 seconds forever.
    ///
    /// This is **not** the retry cadence. The agent exits 1 at once and
    /// launchd restarts the job no sooner than the job's `ThrottleInterval`
    /// (see `launchdThrottleInterval`, currently 10 s) — the growing number
    /// here never delays that. It is only a cap hint for a future in-process
    /// retry loop and for the failure log line, which says so explicitly.
    static func nextRetryDelay(failures: Int) -> TimeInterval {
        guard failures > 0 else { return 2 }
        let exponent = min(failures - 1, 6)
        return min(2 * pow(2, Double(exponent)), 60)
    }

    /// After six failed restores the agent stops retrying and exits 0. The
    /// liveness record is left in place on purpose: giving up is not the same
    /// as a clean exit, and the next launch or app start must still see that
    /// the session was interrupted.
    static func shouldGiveUp(failures: Int) -> Bool {
        failures >= maximumRestoreFailures
    }
}
