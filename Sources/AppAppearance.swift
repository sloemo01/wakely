import AppKit
import SwiftUI

/// Stable persisted values. Missing or unrecognised preferences follow macOS.
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
    init(persistedValue: String?) {
        self = persistedValue.flatMap(Self.init(rawValue:)) ?? .system
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

extension Notification.Name {
    static let wakelyAppearanceDidChange = Notification.Name("wakelyAppearanceDidChange")
}

/// Shared by settings and AppKit consumers. Apply once before constructing windows.
/// System deliberately clears the app override, rather than sampling macOS once.
@MainActor
final class AppAppearance: ObservableObject {
    static let shared = AppAppearance()
    static let defaultsKey = "wakely.appearance"

    @Published var choice: AppearanceChoice {
        didSet {
            guard choice != oldValue else { return }
            lastPersistedValue = choice.rawValue
            defaults.set(choice.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }
    @Published private(set) var revision: UInt = 0
    var preferredColorScheme: ColorScheme? { choice.colorScheme }

    private let defaults: UserDefaults
    private let application: NSApplication
    private let observations = AppearanceObservations()
    private var lastPersistedValue: String?

    init(defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.defaults = defaults
        // NSApp can still be nil during early startup or an isolated test.
        application = NSApplication.shared
        let saved = defaults.string(forKey: Self.defaultsKey)
        lastPersistedValue = saved
        // A launch-only visual QA override must never become a preference.
        choice = environment["WAKELY_APPEARANCE"].flatMap(AppearanceChoice.init(rawValue:))
            ?? AppearanceChoice(persistedValue: saved)
        observations.appearance = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.announceChange() }
        }
        observations.defaults = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let rawValue = self.defaults.string(forKey: Self.defaultsKey)
                // Unrelated preference notifications must not clear QA mode.
                guard rawValue != self.lastPersistedValue else { return }
                self.lastPersistedValue = rawValue
                let saved = AppearanceChoice(persistedValue: rawValue)
                if self.choice != saved { self.choice = saved }
            }
        }
    }

    func apply() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            application.appearance = choice.appearanceName.flatMap(NSAppearance.init(named:))
            announceChange()
        }
    }

    private func announceChange() {
        revision &+= 1
        NotificationCenter.default.post(name: .wakelyAppearanceDidChange, object: self)
    }
}

/// Own both observer tokens independently of actor-isolated controller teardown.
private final class AppearanceObservations {
    var appearance: NSKeyValueObservation?
    var defaults: NSObjectProtocol?
    deinit {
        appearance?.invalidate()
        if let defaults { NotificationCenter.default.removeObserver(defaults) }
    }
}

/// Popovers and auxiliary windows need their own observation: they may live in
/// a separate hosting tree from the settings root.
struct AppAppearanceModifier: ViewModifier {
    @ObservedObject private var appearance = AppAppearance.shared
    func body(content: Content) -> some View {
        content
            .preferredColorScheme(appearance.preferredColorScheme)
            .animation(nil, value: appearance.choice)
    }
}
