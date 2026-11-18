// UsageResetPolicyTests — pure Sleep Until Reset timing matrix (M6b).
//
// Foundation only; no clock, file system, helper, power API or notification.
// Compile with the reader (for `UsageLimitReset`) and the policy:
//
//   xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
//     -module-cache-path build/componentcache \
//     Sources/UsageResetReader.swift Sources/UsageResetPolicy.swift \
//     Tests/UsageResetPolicyTests.swift -o /tmp/wakely-usage-reset-policy
//   /tmp/wakely-usage-reset-policy

import Foundation

@main
struct UsageResetPolicyTests {
    static let now = Date(timeIntervalSince1970: 1_781_000_000)

    static func main() {
        planAddsOneMinute()
        planFiltersAndBounds()
        planDeduplicatesAndCaps()
        replanKeyDetectsChanges()
        batteryDecision()
        sessionEndMatrix()
        onlyOwnedWakeInstantsStartASession()
        constantsMatchTheContract()
        print("Usage Reset policy tests passed (plan, horizon, dedupe, battery, "
            + "4 h cap, 3 min grace, 15 min waiting)")
    }

    // MARK: - Fixtures

    static func reset(_ offset: TimeInterval,
                      provider: UsageLimitReset.Provider = .claude,
                      account: String? = nil) -> UsageLimitReset {
        UsageLimitReset(provider: provider,
                        account: account,
                        resetsAt: now.addingTimeInterval(offset))
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func seconds(_ dates: [Date]) -> [TimeInterval] {
        dates.map { $0.timeIntervalSince(now) }
    }

    // MARK: - Planning

    static func planAddsOneMinute() {
        let planned = UsageResetPolicy.plan(resets: [reset(600)], now: now)
        require(seconds(planned) == [660], "wake is reset + 60 s")
    }

    static func planFiltersAndBounds() {
        require(UsageResetPolicy.plan(resets: [], now: now).isEmpty, "no resets means no wakes")
        require(UsageResetPolicy.plan(resets: [reset(-600)], now: now).isEmpty, "past resets are ignored")
        require(UsageResetPolicy.plan(resets: [reset(-60)], now: now).isEmpty,
                "a reset whose +60 s is already past is ignored")

        // Horizon: exactly 7 days is accepted; a second later is not.
        let inside = UsageResetPolicy.maximumHorizon - 60
        require(seconds(UsageResetPolicy.plan(resets: [reset(inside)], now: now)) == [UsageResetPolicy.maximumHorizon],
                "the last instant inside the horizon is planned")
        require(UsageResetPolicy.plan(resets: [reset(inside + 1)], now: now).isEmpty,
                "an instant beyond the seven-day horizon is dropped")

        let bad = UsageLimitReset(provider: .claude,
                                  resetsAt: Date(timeIntervalSince1970: .infinity))
        require(UsageResetPolicy.plan(resets: [bad], now: now).isEmpty, "a non-finite reset is dropped")
        require(UsageResetPolicy.plan(resets: [reset(600)], now: Date(timeIntervalSince1970: .nan)).isEmpty,
                "a non-finite clock plans nothing")
    }

    static func planDeduplicatesAndCaps() {
        let same = [reset(600, account: "a"), reset(600, account: "b"), reset(600.5, account: "c")]
        require(seconds(UsageResetPolicy.plan(resets: same, now: now)) == [660],
                "one instant within the tolerance is one wake")

        let distinct = [reset(600), reset(602)]
        require(seconds(UsageResetPolicy.plan(resets: distinct, now: now)) == [660, 662],
                "instants outside the tolerance are separate wakes")

        let many = (0..<20).map { reset(600 + Double($0) * 300) }
        let capped = UsageResetPolicy.plan(resets: many, now: now)
        require(capped.count == UsageResetPolicy.maximumEvents,
                "at most 8 wake events are planned")
        require(seconds(capped) == (0..<8).map { 660 + Double($0) * 300 },
                "the cap keeps the earliest instants")
    }

    static func replanKeyDetectsChanges() {
        let a = [reset(600, account: "a"), reset(1200, account: "b")]
        let b = [reset(1200, account: "b"), reset(600, account: "a")]
        require(UsageResetPolicy.replanKey(resets: a) == UsageResetPolicy.replanKey(resets: b),
                "the replan key ignores input order")
        require(UsageResetPolicy.replanKey(resets: []) == "", "no resets means an empty key")
        require(UsageResetPolicy.replanKey(resets: a) != UsageResetPolicy.replanKey(resets: [reset(601, account: "a"), reset(1200, account: "b")]),
                "a moved reset changes the key")
        require(UsageResetPolicy.replanKey(resets: a) != UsageResetPolicy.replanKey(resets: [reset(600, account: "c"), reset(1200, account: "b")]),
                "an account change that keeps the instant still changes the key")
        require(UsageResetPolicy.replanKey(resets: a) != UsageResetPolicy.replanKey(resets: [reset(600, provider: .codex, account: "a"), reset(1200, account: "b")]),
                "a provider change changes the key")

        let subsecond = [UsageLimitReset(provider: .claude,
                                         resetsAt: Date(timeIntervalSince1970: 1_781_000_600.9))]
        let rounded = [UsageLimitReset(provider: .claude,
                                       resetsAt: Date(timeIntervalSince1970: 1_781_000_600.1))]
        require(UsageResetPolicy.replanKey(resets: subsecond) == UsageResetPolicy.replanKey(resets: rounded),
                "sub-second noise does not force a replan")
    }

    // MARK: - Battery

    static func batteryDecision() {
        require(UsageResetPolicy.shouldWakeOnBattery(at: now, onBattery: true),
                "a wake on battery goes back to sleep")
        require(!UsageResetPolicy.shouldWakeOnBattery(at: now, onBattery: false),
                "a wake on AC may hold")
        require(UsageResetPolicy.shouldWakeOnBattery(at: now),
                "the default is the safe one: treat an unmeasured source as battery")
        require(UsageResetPolicy.shouldWakeOnBattery(at: Date(timeIntervalSince1970: .nan), onBattery: false),
                "an unusable clock never holds the Mac awake")
    }

    // MARK: - End after wake

    static func sessionEndMatrix() {
        let start = now
        func end(_ offset: TimeInterval,
                 working: Int = 0,
                 waiting: Int = 0,
                 waitingSince: Date? = nil,
                 lastWorkAt: Date? = nil) -> UsageResetEndReason? {
            UsageResetPolicy.shouldEndAfterWake(
                now: start.addingTimeInterval(offset),
                sessionStartedAt: start,
                working: working,
                waiting: waiting,
                waitingSince: waitingSince,
                lastWorkAt: lastWorkAt
            )
        }

        require(end(0) == nil, "the moment of the wake never ends the session")
        require(end(179) == nil, "the grace is still running")
        require(end(180) == .noWorkInGrace, "no work for the full grace ends the session")
        require(end(10 * 60, working: 1) == nil, "a working agent holds the session")
        require(end(10 * 60, working: 1, waiting: 3) == nil, "work wins over a waiter")

        require(end(600, lastWorkAt: start.addingTimeInterval(600)) == nil,
                "work ending restarts the grace")
        require(end(779, lastWorkAt: start.addingTimeInterval(600)) == nil,
                "the grace after work has not elapsed")
        require(end(780, lastWorkAt: start.addingTimeInterval(600)) == .noWorkInGrace,
                "the grace after work elapsed")
        require(end(600, lastWorkAt: start.addingTimeInterval(10_000)) == nil,
                "a future last-work stamp is clamped to now")

        require(end(60, waiting: 1) == nil, "a new waiter starts its own clock")
        require(end(60, waiting: 1, waitingSince: start) == nil,
                "a waiter inside fifteen minutes holds the session")
        require(end(899, waiting: 1, waitingSince: start) == nil,
                "a waiter just inside the limit holds")
        require(end(900, waiting: 1, waitingSince: start) == .waitingForUser,
                "a waiter for fifteen minutes ends the session")

        require(end(UsageResetPolicy.maximumSessionDuration - 1, working: 1) == nil,
                "the cap is not reached one second early")
        require(end(UsageResetPolicy.maximumSessionDuration) == .fourHourCap,
                "the four-hour cap ends the session")
        require(end(UsageResetPolicy.maximumSessionDuration, working: 5) == .fourHourCap,
                "the cap wins over active work")
        require(end(UsageResetPolicy.maximumSessionDuration + 1, working: 1) == .fourHourCap,
                "the cap is absolute")

        require(UsageResetPolicy.shouldEndAfterWake(
            now: start.addingTimeInterval(-1), sessionStartedAt: start,
            working: 0, waiting: 0) == nil,
            "a backwards clock does not end a session")
        require(UsageResetPolicy.shouldEndAfterWake(
            now: Date(timeIntervalSince1970: .nan), sessionStartedAt: start,
            working: 0, waiting: 0) == .fourHourCap,
            "an unusable clock ends the session instead of holding forever")
        require(end(180, working: -3, waiting: -2) == .noWorkInGrace,
                "negative counts are treated as zero")

        require(UsageResetEndReason.fourHourCap.message.contains("four-hour"),
                "the cap reason names the limit")
        require(UsageResetEndReason.noWorkInGrace.message.contains("three-minute"),
                "the grace reason names the OSS grace")
        require(UsageResetEndReason.waitingForUser.message.contains("fifteen minutes"),
                "the waiter reason names the limit")
    }

    static func onlyOwnedWakeInstantsStartASession() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        require(UsageResetPolicy.isPlannedWake(reset, planned: [reset]),
                "the exact planned instant matches")
        require(UsageResetPolicy.isPlannedWake(reset.addingTimeInterval(14 * 60), planned: [reset]),
                "a delayed firmware wake within the window still matches")
        require(!UsageResetPolicy.isPlannedWake(reset.addingTimeInterval(16 * 60), planned: [reset]),
                "a wake beyond the window is not ours")
        require(!UsageResetPolicy.isPlannedWake(reset, planned: []),
                "no plan means no owned wake")
        require(!UsageResetPolicy.isPlannedWake(reset, planned: [reset.addingTimeInterval(3600)]),
                "a different instant does not match")
        require(UsageResetPolicy.wakeMatchTolerance == 15 * 60,
                "the OSS match window is fifteen minutes")
    }

    static func constantsMatchTheContract() {
        require(UsageResetPolicy.wakeDelay == 60, "the wake delay is one minute")
        require(UsageResetPolicy.maximumSessionDuration == 4 * 60 * 60, "the cap is four hours")
        require(UsageResetPolicy.waitingLimit == 15 * 60, "the waiter limit is fifteen minutes")
        require(UsageResetPolicy.wakeGrace == 3 * 60, "the OSS grace is three minutes")
        require(UsageResetPolicy.maximumHorizon == 7 * 24 * 60 * 60, "the horizon is seven days")
        require(UsageResetPolicy.maximumEvents == 8, "at most eight owned wakes")
    }
}
