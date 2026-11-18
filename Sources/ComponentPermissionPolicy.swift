import Foundation

/// Pure onboarding policy. No checks in this file prompt, enable a component,
/// alter system settings, or assume that opening Settings grants access.
enum ComponentPermission: String, CaseIterable {
    case accessibility, location, notifications, helper

    var title: String {
        switch self {
        case .accessibility: return "Accessibility"
        case .location: return "Location Services"
        case .notifications: return "Notifications"
        case .helper: return "Wakely Helper"
        }
    }

    var settingsURL: URL {
        let route: String
        switch self {
        case .accessibility: route = "com.apple.preference.security?Privacy_Accessibility"
        case .location: route = "com.apple.preference.security?Privacy_LocationServices"
        case .notifications: route = "com.apple.preference.notifications"
        case .helper: route = "com.apple.LoginItems-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:" + route)!
    }

    var supportsAppDrag: Bool { self == .accessibility }

    var instructions: String {
        switch self {
        case .accessibility:
            return "In Privacy & Security → Accessibility, turn on Wakely. If it is missing, drag the app below into the list, or use + and choose it in Finder. You may need to unlock Settings first."
        case .location:
            return "Allow Wakely to read your current Wi-Fi network. macOS protects network names with Location Services. Use Allow Location first; if access was denied, turn on Wakely in Privacy & Security → Location Services. This list is managed by macOS—you cannot drag an app into it."
        case .notifications:
            return "Allow notifications so this component can reach you. If you previously denied access, open Notifications → Wakely and turn on Allow Notifications. Focus modes can still silence delivery. There is no app to drag into this list."
        case .helper:
            return "This component needs Wakely’s privileged helper to change a system setting. Install it once; macOS will ask for your administrator password (or, for a Developer ID build, show a Login Items approval). No Apple ID is required. Wakely then checks this Mac’s hardware support before turning the component on."
        }
    }
}

struct ComponentPermissionRequirement: Equatable {
    let permission: ComponentPermission
    let required: Bool
}

enum ComponentPermissionPolicy {
    static let helperIDs: Set<String> = [
        "passwordAfterClose", "lowPowerWhileClosed", "fanBoost",
        "stayOffWhenOpened", "sleepUntilReset", "sleepMeansSleep"
    ]

    static func requirements(for id: String) -> [ComponentPermissionRequirement] {
        switch id {
        case "cleaningLock": return [.init(permission: .accessibility, required: true)]
        case "capsLock": return [.init(permission: .accessibility, required: false)]
        case "armOnWiFi": return [.init(permission: .location, required: true)]
        case "agentNotifications", "bagCheck": return [.init(permission: .notifications, required: true)]
        default:
            return helperIDs.contains(id) ? [.init(permission: .helper, required: true)] : []
        }
    }

    /// An input lock must be reconfirmed after leaving System Settings.
    static func resumesEnableAfterGrant(_ id: String) -> Bool { id != "cleaningLock" }

    static func missingRequired(for id: String, ready: Set<ComponentPermission>) -> [ComponentPermission] {
        requirements(for: id).filter { $0.required && !ready.contains($0.permission) }.map(\.permission)
    }
}
