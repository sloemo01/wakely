import AppKit
import SwiftUI

// Opt-in, isolated UI regression fixture. Uses the real guide views and the
// shared coordinator, but never starts the component engine or system services.
@main
struct GuideInteractiveApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = GuideInteractiveDelegate()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
        withExtendedLifetime(delegate) {}
    }
}

// Link-only application-action seam for component source files. The fixture
// never casts its own delegate to this type or invokes any of these actions.
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

@MainActor
final class GuideInteractiveDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var host: NSHostingController<AnyView>?
    private var assertionTask: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        try? "started\n".write(toFile: "/tmp/wakely-guide-ui-lifecycle.log", atomically: true, encoding: .utf8)
        _ = WakelyType.registerBundledFonts()
        let window = NSWindow(contentRect: NSRect(x: 100, y: 160, width: 700, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Wakely Guide QA"
        window.isReleasedWhenClosed = false
        self.window = window
        if CommandLine.arguments.contains("--reduced-motion") {
            window.contentView = NSHostingView(rootView: GuideDestinationView()
                .environment(\.colorScheme, .dark)
                .frame(width: 700, height: 500))
            window.contentView?.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
            GuideCoordinator.shared.previewOnboarding(step: 0)
            GuideCoordinator.shared.configurePreview(beat: 1, reduceMotion: true)
            window.orderFrontRegardless()
            return
        }
        SettingsModel.shared.panelPresented = true
        GuideCoordinator.shared.previewOnboarding(step: 0)
        let view = AnyView(SettingsView())
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        window.setContentSize(NSSize(width: 900, height: 620))
        controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        controller.view.autoresizingMask = [.width, .height]
        window.contentViewController = controller
        host = controller
        window.orderFrontRegardless()
        try? "window \(window.frame)\n".write(toFile: "/tmp/wakely-guide-ui-lifecycle.log", atomically: true, encoding: .utf8)
        assertionTask = Task { @MainActor in
            for _ in 0..<1200 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                if CommandLine.arguments.contains("--selftest") {
                guard let step = CommandLine.arguments.first(where: { $0.hasPrefix("--step=") }) else { self.selftest(); continue }
                if self.selftest(step) { self.selftest() }
            }
            }
            fputs("Guide QA timed out; no real app state was changed\n", stderr)
            NSApp.terminate(nil)
        }
    }

    private var stage = "launch"
    private func fail(_ message: String) -> Never {
        let text = "\(stage): \(message)\n"
        FileManager.default.createFile(atPath: "/tmp/wakely-guide-ui-failure.txt", contents: Data(text.utf8))
        NSApp.terminate(nil)
        fatalError(message)
    }
    private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }
    private func selftest(_ step: String? = nil) -> Bool {
        let guide = GuideCoordinator.shared
        let settings = SettingsModel.shared
        let before = (guide.route, guide.progress.step)
        stage = "assert \(step ?? "done") from \(before.0) \(before.1)"
        print("QA \(stage)")
        switch step {
        case "--step=continue":
            require(guide.progress.step == 1, "Continue did not advance")
            guide.previewOnboarding(step: 1)
        case "--step=back":
            require(guide.progress.step == 0, "Back did not return")
            guide.previewOnboarding(step: 0)
        case "--step=dot":
            require(guide.progress.step == 2, "Progress dot did not navigate")
            guide.previewOnboarding(step: 2)
        case "--step=skip":
            require(guide.route == nil, "Skip did not dismiss")
            require(guide.progress.step == 2, "Skip lost its position")
            require(guide.progress.disposition == .dismissed, "Skip incorrectly completed")
            guide.previewOnboarding(step: 4)
        case "--step=finish":
            require(guide.route == nil, "Explore did not finish")
            require(guide.progress.disposition == .completed, "Explore did not persist completion")
            require(settings.tab == "components", "Explore chose wrong destination")
            require(settings.detailComponent == nil, "Explore left a detail route")
            settings.detailComponent = ComponentCatalog.definition(for: "agentScreen")
            settings.selectedComponent = "agentScreen"
            guide.previewOnboarding(step: 0)
            guide.dismiss()
        case "--step=replay":
            require(guide.route == .onboarding, "Replay did not open tour")
            require(guide.progress.step == 0, "Replay did not reset")
        case "--step=done":
            print("QA observed enabledIDs=\(ComponentEngine.shared.enabledIDs)")
            print("PASS: guide QA completed; no component enable/disable action was invoked")
            NSApp.terminate(nil)
            return false
        default: return false
        }
        return true
    }
}
