// UsageResetPolicy — the pure timing and stay-awake policy behind Sleep Until
// Reset.
//
// No clock, file system, helper client, power API or notification is reachable
// from here: every function takes its instant and its observations as
// arguments, so the whole matrix is testable in isolation.
//
// PROVEN (from the feature's own copy, treated as the contract):
//  * wake one minute after a reset;
//  * stay awake while any agent works, up to four hours;
//  * if none is working a short grace after a wake, sleep until the next reset;
//  * if one waits on the user for fifteen minutes, sleep until the next reset;
//  * on battery at a wake, go back to sleep.
//
// OSS POLICY (our choice; the original's exact interval is not recovered):
//  * the grace after a wake is 3 minutes, mirrored from the existing
//    finish-work hold in this build;
//  * at most 8 owned wake events, at least 30 s and at most 7 days ahead, 1 s
//    dedupe tolerance. The helper refuses a wake less than 30 s ahead, so
//    planning must never produce an instant the helper will reject.

import Foundation

/// Why a Sleep Until Reset stay-awake session should end. `nil` from
/// `shouldEndAfterWake` means keep holding.
enum UsageResetEndReason: Equatable, Sendable {
    case fourHourCap
    case noWorkInGrace
    case waitingForUser

    /// Log-safe sentence. Counts only; never an account, prompt or path.
    var message: String {
        switch self {
        case .fourHourCap:
            return "the four-hour Sleep Until Reset limit was reached"
        case .noWorkInGrace:
            return "no agent was working within the three-minute grace after the wake"
        case .waitingForUser:
            return "an agent had been waiting for you for fifteen minutes"
        }
    }
}

enum UsageResetPolicy {
    // MARK: Proven contract

    /// Every reset is followed by one wake a minute later.
    static let wakeDelay: TimeInterval = 60
    /// "stays awake ... up to 4 hours"
    static let maximumSessionDuration: TimeInterval = 4 * 60 * 60
    /// "one waits on you for 15 minutes"
    static let waitingLimit: TimeInterval = 15 * 60

    // MARK: OSS policy

    /// "If none is working <duration> after a wake ... it sleeps." The original
    /// interval was not recovered; 3 minutes matches the existing agent
    /// finish-work grace in this build and is named here as OSS policy.
    static let wakeGrace: TimeInterval = 3 * 60
    /// Bounds the helper's one-off schedule to a reviewable window.
    static let maximumHorizon: TimeInterval = 7 * 24 * 60 * 60
    /// The helper refuses an instant less than 30 s ahead (`WakeSchedulePolicy`
    /// in the helper). Planning this far ahead is the only lead that is certain
    /// to be accepted when the schedule request lands.
    static let minimumWakeLead: TimeInterval = 30
    static let maximumEvents = 8
    /// Two planned instants this close are the same wake.
    static let dedupeTolerance: TimeInterval = 1

    // MARK: - Planning

    /// Reset + 1 minute, at least 30 s ahead (the helper's minimum lead), inside
    /// the 7-day horizon, deduplicated and capped at 8 events. `[]` means "no
    /// wake can be justified from this data".
    static func plan(resets: [UsageLimitReset], now: Date) -> [Date] {
        let nowEpoch = now.timeIntervalSince1970
        guard nowEpoch.isFinite else { return [] }

        var candidates: [Date] = []
        for reset in resets {
            let base = reset.resetsAt.timeIntervalSince1970
            guard base.isFinite else { continue }
            let epoch = base + wakeDelay
            guard epoch.isFinite else { continue }
            let lead = epoch - nowEpoch
            guard lead >= minimumWakeLead, lead <= maximumHorizon else { continue }
            candidates.append(Date(timeIntervalSince1970: epoch))
        }
        candidates.sort()

        var planned: [Date] = []
        for candidate in candidates {
            if let last = planned.last,
               abs(candidate.timeIntervalSince(last)) <= dedupeTolerance {
                continue
            }
            planned.append(candidate)
            if planned.count == maximumEvents { break }
        }
        return planned
    }

    /// A stable key over the known resets, used to decide whether a replan
    /// changed anything. In-memory only: never logged, because it names
    /// accounts. Seconds resolution keeps sub-second provider noise from
    /// forcing a reconcile.
    static func replanKey(resets: [UsageLimitReset]) -> String {
        let parts = resets.compactMap { reset -> String? in
            let epoch = reset.resetsAt.timeIntervalSince1970
            guard epoch.isFinite else { return nil }
            return "\(reset.provider.rawValue)|\(reset.account ?? "")|\(Int(epoch.rounded(.down)))"
        }.sorted()
        return parts.joined(separator: ";")
    }

    // MARK: - Wake-time decisions

    /// True when a wake must go straight back to sleep because the Mac is on
    /// battery. The instant is accepted for call-site symmetry and for the
    /// finite-clock guard; the measured power source decides.
    ///
    /// The default is deliberately `true`: a caller that forgot to measure must
    /// fall back to sleep rather than hold the Mac awake indefinitely.
    static func shouldWakeOnBattery(at date: Date, onBattery: Bool = true) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { return true }
        return onBattery
    }

    /// The stay-awake decision after a wake.
    ///
    /// - `working`/`waiting`: the AgentMonitor counts at `now`.
    /// - `waitingSince`: when the current waiting period was first observed
    ///   (the controller stamps it on the first scan that sees a waiter).
    /// - `lastWorkAt`: the last scan that saw work, so stopped work starts the
    ///   same grace as a wake with no work at all.
    ///
    /// A wake only belongs to this component when it lands near an instant the
    /// component planned. Any other wake (Time Machine, a network wake, a user
    /// timer) must not start a four-hour stay-awake session. Firmware may defer
    /// a scheduled wake, so the match window is deliberately wider than a
    /// minute; it is still narrow enough that unrelated wakes are ignored.
    static let wakeMatchTolerance: TimeInterval = 15 * 60

    static func isPlannedWake(_ instant: Date, planned: [Date],
                              tolerance: TimeInterval = wakeMatchTolerance) -> Bool {
        planned.contains { abs($0.timeIntervalSince(instant)) <= tolerance }
    }

    /// Order: the four-hour cap always ends; any working agent keeps the Mac
    /// awake until that cap; otherwise a waiter older than fifteen minutes
    /// ends the session, and an idle session older than the grace ends it.
    static func shouldEndAfterWake(now: Date,
                                   sessionStartedAt: Date,
                                   working: Int,
                                   waiting: Int,
                                   waitingSince: Date? = nil,
                                   lastWorkAt: Date? = nil) -> UsageResetEndReason? {
        let nowEpoch = now.timeIntervalSince1970
        let startEpoch = sessionStartedAt.timeIntervalSince1970
        guard nowEpoch.isFinite else { return .fourHourCap }
        guard startEpoch.isFinite, startEpoch <= nowEpoch else { return nil }

        if nowEpoch - startEpoch >= maximumSessionDuration { return .fourHourCap }

        let activeWork = max(0, working)
        let activeWaiting = max(0, waiting)
        if activeWork > 0 { return nil }

        if activeWaiting > 0 {
            // A waiter is evidence of an unfinished task: hold while the
            // fifteen-minute limit has not elapsed. Start counting at `now` when
            // the caller has not stamped the first observation yet.
            let since = min(nowEpoch, max(startEpoch, waitingSince?.timeIntervalSince1970 ?? nowEpoch))
            if nowEpoch - since >= waitingLimit { return .waitingForUser }
            return nil
        }

        let lastWorkEpoch = lastWorkAt?.timeIntervalSince1970 ?? startEpoch
        let baseline = min(nowEpoch, max(startEpoch, lastWorkEpoch))
        if nowEpoch - baseline >= wakeGrace { return .noWorkInGrace }
        return nil
    }
}
