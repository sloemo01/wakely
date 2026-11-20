// AppDelegate — wiring: URL commands, the menu bar, the settings window, quit.

import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBar: MenuBarController?
    private var settingsController: NSViewController?
    private var aboutWindow: NSWindow?
    private var terminationTask: Task<Void, Never>?
    private var enablementObserver: NSObjectProtocol?
    private var rearmBudget = HomeServerRearmBudget()
    private var terminating = false
    private var guideLaunchWasNew = false
    private var guideLaunchContext = GuideLaunchContext(foregroundOpen: false, loginOrBackground: true)
    private var guideLaunchCommandReceived = false
    private var guideLaunchBegan = Date.distantPast
    private var guideLaunchFinished = false
    /// Persisted so a crash-looping launch cannot rearm more than the budget.
    private static let rearmBudgetKey = "homeServer.rearmTimes"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Establish freshness before startup writes a log or starts services.
        let diagnosticsExisted = FileManager.default.fileExists(atPath:
            Diagnostics.supportDirectory.appendingPathComponent("diagnostics.log").path)
        guideLaunchWasNew = !GuideLaunchContext.hasExistingInstallation(diagnosticsExisted: diagnosticsExisted)
        guideLaunchContext = GuideLaunchContext.current()
        guideLaunchBegan = Date()
        GuideCoordinator.shared.classifyExistingInstallation(!guideLaunchWasNew)
        AppAppearance.shared.apply()
        // Register the bundled OFL pixel faces before any window renders text.
        // If this ever fails, Font.custom falls back to the system face.
        _ = ClamType.registerBundledFonts()
        if ProcessInfo.processInfo.environment["WAKELY_FONT_DIAGNOSTICS"] == "1" {
            print("fonts: \(ClamType.resolvedFontSummary())")
        }
        // Publish this instance before anything can arm: the watchdog needs a
        // PID plus kernel start time to tell this process from a later PID reuse.
        AppLiveness.beginIdle()
        // Tell the deletion watcher and the helper where the app lives, and
        // keep the watcher agent installed. Both survive an app update swap.
        InstallRecord.publish()
        _ = UninstallWatcherInstaller.installIfNeeded()
        // There is no install step: set the helper up quietly the first time,
        // and never block arming on it.
        Task { @MainActor in
            await HelperClient.shared.registerSilentlyIfNeeded()
            // The login agent only earns its place once the privileged helper
            // exists; registration reports its real status and never prompts.
            if case .installed = HelperClient.shared.installState {
                _ = AppLiveness.registerAgentIfNeeded(helperInstalled: true)
                // A clean agent exit is not restarted by launchd for the rest of
                // this login, so a relaunch after one would be unwatched. Ask for
                // a fresh agent; the call itself skips unless the agent is
                // actually enabled, and it never kills a running watcher.
                AppLiveness.kickstartAgentIfNeeded()
            }
        }
        Diagnostics.truncateIfNeeded()
        Diagnostics.log("launch")
        // Throttled to once a day; the prompt itself is once per release.
        UpdateManager.shared.checkOnLaunch()
        CapsLockLight.reportTrust()
        CapsLockLight.onCapsLockChange = { on in
            guard ComponentEngine.shared.isEnabled("capsLock") else { return }
            Diagnostics.log("caps lock switch: \(on ? "on" : "off")")
            if on {
                let lifetime = ArmSessionLifetime.capsLock(
                    oneClose: UserDefaults.standard.bool(forKey: "capsLockOneClose"))
                // Already armed by something else: Caps takes the session over
                // instead of silently doing nothing (logged as
                // "caps lock took over the armed session").
                if !PowerEngine.shared.takeOverSession(lifetime: lifetime, source: "Caps Lock") {
                    _ = PowerEngine.shared.arm(source: "Caps Lock", lifetime: lifetime)
                }
            }
            else if PowerEngine.shared.isArmed { PowerEngine.shared.disarm(reason: "Caps Lock turned off") }
        }
        if ComponentEngine.shared.isEnabled("capsLock") { CapsLockLight.startWatching() }

        let engine = PowerEngine.shared
        engine.onStateChange = { [weak self] in
            AppLiveness.sync(armed: engine.isArmed, armedAt: engine.armedAt)
            self?.menuBar?.rebuild()
            AppState.shared.refreshFromEngine()
        }
        engine.onLidClosed = {
            ComponentEngine.shared.lidChanged(closed: true)
            Diagnostics.log("lid closed")
        }
        engine.onLidOpened = {
            ComponentEngine.shared.lidChanged(closed: false)
        }

        engine.startMonitoringIfNeeded()
        ComponentStore.shared.installKitIfNeeded()
        ComponentStore.shared.reload()
        ComponentStore.shared.startWatching()
        // Home Server owns the one documented launch arm. It runs before the
        // component engine's first tick so the session keeps the "home server"
        // source and consumes the persisted rearm budget exactly once.
        rearmBudget = Self.loadRearmBudget()
        // The component hold arms on AC every tick. Point it at the same persisted
        // budget so a launch the budget refused cannot be undone by the next
        // tick, and let it self-heal once the oldest rearm leaves the hour.
        HomeServerAutomation.automaticArmAllowed = { [weak self] in
            guard let self else { return false }
            return self.rearmBudget.canRearm(now: Date())
        }
        armHomeServerIfNeeded(reason: "launch")
        ComponentEngine.shared.start()
        ComponentRuntime.shared.start()

        // One login item covers Home Server, Password After Close and Sleep
        // Until Reset. Registration is gated on the enabled set and never blocks
        // launch: a pending approval is reported, not claimed.
        installEnablementObserver()
        LoginItem.sync(enabledComponentIDs: ComponentEngine.shared.enabledIDs, reason: "launch")
        // Finish or undo a Password After Close phase persisted by a previous
        // run. The helper probe inside never blocks launch.
        Task { @MainActor in
            await PasswordAfterCloseController.shared.didLaunch()
        }

        AgentMonitor.shared.onChange = { [weak self] in
            self?.menuBar?.rebuild()
            AppState.shared.refreshFromEngine()
        }
        AgentMonitor.shared.start()

        menuBar = MenuBarController()
        AppState.shared.refreshFromEngine()
        // Prepare the retained destination while the panel is hidden. A first
        // click must not decode sprites and build three hosting trees mid-spring.
        DispatchQueue.main.async { [weak self] in self?.prepareSettingsController() }

        // The app never arms itself at launch from the stored preference: the
        // launch path contains no such call and logs "no automatic arm at
        // launch" after an unclean exit. Home Server is the one
        // documented exception (component on, AC power, rearm budget satisfied) and
        // is armed above. The stored preference is kept for compatibility only.
        if AppState.shared.armOnLaunch {
            Diagnostics.log("no automatic arm at launch (stored preference ignored)")
        }

        Diagnostics.log("lid observer baseline: \(engine.lidClosed ? "closed" : "open")")
        guideLaunchFinished = true
        // Let startup URL events arrive first. Unknown/background launches never
        // acquire a foreground window just to advertise the tour.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.presentFirstRunGuideIfAppropriate()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        presentFirstRunGuideIfAppropriate()
    }

    func openFirstRunGuideForMenuInteraction() {
        guard GuideCoordinator.shared.presentOnFirstMenuInteraction(),
              !ComponentPermissions.shared.setupPresented,
              !SettingsModel.shared.showMakeYourOwn else { return }
        openSettingsWindow(tab: "components", preservingGuide: true)
    }

    private func presentFirstRunGuideIfAppropriate() {
        guard guideLaunchFinished, Date().timeIntervalSince(guideLaunchBegan) < 3,
              guideLaunchContext.foregroundOpen, NSApp.isActive,
              !guideLaunchCommandReceived,
              !ComponentPermissions.shared.setupPresented,
              !SettingsModel.shared.showMakeYourOwn else { return }
        if GuideCoordinator.shared.presentAutomatically(isNewUser: guideLaunchWasNew,
            isLoginLaunch: guideLaunchContext.loginOrBackground,
            receivedCommand: guideLaunchCommandReceived) {
            openSettingsWindow(tab: "components", preservingGuide: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard terminationTask == nil else { return .terminateLater }
        terminating = true
        if let enablementObserver {
            NotificationCenter.default.removeObserver(enablementObserver)
            self.enablementObserver = nil
        }
        Diagnostics.log("termination signal received; waiting for orderly cleanup")
        // Freeze the liveness record at its last armed state: if this process
        // dies during the drain, the session still reads as interrupted.
        AppLiveness.beginTermination()
        // Keep the main run loop alive for XPC replies and asynchronous restore
        // work. A second quit request must not start another cleanup or reply.
        terminationTask = Task { @MainActor in
            AgentMonitor.shared.stop()
            ComponentRuntime.shared.stop()
            ComponentEngine.shared.stop()
            PowerEngine.shared.shutDown()
            let restored = await ComponentEngine.shared.awaitShutdownRestoration(timeout: 8)
            let powerCleaned = await PowerEngine.shared.awaitShutdownCleanup(timeout: 3)
            Diagnostics.log(restored && powerCleaned ? "termination cleanup completed" : "termination cleanup incomplete or deadline reached; unresolved helper leases retained for recovery")
            // The drains are done: a clean quit must leave no marker behind.
            AppLiveness.clear()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Home Server relaunch / login

    /// One observer for the built-in enablement signal. It keeps the shared
    /// login item in step and gives Home Server its launch/disable arms without
    /// teaching every component about either.
    private func installEnablementObserver() {
        guard enablementObserver == nil else { return }
        enablementObserver = NotificationCenter.default.addObserver(
            forName: .componentEnablementChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                LoginItem.sync(enabledComponentIDs: ComponentEngine.shared.enabledIDs,
                               reason: "component enablement changed")
                guard (note.object as? String) == "homeServer" else { return }
                if ComponentEngine.shared.isEnabled("homeServer") {
                    self.armHomeServerIfNeeded(reason: "Home Server enabled")
                } else {
                    // Teardown already releases this owner; the call is
                    // idempotent and guarantees the disable is never swallowed
                    // by the control-disarm exception.
                    PowerEngine.shared.releaseAutomaticArm(owner: "homeServer",
                                                           reason: "component disabled")
                    Diagnostics.log("home server: component disabled; its automatic arm released")
                }
            }
        }
    }

    /// The documented automatic launch arm: component on, AC power, no orderly quit
    /// in progress, and the persisted one-hour rearm budget not exhausted.
    private func armHomeServerIfNeeded(reason: String) {
        let engine = PowerEngine.shared
        guard !terminating, !engine.isShuttingDown else { return }
        let enabled = ComponentEngine.shared.isEnabled("homeServer")
        let onCharger = !engine.onBattery()
        guard HomeServerPolicy.shouldArmAtLaunch(componentEnabled: enabled, onCharger: onCharger) else {
            if reason == "launch", enabled {
                Diagnostics.log("home server: not on AC power; no automatic arm at launch")
            }
            return
        }
        guard !engine.isArmed else {
            if reason == "launch" {
                Diagnostics.log("home server: relaunch found the session already armed (source \(engine.armSource))")
            }
            return
        }
        guard rearmBudget.canRearm(now: Date()) else {
            Diagnostics.log("home server: automatic rearm budget reached (\(HomeServerRearmBudget.maximumPerHour) per hour); leaving the session to you")
            return
        }
        if engine.requestAutomaticArm(owner: "homeServer", source: "home server",
                                      lifetime: .persistent) {
            if rearmBudget.recordRearm(now: Date()) { saveRearmBudget() }
            Diagnostics.log("home server: armed (\(reason)) on AC power")
        } else {
            Diagnostics.log("home server: arm refused (\(reason)); \(engine.lastEndReason ?? "no reason reported")")
        }
    }

    private static func loadRearmBudget() -> HomeServerRearmBudget {
        let stamps = UserDefaults.standard.array(forKey: rearmBudgetKey) as? [Double] ?? []
        return HomeServerRearmBudget(rearms: stamps.map { Date(timeIntervalSince1970: $0) })
    }

    private func saveRearmBudget() {
        UserDefaults.standard.set(rearmBudget.rearms.map(\.timeIntervalSince1970),
                                  forKey: Self.rearmBudgetKey)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handle(urls: urls)
    }

    private func handle(urls: [URL]) {
        if !urls.isEmpty {
            guideLaunchCommandReceived = true
            GuideCoordinator.shared.dismiss()
        }
        for url in urls {
            let command = (url.host ?? url.path.replacingOccurrences(of: "/", with: "")).lowercased()
            Diagnostics.log("url command: \(command)")
            switch command {
            case "arm":
                // URL arm selects mode 1 (persistent), unlike the menu's one-close arm.
                PowerEngine.shared.arm(source: "url", lifetime: .persistent)
            case "disarm":
                PowerEngine.shared.disarm(reason: "you")
            case "toggle":
                if PowerEngine.shared.isArmed {
                    PowerEngine.shared.disarm(reason: "you")
                } else {
                    PowerEngine.shared.arm(source: "url", lifetime: .persistent)
                }
            case "status":
                Diagnostics.log("status: \(PowerEngine.shared.statusLine)")
            case "removecomponent", LegacyVocabulary.removeCommand:
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let id = items.first(where: { $0.name == "id" })?.value {
                    ComponentStore.shared.remove(id)
                }
            case "importcomponent", LegacyVocabulary.importCommand:
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let path = items.first(where: { $0.name == "path" })?.value {
                    _ = ComponentStore.shared.importComponent(from: URL(fileURLWithPath: path))
                }
            case "testsound":
            let played = CloseSoundPlayer.shared.play(preview: true)
            Diagnostics.log("test sound requested: played=\(played)")
            return
        case "selftest":
                _ = ComponentEngine.shared.runSelfTest()
            case "set":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let component = Self.componentParameter(in: items) {
                    let on = (items.first(where: { $0.name == "on" })?.value ?? "1") != "0"
                    ComponentEngine.shared.setEnabled(component, on)
                    SettingsModel.shared.refresh()
                }
            case "settings":
                let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let tab = items.first(where: { $0.name == "tab" })?.value ?? "general"
                if let query = items.first(where: { $0.name == "q" })?.value {
                    SettingsModel.shared.query = query
                }
                if items.first(where: { $0.name == "make" })?.value == "1" {
                    SettingsModel.shared.showMakeYourOwnAtLaunch = true
                }
                if let componentID = Self.componentParameter(in: items),
                   let definition = ComponentCatalog.definition(for: componentID) {
                    SettingsModel.shared.selectedComponent = componentID
                    SettingsModel.shared.detailComponent = definition
                }
                openSettingsWindow(tab: Self.normalizedSettingsTab(tab))
            default:
                Diagnostics.log("unknown url command: \(command)")
            }
            menuBar?.rebuild()
            AppState.shared.refreshFromEngine()
        }
    }

    // MARK: - Menu actions

    @objc func armFromMenu() {
        PowerEngine.shared.arm(source: "you")
        menuBar?.rebuild()
    }

    @objc func disarmFromMenu() {
        PowerEngine.shared.disarm(reason: "you")
        menuBar?.rebuild()
    }

    @objc func openSettings() {
        openSettingsWindow(tab: "general")
    }

    /// Menu shortcut straight to the component grid, above Settings.
    @objc func openComponents() {
        openSettingsWindow(tab: "components")
    }

    /// The components tab was addressed as "components" before the rename. Links
    /// written against the old name still land on the same page; anything else
    /// is passed through unchanged so the window falls back to General itself.
    /// New links use `component=`. Links written before the rename used the
    /// retired spelling and still resolve to the same component.
    private static func componentParameter(in items: [URLQueryItem]) -> String? {
        items.first { $0.name == "component" }?.value
            ?? items.first { $0.name == LegacyVocabulary.urlComponentParameter }?.value
    }

    private static func normalizedSettingsTab(_ tab: String) -> String {
        switch tab.lowercased() {
        case "components", LegacyVocabulary.settingsTab: return "components"
        // The License tab is gone; links written against it land on About.
        case "license": return "about"
        default: return tab
        }
    }

    private func prepareSettingsController() {
        guard settingsController == nil else { return }
        settingsController = NSHostingController(rootView: SettingsView(initialTab: SettingsModel.shared.tab,
            openMakeYourOwn: SettingsModel.shared.showMakeYourOwnAtLaunch))
        guard let settingsController else { return }
        FluidOpen.shared.prepareSettings(content: settingsController,
                                         anchorProvider: { [weak self] in self?.menuBar?.anchorFrame })
    }

    func openSettingsWindow(tab: String, preservingGuide: Bool = false) {
        if !preservingGuide { GuideCoordinator.shared.dismiss() }
        SettingsModel.shared.tab = tab
        prepareSettingsController()
        guard let settingsController else { return }
        // Both views live in FluidOpen's one fixed, status-anchored window.
        FluidOpen.shared.showSettings(content: settingsController,
                                      anchorProvider: { [weak self] in self?.menuBar?.anchorFrame })
    }

    @objc func showAbout() {
        // About is a destination in the same retained glass surface. Opening a
        // second titled window used a different first-launch animation path.
        openSettingsWindow(tab: "about")
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

private struct AboutWindowView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text("Wakely").font(ClamType.display(19))
            Text("Version \(AppVersion.current)").font(ClamType.body(12)).foregroundStyle(.secondary)
            Text("Open source. No license, no trial.")
                .font(ClamType.body(13))
                .foregroundStyle(.secondary)
        }
        .environment(\.font, ClamType.body(13))
        .padding(28)
        .frame(width: 300)
    }
}
