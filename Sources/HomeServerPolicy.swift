// HomeServerPolicy — pure rules for the Home Server restart/login lifecycle.
//
// Home Server is the documented exception to "never arm at launch": while the
// component is on and the Mac is on AC power, Wakely arms persistently so it is
// back after a restart or a login. That exception must not swallow a safety
// stop, and it must not turn a crash loop into a rearm loop.
//
// No AppKit, IOKit, ServiceManagement, helper client or UserDefaults here.

import Foundation

enum HomeServerPolicy {

    /// The components whose presence at login is the reason to keep a login item.
    static let loginItemComponentIDs: Set<String> = [
        "homeServer", "passwordAfterClose", "sleepUntilReset"
    ]

    // MARK: - Startup and control

    /// The one automatic arm at launch: component on and the Mac on AC.
    static func shouldArmAtLaunch(componentEnabled: Bool, onCharger: Bool) -> Bool {
        componentEnabled && onCharger
    }

    /// A manual/URL/Caps/control disarm has no effect while Home Server holds an
    /// AC session. This predicate is only the power/component half; callers must
    /// pair it with `classifyDisarm` so a safety stop is never ignored.
    static func shouldIgnoreControlDisarm(componentEnabled: Bool, onCharger: Bool) -> Bool {
        componentEnabled && onCharger
    }

    // MARK: - Disarm reason classifier

    /// A closed vocabulary for stop reasons. `control` is the only class Home
    /// Server may ignore; every safety class is honored even on AC. An
    /// unrecognized reason is `.unrecognized` and is honored too: a stop we do
    /// not understand could be a limit we must respect.
    enum DisarmClass: String, Equatable {
        case control
        case quit
        case lowBattery
        case batteryBudget
        case thermal
        case componentDisabled
        case helperRemoved
        case unrecognized

        var isSafety: Bool {
            switch self {
            case .control, .unrecognized: return false
            case .quit, .lowBattery, .batteryBudget, .thermal, .componentDisabled, .helperRemoved:
                return true
            }
        }
    }

    /// Explicit allowlists. Matching is on the lowercased reason; short control
    /// words require an exact match so "you" cannot match inside another word.
    private static let quitReasons = [
        "wakely quit", "quit", "app quit", "termination", "shut down", "shutdown"
    ]
    private static let lowBatteryReasons = [
        "low battery", "battery is at or below", "battery below", "battery guard",
        "battery reached", "battery at 20"
    ]
    private static let batteryBudgetReasons = ["battery budget"]
    private static let thermalReasons = ["too hot", "thermal", "heat"]
    private static let componentDisabledReasons = ["component disabled"]
    private static let helperRemovedReasons = [
        "helper is being removed", "helper removed", "helper uninstall", "privileged helper is being removed"
    ]
    /// Control actions are manual stops and lifecycle transitions that Home
    /// Server is meant to override while it holds an AC session. Safety words
    /// never appear here, and the classifier checks the safety lists first.
    private static let controlReasons = [
        "you", "url", "menu", "caps lock", "caps", "status item", "control",
        "the lid opened", "nothing was working", "the sleep timer ended"
    ]

    static func classifyDisarm(_ reason: String) -> DisarmClass {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An empty reason is not evidence of a control action: honor it.
        guard !text.isEmpty else { return .unrecognized }
        func matches(_ list: [String]) -> Bool {
            list.contains { token in
                // "you" is too short to match as a substring ("your battery").
                token == "you" ? text == token : text.contains(token)
            }
        }
        // Safety first: a string that names a safety stop is never control, even
        // if it also contains a control word.
        if matches(helperRemovedReasons) { return .helperRemoved }
        if matches(componentDisabledReasons) { return .componentDisabled }
        if matches(batteryBudgetReasons) { return .batteryBudget }
        if matches(thermalReasons) { return .thermal }
        if matches(lowBatteryReasons) { return .lowBattery }
        if matches(quitReasons) { return .quit }
        if matches(controlReasons) { return .control }
        return .unrecognized
    }

    /// True only for a control-classified disarm while Home Server is enabled,
    /// on AC, and the app is not shutting down. Every safety and quit reason is
    /// honored. `shuttingDown` short-circuits so an orderly quit never logs a
    /// spurious "ignored" line.
    static func shouldIgnoreDisarm(componentEnabled: Bool, onCharger: Bool,
                                   reason: String, shuttingDown: Bool) -> Bool {
        guard !shuttingDown else { return false }
        guard shouldIgnoreControlDisarm(componentEnabled: componentEnabled, onCharger: onCharger) else {
            return false
        }
        return classifyDisarm(reason) == .control
    }

    // MARK: - Login item

    /// One login item covers the three components that need Wakely back after a
    /// restart or login. Turning all of them off releases it (unless it is
    /// owned by the separate launch-at-login preference).
    static func shouldRegisterLoginItem(enabledComponentIDs: Set<String>) -> Bool {
        !enabledComponentIDs.isDisjoint(with: loginItemComponentIDs)
    }
}

/// A sliding one-hour budget for automatic Home Server rearms. Pure: callers
/// inject `now` and persist the timestamps. Five per hour bounds a launch or
/// enable/disable crash loop without stopping the one legitimate rearm after a
/// restart.
struct HomeServerRearmBudget: Equatable {
    static let maximumPerHour = 5
    static let window: TimeInterval = 3600

    /// Timestamps of automatic rearms, oldest first.
    private(set) var rearms: [Date]

    init(rearms: [Date] = []) {
        self.rearms = rearms.sorted()
    }

    /// Drop entries outside the trailing window. A timestamp slightly in the
    /// future is kept (clock adjustment), never treated as a free rearm.
    mutating func prune(now: Date) {
        let earliest = now.addingTimeInterval(-Self.window)
        rearms.removeAll { $0 < earliest }
    }

    func rearmCount(now: Date) -> Int {
        let earliest = now.addingTimeInterval(-Self.window)
        return rearms.filter { $0 >= earliest }.count
    }

    func canRearm(now: Date) -> Bool {
        rearmCount(now: now) < Self.maximumPerHour
    }

    /// Record one automatic rearm. Returns false (and records nothing) when the
    /// budget is exhausted, so a caller can log the refusal without consuming a
    /// slot it did not get.
    @discardableResult
    mutating func recordRearm(now: Date) -> Bool {
        prune(now: now)
        guard rearms.count < Self.maximumPerHour else { return false }
        rearms.append(now)
        return true
    }

    func remaining(now: Date) -> Int {
        max(0, Self.maximumPerHour - rearmCount(now: now))
    }

    mutating func reset() { rearms.removeAll() }
}
