import Foundation

/// Per-component defaults, used by the detail page's Restore Defaults link.
/// Only the keys a component actually owns are touched, so restoring one
/// component never changes a sibling.
enum ComponentDefaults {
    /// The full set of keys each component's controls can write.
    static func keys(for componentID: String) -> [String: Any] {
        switch componentID {
        case "lidCloseSound": return ["lidCloseSoundName": "shell"]
        case "batteryBudget": return ["batteryBudget.percent": 15]
        case "sleepTimer": return ["sleepTimer.minutes": 30]
        case "sleepWhenIdle": return ["sleepWhenIdle.minutes": 15]
        case "keepAwake": return ["keepAwake.minutes": 120]
        case "awakeWhileConnected": return ["awakeWhileConnected.graceMinutes": 10]
        case "armOnSchedule":
            return ["armOnSchedule.start": "22:00",
                    "armOnSchedule.end": "07:00",
                    "armOnSchedule.weekdays": Array(1...7)]
        case "armWhenDriveConnects": return ["armWhenDriveConnects.volumeIDs": [String]()]
        case "armOnWiFi": return ["armOnWiFi.ssid": ""]
        case "armWhileAppRuns": return ["armWhileAppRuns.bundleID": ""]
        case "lidShortcuts": return ["lidShortcuts.close": "", "lidShortcuts.open": ""]
        case "passwordAfterClose":
            return ["passwordAfterClose.externalDisplay": false,
                    "passwordAfterClose.immediate": true]
        case "fanBoost": return ["fanBoost.percent": 60]
        case "agentLight": return ["agentLight.minutes": 60]
        case "finishWorkThenSleep":
            return ["finishWorkThenSleep.waitMinutes": 15,
                    "finishWorkThenSleep.maxHours": 12]
        case "finishJobsThenSleep":
            return ["finishJobsThenSleep.waitMinutes": 2,
                    "finishJobsThenSleep.maxHours": 8]
        case "agentScreen": return ["agentScreen.minutes": 2]
        case "agentNotifications":
            return ["agentNotifications.sound": true,
                    "agentNotifications.waiting": true,
                    "agentNotifications.finished": true]
        case "ejectOnSleep": return ["ejectOnSleep.remount": true]
        case "cleaningLock": return ["cleaningLock.seconds": 60]
        case "sleepUntilReset":
            return ["sleepUntilReset.idleMinutes": 30,
                    "sleepUntilReset.waitingMinutes": 15]
        default: return [:]
        }
    }

    static func isModified(_ componentID: String,
                           defaults: UserDefaults = .standard) -> Bool {
        keys(for: componentID).contains { key, fallback in
            guard let current = defaults.object(forKey: key) else { return false }
            return !equal(current, fallback)
        }
    }

    /// Writes every owned key back to its default. The caller refreshes the
    /// detail view so direct UserDefaults-backed chips re-read their values.
    static func restore(_ componentID: String, defaults: UserDefaults = .standard) {
        for (key, fallback) in keys(for: componentID) {
            defaults.set(fallback, forKey: key)
        }
    }

    private static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (a as Int, b as Int): return a == b
        case let (a as Bool, b as Bool): return a == b
        case let (a as String, b as String): return a == b
        case let (a as [Int], b as [Int]): return a == b
        case let (a as [String], b as [String]): return a == b
        default: return false
        }
    }
}