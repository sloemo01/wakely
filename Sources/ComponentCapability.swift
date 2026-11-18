// ComponentCapability — what this build can actually do, per component.
//
// This file is data, not a test. Reading it never enables or disables a component,
// touches hardware, plays audio, ejects a volume, changes a preference, or asks
// for a permission. It exists so the built-in report can state a capability
// honestly instead of printing PASS for a code path that was never exercised.
//
// Statuses:
//   implemented          the automatic runtime path for the advertised behavior
//                        exists in this build (still not hardware-verified).
//   partial              part of the advertised behavior is missing; the reason
//                        names the missing part.
//   protectedManualOnly  the behavior exists only as an explicit, user-authorized
//                        action (a manual trigger or an administrator-approved
//                        protected setting). No automatic tick performs it.
//   unsupported          no implementation exists; the reason names what is
//                        missing and why it is not attempted.
//
// A component id with no entry is reported UNSUPPORTED, never assumed to work.

import Foundation

enum ComponentCapabilityStatus: String, Equatable, Hashable {
    case implemented
    case partial
    case protectedManualOnly
    case unsupported

    var label: String {
        switch self {
        case .implemented: return "IMPLEMENTED"
        case .partial: return "PARTIAL"
        case .protectedManualOnly: return "PROTECTED/MANUAL-ONLY"
        case .unsupported: return "UNSUPPORTED"
        }
    }
}

struct ComponentCapability: Equatable {
    let componentID: String
    let status: ComponentCapabilityStatus
    /// One line, no newline. Says what works, or exactly what does not.
    let reason: String
}

enum ComponentCapabilityPolicy {

    /// One explicit entry per ComponentCatalog id. Keep this table in step with the
    /// runtime: an entry describes shipped behavior, not an intention.
    static let entries: [ComponentCapability] = [

        // MARK: Agents
        .init(componentID: "agentScreen", status: .partial,
              reason: "holds a display-sleep assertion only for working agents whose last transcript tool call is screen or browser work, active or completed within a 120s grace; the registry schema, five tool kinds and default grace are unverified"),
        .init(componentID: "agentStatus", status: .partial,
              reason: "menu counts, per-session display names and provider/PID rows work; the Claude session-index adapter is defensive because the schema, path and sentinel semantics are unverified"),
        .init(componentID: "finishWorkThenSleep", status: .implemented,
              reason: "bounded hold on explicitly observed agent work (12h cap by default, 15min waiting cap, 180s release grace)"),
        .init(componentID: "agentNotifications", status: .implemented,
              reason: "per-agent busy->idle and waiting transitions from AgentMonitor, suppressed while that agent's app or terminal is frontmost; delivery uses Wakely-owned UserNotifications authorization; macOS notification settings and Focus modes can suppress it"),
        .init(componentID: "agentLight", status: .implemented,
              reason: "menu bar icon tint follows agent counts (green working, orange waiting); nothing is installed or configured"),
        .init(componentID: "sleepUntilReset", status: .partial,
              reason: "owned one-off wakes are scheduled 60s after a locally observed reset, reconciled on lid close, adopted from the helper after a relaunch and cancelled on lid open, disable and quit; enablement now requires a helper that reports its wake store, and no wake was hardware-verified"),

        // MARK: Keyboard
        .init(componentID: "capsLock", status: .implemented,
              reason: "watcher turns the Caps Lock key into arm/disarm; the typing filter additionally needs Accessibility and is not required for arming"),
        .init(componentID: "cleaningLock", status: .protectedManualOnly,
              reason: "turning the switch on explicitly starts a timed input lock after Accessibility is granted; Escape, timeout, session-arming safety or switching off ends it and resets the switch"),
        .init(componentID: "lidCloseSound", status: .implemented,
              reason: "one sound per close while armed, requested as the hinge crosses 30 degrees so the speaker is still powered (the registry transition is the fallback); asset decoding is unit-tested, actual audibility is not verified by this report"),
        .init(componentID: "quietClose", status: .implemented,
              reason: "mutes the exact output device after a real lid close and restores its previous mute state on open or session end"),

        // MARK: Security
        .init(componentID: "passwordAfterClose", status: .partial,
              reason: "the privileged helper turns system Touch ID unlock off at lid close and restores it at the next observed unlock, or at lid open, wake, launch or quit when the screen is provably unlocked; locked or unknown states defer the restore so that unlock still needs a password or Apple Watch, and hardware is unverified"),
        .init(componentID: "bagCheck", status: .implemented,
              reason: "one notice per closed episode, 60s after the lid is closed with Wakely unarmed"),

        // MARK: Power
        .init(componentID: "alwaysOnPluggedIn", status: .implemented,
              reason: "automatic hold while the Mac is on AC power"),
        .init(componentID: "homeServer", status: .partial,
              reason: "the plugged-in hold and a gated login-item relaunch exist, the privileged helper sets `pmset -c autorestart` where this Mac reports it, and automatic rearm is budgeted to 5 per hour; firmware auto-boot and a live restart are unverified"),
        .init(componentID: "lowPowerWhileClosed", status: .implemented,
              reason: "the privileged helper switches battery low power mode on for a closed armed session and restores the saved value on session end, lid open, disable and quit; it does nothing on AC power or when pmset does not report lowpowermode"),
        .init(componentID: "batteryBudget", status: .implemented,
              reason: "per-session battery accounting for a closed armed session; disarms at the configured budget"),
        .init(componentID: "keepAwake", status: .protectedManualOnly,
              reason: "starts only from an explicit menu choice and holds a separate lid-open assertion; it never arms a closed session"),
        .init(componentID: "sleepMeansSleep", status: .partial,
              reason: "the privileged helper suppresses supported battery powernap, proximitywake and womp settings while enabled and restores their saved values on disable; third-party scheduled wake events and unsupported wake sources are not cancelled"),
        .init(componentID: "stayOffWhenOpened", status: .partial,
              reason: "the privileged helper writes `BootPreference=%00` while enabled and deletes the key to restore it; a refused write is reported, and a firmware that ignores the key is not detectable from the helper"),
        .init(componentID: "finishJobsThenSleep", status: .implemented,
              reason: "bounded hold on known transfer/backup processes plus chosen bundle ids (8h cap, 120s release grace)"),
        .init(componentID: "sleepWhenIdle", status: .implemented,
              reason: "disarms a closed session after 15min by default with no agents, remote sessions, network activity or jobs, and can re-arm on new activity"),
        .init(componentID: "sleepTimer", status: .implemented,
              reason: "fades output over the last minute, disarms, then sleeps after a cancellable delay that a newer session invalidates"),
        .init(componentID: "fanBoost", status: .implemented,
              reason: "the privileged helper validates FNum/F0Md/F0Tg and writes a fan target through AppleSMC only on supported models; the exact post-write RPM is reported, and the physical RPM change is not verified by this report"),
        .init(componentID: "ejectOnSleep", status: .implemented,
              reason: "ejects external volumes at real system sleep; skips Time Machine, selected drives, external displays and armed sessions, and volume enumeration plus ejection run off the main thread"),

        // MARK: Connections
        .init(componentID: "bluetoothOffWhileClosed", status: .implemented,
              reason: "turns Bluetooth off only at real system sleep with the lid closed, unarmed and no external display; restores on wake, session start and quit"),
        .init(componentID: "awakeWhileConnected", status: .implemented,
              reason: "hold while lsof/who report remote SSH or screen-sharing sessions, with a 600s grace after the last one drops"),
        .init(componentID: "lidShortcuts", status: .implemented,
              reason: "runs the named Shortcut on a real lid open/close; a missing or renamed Shortcut is not detected by this report"),
        .init(componentID: "armWhileAppRuns", status: .implemented,
              reason: "hold while the chosen bundle id is running"),
        .init(componentID: "armOnWiFi", status: .implemented,
              reason: "hold while joined to the chosen SSID on AC power; reading the SSID needs Location permission, and without it the condition is never true"),
        .init(componentID: "armOnSchedule", status: .implemented,
              reason: "weekday and time window on AC power, including overnight windows that belong to their start day"),
        .init(componentID: "armWhenDriveConnects", status: .implemented,
              reason: "hold while a selected external volume is mounted; identity is by volume UUID with a path fallback")
    ]

    private static let index: [String: ComponentCapability] = Dictionary(
        entries.map { ($0.componentID, $0) }, uniquingKeysWith: { first, _ in first })

    /// Fail closed: an unregistered id is unsupported, never "probably fine".
    static func capability(for componentID: String) -> ComponentCapability {
        index[componentID] ?? ComponentCapability(componentID: componentID, status: .unsupported,
                                            reason: "no capability entry is registered for this component")
    }

    static func isRegistered(_ componentID: String) -> Bool { index[componentID] != nil }

    static var registeredIDs: Set<String> { Set(entries.map(\.componentID)) }

    /// Ids listed more than once. A duplicate is a table bug, not a preference.
    static var duplicateIDs: [String] {
        var seen: Set<String> = [], duplicates: Set<String> = []
        for entry in entries where !seen.insert(entry.componentID).inserted { duplicates.insert(entry.componentID) }
        return duplicates.sorted()
    }
}
