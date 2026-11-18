import Foundation

// Presentation data only: no permissions, engine calls or system effects.
enum GuideSceneKind: String, CaseIterable {
    case welcome, awakeModes, components, permissions, ready, agents, display, notification, light, reset, keyboard, sound, lock, battery, charger, timer, fan, drive, bluetooth, connection, shortcut, application, wifi, schedule, sleep
}

struct GuideBeat: Equatable {
    let title: String
    let caption: String
}

struct OnboardingPage: Identifiable {
    let id: String
    let title: String
    let body: String
    let scene: GuideSceneKind
    let beats: [GuideBeat]
}

enum OnboardingCatalog {
    static let pages: [OnboardingPage] = [
        .init(id: "welcome", title: "Meet Wakely", body: "Choose when your Mac stays awake. Start from the menu bar.", scene: .welcome,
              beats: [.init(title: "Open", caption: "Find Wakely's eye in the menu bar."), .init(title: "Choose", caption: "Pick how to stay awake."), .init(title: "Control", caption: "End a hold when you are done.")]),
        .init(id: "awakeModes", title: "Two ways to stay awake", body: "Keep Awake is lid-open only. Arm Wakely prepares a closed-lid session.", scene: .awakeModes,
              beats: [.init(title: "Lid open", caption: "Choose Keep Awake and a duration."), .init(title: "Lid closed", caption: "Use Arm Wakely separately."), .init(title: "Close", caption: "Keep Awake ends; a separate Arm request stays.")]),
        .init(id: "components", title: "Make it yours", body: "Choose the components you need. Each one explains when it runs.", scene: .components,
              beats: [.init(title: "Browse", caption: "Find a rule that fits."), .init(title: "Choose", caption: "Check its trigger and limits."), .init(title: "Combine", caption: "Separate awake holds can coexist.")]),
        .init(id: "permissions", title: "Only as needed", body: "Wakely asks for access only when a component needs it. You decide what to allow.", scene: .permissions,
              beats: [.init(title: "Choose", caption: "Enable a component you want."), .init(title: "Review", caption: "See only the access it needs."), .init(title: "Decide", caption: "Opening Settings does not grant access.")]),
        .init(id: "ready", title: "Ready when you are", body: "Nothing is armed by this guide. Choose an awake mode from the menu bar.", scene: .ready,
              beats: [.init(title: "Finish", caption: "Close this introduction."), .init(title: "Choose", caption: "Start a mode when you need it."), .init(title: "Check", caption: "Review active holds before closing the lid.")])
    ]
}
