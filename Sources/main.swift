// Wakely — menu-bar control for when your Mac stays awake.
//
// Entry point. Accessory (menu bar only) app, no dock icon, no windows until asked.

import AppKit
import SwiftUI
import ApplicationServices

// One-time vocabulary migration. It runs before any engine reads a preference
// or component store touches the support directory.
LegacyVocabulary.migratePreferences()
LegacyVocabulary.migrateStorage(in: SupportPaths.baseDirectory)

// Install the per-user watchdog without SMAppService (ad-hoc builds).
if CommandLine.arguments.contains("--install-agent") {
    let ok = ManualAgentInstaller.installIfNeeded()
    print("agent_installed: \(ok)")
    print("agent_loaded: \(ManualAgentInstaller.isLoaded())")
    print("watchdog: \(ManualAgentInstaller.installedWatchdogURL().path)")
    exit(0)
}

// Read-only watchdog state.
if CommandLine.arguments.contains("--agent-status") {
    print("agent_loaded: \(ManualAgentInstaller.isLoaded())")
    print("plist: \(ManualAgentInstaller.launchAgentURL().path)")
    exit(0)
}

// Print the exact ad-hoc identity the administrator installer will pin.
if CommandLine.arguments.contains("--print-helper-identity") {
    let app = Bundle.main.executableURL ?? Bundle.main.bundleURL
    let watchdog = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WakelyWatchdog")
    print("app=\(HelperCodeIdentity.cdhash(for: app) ?? "nil")")
    print("watchdog=\(HelperCodeIdentity.cdhash(for: watchdog) ?? "nil")")
    print("team=\(HelperCodeIdentity.hasTeamIdentifier() ? "present" : "none")")
    exit(0)
}

// Install the root LaunchDaemon through one administrator prompt. This path
// does not use SMAppService or require an Apple Developer ID.
if CommandLine.arguments.contains("--install-helper-admin") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let client = HelperClient.shared
            let result = await client.installWithAdministratorPrompt()
            print("install: \(result)")
            client.refreshInstallState()
            print("state: \(client.installState)")
            print("reachable: \(await client.isReachable())")
            exit(0)
        }
        RunLoop.main.run()
    }
    exit(0)
}

// End-to-end helper QA for Sleep Means Sleep. Applies the supported battery
// wake-source lease and immediately restores it; no component toggle or
// preference is changed. Refuses if this helper/model cannot do the operation.
if CommandLine.arguments.contains("--test-wake-source-suppression") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let api = HelperComponentAPI()
            let capability = await HelperClient.shared.capability(.suppressWakeSources)
            print("capability: supported=\(capability.supported) reason=\(capability.reason)")
            guard capability.supported else { exit(2) }
            let applied = await api.suppressWakeSources()
            print("apply: ok=\(applied.reply.ok) message=\(applied.reply.message)")
            let restored = await api.restore(component: "sleepMeansSleep")
            print("restore: ok=\(restored.reply.ok) message=\(restored.reply.message)")
            exit(applied.reply.ok && restored.reply.ok ? 0 : 1)
        }
        RunLoop.main.run()
    }
    exit(1)
}

// Read-only helper status: ping, status, and wake ownership. No mutation.
if CommandLine.arguments.contains("--helper-status") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let client = HelperClient.shared
            client.refreshInstallState()
            print("state: \(client.installState)")
            print("reachable: \(await client.isReachable())")
            for operation in HelperOperation.allCases where operation != .ping {
                let capability = await client.capability(operation)
                print("\(operation.rawValue): supported=\(capability.supported) reason=\(capability.reason)")
            }
            exit(0)
        }
        RunLoop.main.run()
    }
    exit(0)
}

// Helper maintenance diagnostics. These only use SMAppService unregister/
// register; they never run a shell as root or modify /Library directly.
if CommandLine.arguments.contains("--reinstall-helper") {
    MainActor.assumeIsolated {
        Task { @MainActor in
            let client = HelperClient.shared
            await client.uninstall()
            client.refreshInstallState()
            print("after uninstall: \(client.installState)")
            let result = await client.install()
            print("install: \(result)")
            client.refreshInstallState()
            print("after install: \(client.installState)")
            print("reachable: \(await client.isReachable())")
            exit(0)
        }
        RunLoop.main.run()
    }
    exit(0)
}

// Safe input-tap check: listens only, never consumes or blocks an event, and
// disables immediately. Proves the Accessibility/event-tap path without locking
// the keyboard or touching any component state.
if CommandLine.arguments.contains("--test-input-tap") {
    MainActor.assumeIsolated {
        guard AXIsProcessTrusted() else {
            print("Input tap unavailable: Wakely does not have Accessibility access.")
            exit(2)
        }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                                          userInfo: nil) else {
            print("Input tap creation was refused by macOS.")
            exit(1)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        defer { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        guard CGEvent.tapIsEnabled(tap: tap) else {
            print("Input tap did not become active.")
            exit(1)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        print("PASS: Accessibility input-tap creation and activation work; listen-only, no input was blocked.")
    }
    exit(0)
}

// Read-only capability report: no component is toggled, no permission is
// requested, and no hardware action is attempted. Prints the real table.
if CommandLine.arguments.contains("--self-test") {
    MainActor.assumeIsolated {
        print(ComponentEngine.shared.runSelfTest())
    }
    exit(0)
}

// Offscreen design QA: no app delegate, power assertions, or foreground window.
if let index = CommandLine.arguments.firstIndex(of: "--render-ui-preview"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppAppearance.shared.apply()
        _ = ClamType.registerBundledFonts()
        SettingsModel.shared.showOnOnly = CommandLine.arguments.contains("--on-only")
        let width: CGFloat = CommandLine.arguments.contains("--compact") ? 860 : 1040
        let size = NSSize(width: width, height: 760)
        let requestedTab = CommandLine.arguments
            .first { $0.hasPrefix("--tab=") }
            .map { String($0.dropFirst("--tab=".count)) } ?? "components"
        let view = NSHostingView(rootView: SettingsView(initialTab: CommandLine.arguments.contains("--exercise-navigation") ? "general" : requestedTab))
        if CommandLine.arguments.contains("--screen-prompt") {
            let promptID = CommandLine.arguments
                .first { $0.hasPrefix("--prompt-screen=") }
                .flatMap { UUID(uuidString: String($0.dropFirst("--prompt-screen=".count))) }
            SettingsModel.shared.beginScreenPrompt(promptID)
        }
        if CommandLine.arguments.contains("--screen-editor") {
            let editID = CommandLine.arguments
                .first { $0.hasPrefix("--edit-screen=") }
                .flatMap { UUID(uuidString: String($0.dropFirst("--edit-screen=".count))) }
            SettingsModel.shared.beginScreenEditor(editID)
        }
        // Optional component sheet, so a component's options can be rendered and
        // checked headlessly.
        if let componentID = CommandLine.arguments
            .first(where: { $0.hasPrefix("--component=") })
            .map({ String($0.dropFirst("--component=".count)) }),
           let definition = ComponentCatalog.definition(for: componentID) {
            SettingsModel.shared.detailComponent = definition
            SettingsModel.shared.selectedComponent = definition.id
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let wait = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-wait=") })
            .flatMap { Double($0.dropFirst("--ui-wait=".count)) } ?? 0.25
        RunLoop.main.run(until: Date().addingTimeInterval(max(0.1, min(15, wait))))
        if CommandLine.arguments.contains("--exercise-navigation") {
            SettingsModel.shared.tab = "components"
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            for onOnly in [true, false, true, false] {
                withAnimation(.easeInOut(duration: 0.2)) { SettingsModel.shared.showOnOnly = onOnly }
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                view.layoutSubtreeIfNeeded()
            }
            print("PASS: General → Components and repeated All/On filter transitions")
        }
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                    print("Rendered component UI \(Int(width))×760 without opening a window")
                } catch { fputs("Preview write failed: \(error)\n", stderr); exit(1) }
            } else { exit(1) }
        } else { exit(1) }
    }
    exit(0)
}

// Offscreen permission onboarding QA: renders the real window for every
// permission category without prompting, opening Settings, or registering the
// helper. This is the install-journey screenshot fixture.
if let index = CommandLine.arguments.firstIndex(of: "--render-permission-preview"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppAppearance.shared.apply()
        let base = CommandLine.arguments[index + 1]
        let explicitComponent = CommandLine.arguments
            .first { $0.hasPrefix("--component=") }
            .map { String($0.dropFirst("--component=".count)) }
        for permission in ComponentPermission.allCases {
            // Use a representative component when none was supplied, so the
            // preview does not claim Cleaning Lock needs the helper or Location.
            let componentID = explicitComponent ?? {
                switch permission {
                case .accessibility: return "cleaningLock"
                case .location: return "armOnWiFi"
                case .notifications: return "agentNotifications"
                case .helper: return "passwordAfterClose"
                }
            }()
            let view = ComponentPermissions.previewView(componentID: componentID, permission: permission)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            let path = "\(base)-\(permission.rawValue).png"
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch { fputs("permission preview write failed: \(error)\n", stderr); exit(1) }
        }
        print("Rendered permission onboarding previews")
    }
    exit(0)
}

// Offscreen frame-by-frame check of the card morph surface. Renders the same
// component at several progress values so corners, stroke, clipping and text
// can be inspected without racing a live animation.
if let index = CommandLine.arguments.firstIndex(of: "--render-morph-frames"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppAppearance.shared.apply()
        let base = CommandLine.arguments[index + 1]
        let componentID = CommandLine.arguments
            .first { $0.hasPrefix("--component=") }
            .map { String($0.dropFirst("--component=".count)) } ?? "agentScreen"
        guard let component = ComponentCatalog.definition(for: componentID) else {
            fputs("No such component: \(componentID)\n", stderr); exit(1)
        }
        let size = CGSize(width: 1040, height: 760)
        let canvas = CGSize(width: size.width, height: size.height)
        // The first grid cell, measured from the 1040x760 render: the overlay
        // must sit exactly over the real card for a truthful frame.
        let source = CGRect(x: 28, y: 135, width: 322, height: 182)
        let destination = CGRect(x: 28, y: 74, width: 984, height: 112)
        let geometry = CardMorphGeometry(source: source, destination: destination,
                                         direction: .opening)
        for step in 0...10 {
            let progress = Double(step) / 10
            let elapsed = progress * geometry.duration
            let root = ZStack(alignment: .topLeading) {
                SettingsView(initialTab: "components")
                    .frame(width: size.width, height: size.height)
                Color.black.opacity(0.42 * geometry.opacity(for: .dim, at: elapsed))
                CardMorphOverlay(component: component,
                                 isOn: true,
                                 canvas: canvas,
                                 source: source,
                                 destination: destination,
                                 direction: .opening,
                                 progress: progress,
                                 dimsCatalog: false)
            }
            .frame(width: size.width, height: size.height)
            let view = NSHostingView(rootView: root)
            view.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            let path = "\(base)-\(String(format: "%03d", Int(progress * 100))).png"
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch { fputs("morph frame write failed: \(error)\n", stderr); exit(1) }
        }
        print("Rendered 11 morph frames for \(component.name)")
    }
    exit(0)
}


// Safe guide preview setup. This route mutates tutorial navigation only and
// explicitly disables tutorial preference writes; no component is enabled.
@MainActor
func configureGuidePreview() {
    let args = CommandLine.arguments
    if let raw = args.first(where: { $0.hasPrefix("--onboarding-preview=") }),
       let step = Int(raw.dropFirst("--onboarding-preview=".count)) {
        GuideCoordinator.shared.previewOnboarding(step: step)
    }
    let beat = args.first(where: { $0.hasPrefix("--guide-beat=") })
        .flatMap { Int($0.dropFirst("--guide-beat=".count)) }
    GuideCoordinator.shared.configurePreview(beat: beat,
        reduceMotion: args.contains("--guide-reduced-motion"))
}

// Local, offscreen layout QA for small guide sizes. No screen capture, app
// delegate, power engine start, permission prompt, or foreground activation.
if let index = CommandLine.arguments.firstIndex(of: "--render-guide-preview"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.prohibited)
        AppAppearance.shared.apply()
        _ = ClamType.registerBundledFonts()
        configureGuidePreview()
        guard GuideCoordinator.shared.isPresented else { exit(1) }
        SettingsModel.shared.panelPresented = true
        let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--guide-size=") })
            .map { String($0.dropFirst("--guide-size=".count)) } ?? "760x560"
        let dimensions = raw.split(separator: "x").compactMap { Double($0) }
        guard dimensions.count == 2, dimensions.allSatisfy({ $0.isFinite && $0 >= 400 && $0 <= 1600 }) else { exit(1) }
        let size = CGSize(width: dimensions[0], height: dimensions[1])
        let defaultsBefore = UserDefaults.standard.persistentDomain(forName: "dev.wakely.app") ?? [:]
        var tourLayout: HighlightTourLayoutProbe.Sample?
        HighlightTourLayoutProbe.observe = { tourLayout = $0 }
        let previewScheme: ColorScheme? = CommandLine.arguments.contains("--guide-light") ? .light
            : (CommandLine.arguments.contains("--guide-dark") ? .dark : AppAppearance.shared.preferredColorScheme)
        let view = NSHostingView(rootView: GuideDestinationView()
            .background(Theme.window)
            .environment(\.font, ClamType.body(13))
            .preferredColorScheme(previewScheme)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        if CommandLine.arguments.contains("--tour-show-form") {
            HighlightTourNavigation.shared.previewCreation()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        if CommandLine.arguments.contains("--verify-tour-layout") {
            guard let sample = tourLayout, sample.target != nil,
                  sample.viewport.insetBy(dx: -1, dy: -1).contains(sample.coach) else {
                fputs("FAIL: missing spotlight or off-window coach for step \(GuideCoordinator.shared.progress.step)\n", stderr)
                exit(1)
            }
            let defaultsAfter = UserDefaults.standard.persistentDomain(forName: "dev.wakely.app") ?? [:]
            guard NSDictionary(dictionary: defaultsBefore).isEqual(to: defaultsAfter) else {
                fputs("FAIL: preview changed saved settings\n", stderr); exit(1)
            }
            print("PASS: measured spotlight, coach inside viewport, no saved settings changed")
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) }
        catch { fputs("guide preview write failed: \(error)\n", stderr); exit(1) }
        print("Rendered read-only guide preview")
        if CommandLine.arguments.contains("--verify-tour-flow") {
            let guide = GuideCoordinator.shared
            let model = SettingsModel.shared
            guide.dismiss()
            model.tab = "general"
            model.query = "preserved tour test query"
            model.showOnOnly = true
            guide.previewOnboarding(step: 1)
            precondition(model.tab == "components" && model.query == "Agent Light" && !model.showOnOnly)
            guide.next()
            precondition(model.detailComponent?.id == HighlightTourStep.demonstrationComponentID)
            guide.next()
            guide.demoMinutes = 90
            guide.go(to: 5)
            HighlightTourNavigation.shared.previewCreation()
            precondition(model.showMakeYourOwn && guide.creationPreviewOpened)
            guide.go(to: 6)
            precondition(!model.showMakeYourOwn)
            HighlightTourNavigation.shared.previewCreation()
            precondition(model.showScreenPrompt && guide.creationPreviewOpened)
            guide.dismiss()
            precondition(model.tab == "general" && model.query == "preserved tour test query" && model.showOnOnly)
            precondition(!model.anyModalPresented)
            let after = UserDefaults.standard.persistentDomain(forName: "dev.wakely.app") ?? [:]
            precondition(NSDictionary(dictionary: defaultsBefore).isEqual(to: after))
            print("PASS: real detail/creation navigation, local practice value, skip restoration and unchanged preferences")
        }
        window.close()
    }
    exit(0)
}

// Isolated visual QA for the real borderless goo panel. No AppDelegate,
// component engine, helper, or system setting is started. The panel is shown
// briefly so ScreenCaptureKit can include its native material.
if let index = CommandLine.arguments.firstIndex(of: "--render-panel-preview"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        AppAppearance.shared.apply()
        // The preview must exercise the same bundled display face as the app.
        _ = ClamType.registerBundledFonts()
        if ProcessInfo.processInfo.environment["WAKELY_FONT_DIAGNOSTICS"] == "1" {
            print("fonts: \(ClamType.resolvedFontSummary())")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Arm Wakely", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let keep = NSMenuItem(title: "Keep Awake With Lid Open", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Indefinitely", action: nil, keyEquivalent: ""))
        submenu.addItem(NSMenuItem(title: "1 hour", action: nil, keyEquivalent: ""))
        keep.submenu = submenu
        menu.addItem(keep)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit Wakely", action: nil, keyEquivalent: "q"))
        guard let screen = NSScreen.main else { exit(1) }
        let previewBackdrop: String? = ProcessInfo.processInfo.environment["WAKELY_PREVIEW_BACKDROP"]
        let backdropWindow: NSWindow?
        if let tone = previewBackdrop {
            let color: NSColor = tone == "white" ? .white
                : (tone == "gray" ? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1) : .black)
            let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            backdrop.backgroundColor = color
            backdrop.isOpaque = true
            backdrop.ignoresMouseEvents = true
            backdrop.level = .normal
            backdrop.orderFront(nil)
            backdropWindow = backdrop
        } else {
            backdropWindow = nil
        }
        _ = backdropWindow
        let anchor = NSRect(x: screen.frame.midX, y: screen.visibleFrame.maxY - 24,
                            width: 24, height: 24)
        FluidOpen.shared.configure(menu: menu, anchorProvider: { anchor }, perform: { _ in })
        if CommandLine.arguments.contains("--settings") {
            if let componentID = CommandLine.arguments
                .first(where: { $0.hasPrefix("--component=") })
                .map({ String($0.dropFirst("--component=".count)) }),
               let definition = ComponentCatalog.definition(for: componentID) {
                SettingsModel.shared.selectedComponent = definition.id
                SettingsModel.shared.detailComponent = definition
            }
            let tab = CommandLine.arguments.first(where: { $0.hasPrefix("--tab=") })
                .map { String($0.dropFirst("--tab=".count)) } ?? "components"
            if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("--setup-preview=") })
                .map({ String($0.dropFirst("--setup-preview=".count)) }),
               let definition = ComponentCatalog.definition(for: raw) {
                let permission = ComponentPermissionPolicy.requirements(for: definition.id)
                    .first?.permission ?? .accessibility
                ComponentPermissions.shared.previewInPanel(componentID: definition.id,
                                                           permission: permission)
            }
            configureGuidePreview()
            let controller = NSHostingController(rootView: SettingsView(initialTab: tab))
            FluidOpen.shared.showSettings(content: controller, anchorProvider: { anchor })
        } else {
            FluidOpen.shared.toggleMenu()
        }
        let panelWait = CommandLine.arguments.first(where: { $0.hasPrefix("--ui-wait=") })
            .flatMap { Double($0.dropFirst("--ui-wait=".count)) } ?? 1.0
        RunLoop.main.run(until: Date().addingTimeInterval(max(0.2, min(15, panelWait))))
        guard let window = FluidOpen.shared.debugPanelWindow, window.windowNumber > 0 else {
            fputs("panel preview window missing\n", stderr)
            exit(1)
        }
        if CommandLine.arguments.contains("--exercise-status-toggle") {
            for _ in 0..<3 {
                FluidOpen.shared.toggleMenu()
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                precondition(!window.isVisible, "Close must complete without a retained nub window")
                FluidOpen.shared.toggleMenu()
                RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                precondition(window.isVisible, "Reopen must retain the panel")
            }
            for _ in 0..<4 {
                FluidOpen.shared.toggleMenu()
                RunLoop.main.run(until: Date().addingTimeInterval(0.055))
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            precondition(window.isVisible, "Rapid close/reopen must settle at the final command")
            print("PASS: repeated status open/close and rapid reversal")
        }
        if CommandLine.arguments.contains("--submenu-back-hover") {
            func menuView(in view: NSView) -> GooMenuView? {
                if let menu = view as? GooMenuView { return menu }
                return view.subviews.lazy.compactMap { menuView(in: $0) }.first
            }
            func buttons(in view: NSView) -> [NSButton] {
                (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
            }
            guard let menuView = window.contentView.flatMap({ menuView(in: $0) }),
                  let keepButton = buttons(in: menuView).first(where: { $0.title == keep.title }) else { exit(1) }
            keepButton.performClick(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            guard let back = buttons(in: menuView).first(where: { $0.title.contains("Back") && !$0.isHidden }) else { exit(1) }
            menuView.updatePointer(at: back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil),
                                   pointerEvent: true)
            precondition(menuView.debugHighlightedTitles == [back.title], "Back must hover during submenu arrival")
            menuView.displayIfNeeded()
            back.displayIfNeeded()
            print("PASS: real-panel Back hover (immediate arrival covered by behavior test)")
        }
        let path = CommandLine.arguments[index + 1]
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        if previewBackdrop != nil {
            let frame = window.frame
            let region = CGRect(x: frame.minX,
                                y: screen.frame.maxY - frame.maxY,
                                width: frame.width, height: frame.height)
            capture.arguments = ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path]
        } else {
            capture.arguments = ["-x", "-l", String(window.windowNumber), path]
        }
        do {
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0,
                  FileManager.default.fileExists(atPath: path) else { exit(1) }
            print("Rendered goo panel preview \(window.windowNumber) to \(path)")
        } catch {
            fputs("panel preview capture failed: \(error)\n", stderr)
            exit(1)
        }
    }
    exit(0)
}

// Headless diagnostic uses the actual app bundle and playback implementation,
// not a separate decoder test. It does not arm, open windows, or alter volume.
if CommandLine.arguments.contains("--test-close-sound") {
    let result = MainActor.assumeIsolated { () -> (Bool, TimeInterval) in
        let played = CloseSoundPlayer.shared.play(preview: true)
        print("bundle=\(Bundle.main.bundleURL.path)")
        print("audioPlaybackStarted=\(played) outputMuted=\(Audio.isMuted())")
        return (played, CloseSoundPlayer.shared.playbackRemaining)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(result.1 + 0.25))
    exit(result.0 ? 0 : 1)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
