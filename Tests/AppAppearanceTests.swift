import AppKit
import SwiftUI

@main struct AppAppearanceTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        precondition(AppearanceChoice(persistedValue: nil) == .system)
        precondition(AppearanceChoice(persistedValue: "invalid") == .system)
        precondition(AppearanceChoice(persistedValue: "light") == .light)
        precondition(AppearanceChoice(persistedValue: "dark") == .dark)
        let suite = "wakely.test.appearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); app.appearance = nil }
        let controller = AppAppearance(defaults: defaults, environment: [:])
        precondition(controller.choice == .system)
        controller.apply()
        precondition(app.appearance == nil, "System clears the app override")
        controller.choice = .light
        precondition(defaults.string(forKey: AppAppearance.defaultsKey) == "light")
        precondition(app.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        controller.choice = .dark
        precondition(defaults.string(forKey: AppAppearance.defaultsKey) == "dark")
        precondition(app.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        controller.choice = .system
        precondition(app.appearance == nil && controller.preferredColorScheme == nil)
        let qa = AppAppearance(defaults: defaults, environment: ["WAKELY_APPEARANCE": "light"])
        precondition(qa.choice == .light)
        precondition(defaults.string(forKey: AppAppearance.defaultsKey) == "system", "QA override must not persist")
        defaults.set(42, forKey: "unrelated")
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(qa.choice == .light, "Unrelated defaults must not reset QA appearance")
        print("PASS: appearance fallback, persistence, live native overrides and isolated QA checks")
    }
}
