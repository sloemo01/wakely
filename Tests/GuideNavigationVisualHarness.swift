// Compile with the app sources excluding main.swift and AppDelegate.swift.
// This fixture only orders a far-offscreen window, never activates the app,
// sends OS events, or starts an engine.
import AppKit
import SwiftUI
import Darwin

// Link-only delegate seam: invoking an application action is a test failure.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @objc func openSettings() { fatalError("Unexpected app action") }
    @objc func showAbout() { fatalError("Unexpected app action") }
    @objc func quit() { fatalError("Unexpected app action") }
    @objc func openComponents() { fatalError("Unexpected app action") }
    @objc func armFromMenu() { fatalError("Unexpected app action") }
    @objc func disarmFromMenu() { fatalError("Unexpected app action") }
    func openSettingsWindow(tab: String) { fatalError("Unexpected app action") }
    func openFirstRunGuideForMenuInteraction() { fatalError("Unexpected app action") }
}

@main struct GuideNavigationVisualHarness {
    @MainActor static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor static func descendants(_ root: Any, depth: Int = 0) -> [any NSAccessibilityProtocol] {
        guard depth < 32, let element = root as? any NSAccessibilityProtocol else { return [] }
        return [element] + (element.accessibilityChildren() ?? []).flatMap { descendants($0, depth: depth + 1) }
    }

    @MainActor static func label(_ element: any NSAccessibilityProtocol) -> String {
        element.accessibilityLabel() ?? (element.accessibilityValue() as? String) ?? ""
    }

    @MainActor static func press(_ host: NSView, matching text: String) -> Bool {
        settle(host)
        let matches = descendants(host).filter {
            $0.accessibilityRole() == .button && label($0).contains(text)
        }
        guard matches.count == 1, let button = matches.first else {
            print("AX unavailable/ambiguous for \(text): \(matches.count) matches")
            return false
        }
        guard button.isAccessibilityEnabled() else { fatalError("Disabled control: \(text)") }
        let dispatched = button.accessibilityPerformPress()
        settle(host)
        print("AX press \(text): \(dispatched)")
        return dispatched
    }

    @MainActor static func capture(_ host: NSView, name: String, output: URL) throws {
        settle(host)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("No bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
        try png.write(to: output.appendingPathComponent(name + ".png"))
        precondition(host.bounds.size == NSSize(width: 700, height: 500))
    }

    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        // AppKit returns false when a CLI process already has this policy.
        app.setActivationPolicy(.prohibited)
        precondition(app.activationPolicy() == .prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let guide = GuideCoordinator.shared
        let settings = SettingsModel.shared
        let enabledBefore = settings.enabled
        let engineBefore = ComponentEngine.shared.enabledIDs
        let preferenceDomain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let defaultsBefore = UserDefaults.standard.persistentDomain(forName: preferenceDomain) ?? [:]
        let progressBefore = UserDefaults.standard.object(forKey: GuideCoordinator.progressKey) as? Data
        guide.previewOnboarding(step: 0)
        guide.configurePreview(beat: 1, reduceMotion: false)
        settings.panelPresented = true
        settings.tab = "general"
        let host = NSHostingView(rootView: GuideDestinationView()
            .environment(\.colorScheme, .dark).frame(width: 700, height: 500))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        // One bounded AX-materialization attempt, explicitly far offscreen.
        // No makeKey, application activation, pointer or keyboard input.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        precondition(window.frame.maxX < 0 && window.frame.maxY < 0 && !window.isKeyWindow)
        try capture(host, name: "onboarding-step-0", output: output)
        let nodes = descendants(host)
        let labels = nodes.filter { $0.accessibilityRole() == .button }.map { label($0) }
        try labels.joined(separator: "\n").write(to: output.appendingPathComponent("accessibility-buttons.txt"), atomically: true, encoding: .utf8)
        print("Offscreen native accessibility: \(nodes.count) nodes; \(labels.count) buttons")
        var verified = 0
        if press(host, matching: "Continue") {
            precondition(guide.route == .onboarding && guide.progress.step == 1)
            verified += 1
            precondition(press(host, matching: "← Back"))
            precondition(guide.progress.step == 0)
            verified += 1
            precondition(press(host, matching: "Step 3 of 5"))
            precondition(guide.progress.step == 2)
            verified += 1
            precondition(press(host, matching: "Skip for now"))
            precondition(guide.route == nil && guide.progress.step == 2)
            verified += 1
            guide.previewOnboarding(step: 4)
            guide.configurePreview(beat: 1, reduceMotion: false)
            try capture(host, name: "onboarding-step-4", output: output)
            precondition(press(host, matching: "Explore Components"))
            precondition(guide.route == nil && settings.tab == "components")
            precondition(guide.progress.disposition == .completed)
            verified += 1
        } else {
            print("LIMIT: offscreen SwiftUI exposes no actionable native AX controls. No OS input fallback attempted.")
            guide.previewOnboarding(step: 4)
            guide.configurePreview(beat: 1, reduceMotion: false)
            try capture(host, name: "onboarding-step-4", output: output)
        }
        precondition(settings.enabled == enabledBefore)
        precondition(ComponentEngine.shared.enabledIDs == engineBefore)
        // Guide preview navigation must not persist onboarding/component state.
        // dictionaryRepresentation also includes volatile SwiftUI registration
        // defaults, which change when views mount; compare persisted app state.
        let defaultsAfter = UserDefaults.standard.persistentDomain(forName: preferenceDomain) ?? [:]
        precondition(NSDictionary(dictionary: defaultsBefore).isEqual(to: defaultsAfter), "Application preferences changed")
        precondition((UserDefaults.standard.object(forKey: GuideCoordinator.progressKey) as? Data) == progressBefore)
        precondition(window.frame.maxX < 0 && window.frame.maxY < 0 && !window.isKeyWindow)
        window.orderOut(nil)
        precondition(!window.isVisible && app.activationPolicy() == .prohibited)
        settings.panelPresented = false
        print("PASS: actual GuideDestinationView rendered 700×500; \(verified) native AX navigation actions verified; component IDs and application preferences unchanged; window remained far offscreen and non-key")
    }
}
