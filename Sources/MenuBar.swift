// MenuBar — the mark in the menu bar, and the menu under it.

import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var refreshTimer: Timer?
    private var enablementObservation: AnyCancellable?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        // The mark opens our compact state of the SAME goo window, not a
        // native NSMenu window. Keep NSMenu as the action model/test seam.
        statusItem.menu = nil
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        rebuild()
        FluidOpen.shared.configure(menu: menu, anchorProvider: { [weak self] in self?.anchorFrame },
                                   perform: { [weak self] item in self?.perform(item) })
        // Rebuild when enablement changes, rather than waiting for the status
        // timer. Tour anchors/copy must follow the same real menu immediately.
        enablementObservation = SettingsModel.shared.$enabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIcon() }
        }
        if let refreshTimer { RunLoop.main.add(refreshTimer, forMode: .common) }
    }

    func menuWillOpen(_ menu: NSMenu) { rebuild() }

    @objc private func togglePanel() {
        // A close/reversal click must retarget immediately, not recreate and
        // lay out the menu before the spring can move.
        if FluidOpen.shared.needsMenuRefreshBeforeOpening {
            (NSApp.delegate as? AppDelegate)?.openFirstRunGuideForMenuInteraction()
            if FluidOpen.shared.needsMenuRefreshBeforeOpening { rebuild() }
        }
        if !GuideCoordinator.shared.isPresented { FluidOpen.shared.toggleMenu() }
    }

    private func perform(_ item: NSMenuItem) {
        guard !GuideCoordinator.shared.isPresented, let action = item.action else { return }
        if action == #selector(AppDelegate.openSettings) {
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow(tab: "general")
        } else if action == #selector(AppDelegate.showAbout) {
            (NSApp.delegate as? AppDelegate)?.openSettingsWindow(tab: "about")
        } else {
            if action == #selector(activateAgent(_:)) || action == #selector(lockForCleaning)
                || action == #selector(AppDelegate.quit) {
                FluidOpen.shared.dismiss()
            }
            NSApp.sendAction(action, to: item.target, from: item)
            rebuild()
        }
    }

    /// Test seam: read-only access to the constructed menu.
    var debugMenu: NSMenu? { menu }

    /// Where the mark sits on screen, for anything that wants to grow out of it.
    var anchorFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func refreshIcon() {
        statusItem.button?.image = statusImage(armed: PowerEngine.shared.isArmed)
        FluidOpen.shared.statusItemDidLayout()
        if FluidOpen.shared.acceptsLiveMenuRefresh { rebuild() }
    }

    // MARK: - Drawing

    /// Armed by Caps Lock shows green, keep-awake shows dark green, and plain
    /// armed shows yellow. These colours now paint the icon outline.
    private func stateColor() -> NSColor? {
        let engine = PowerEngine.shared
        if ComponentEngine.shared.isEnabled("agentLight") {
            if AgentMonitor.shared.waitingCount > 0 { return .systemOrange }
            if AgentMonitor.shared.workingCount > 0 { return .systemGreen }
            // After the last agent finishes the light keeps showing "done" for
            // the window chosen in the component's options.
            if let finishedAt = AgentMonitor.shared.lastFinishedAt {
                let minutes = UserDefaults.standard.object(forKey: "agentLight.minutes") as? Int ?? 60
                if Date().timeIntervalSince(finishedAt) < Double(max(1, minutes)) * 60 {
                    return NSColor.systemGreen.blended(withFraction: 0.45, of: .black)
                }
            }
        }
        if ComponentEngine.shared.isKeepingAwake { return NSColor.systemGreen.blended(withFraction: 0.35, of: .black) }
        guard engine.isArmed else { return nil }
        if ComponentEngine.shared.isEnabled("capsLock"), CapsLockLight.isLit { return .systemGreen }
        return .systemYellow
    }

    /// The status-bar-only mark: white-only while unarmed/inactive, with a
    /// coloured outline and white interior while armed or doing something.
    private func statusImage(armed: Bool) -> NSImage {
        BrandIcon.statusImage(color: stateColor())
    }

    // MARK: - Menu

    func rebuild() {
        let engine = PowerEngine.shared
        let armed = engine.isArmed

        statusItem.button?.image = statusImage(armed: armed)
        statusItem.button?.toolTip = nil

        menu.removeAllItems()

        if armed {
            let header = NSMenuItem(title: engine.statusLine, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            if let since = engine.armedAt {
                let held = NSMenuItem(title: "Awake for \(shortDuration(from: since))", action: nil, keyEquivalent: "")
                held.isEnabled = false
                menu.addItem(held)
            }
            if ComponentEngine.shared.isEnabled("capsLock"), CapsLockLight.isLit {
                let caps = NSMenuItem(title: "Caps Lock is the switch", action: nil, keyEquivalent: "")
                caps.isEnabled = false
                menu.addItem(caps)
            }
            if let owner = PowerEngine.shared.activeComponentOwner,
               let name = ComponentCatalog.definition(for: owner)?.name {
                let row = NSMenuItem(title: "Held by \(name)", action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
            }
            menu.addItem(.separator())
            menu.addItem(item("Unarm", #selector(AppDelegate.disarmFromMenu)))
        } else {
            menu.addItem(item("Arm Wakely", #selector(AppDelegate.armFromMenu)))
        }

        if ComponentEngine.shared.isEnabled("agentStatus") {
            let agents = AgentMonitor.shared
            if agents.threads.isEmpty {
                menu.addItem(.separator())
                let idle = NSMenuItem(title: "No agents running", action: nil, keyEquivalent: "")
                idle.isEnabled = false
                menu.addItem(idle)
            } else {
                menu.addItem(.separator())
                let label = Self.agentSummaryTitle(working: agents.workingCount,
                                                   waiting: agents.waitingCount,
                                                   total: agents.threads.count)
                let row = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                row.isEnabled = false
                menu.addItem(row)
                for thread in agents.threads {
                    // Identity is the registry/derived display name. The row
                    // never shows commands, cwd, prompts, or transcript text.
                    let entry = NSMenuItem(title: Self.agentRowTitle(for: thread), action: #selector(activateAgent(_:)), keyEquivalent: "")
                    entry.target = self
                    entry.representedObject = NSNumber(value: thread.pid)
                    menu.addItem(entry)
                }
            }
        }

        if ComponentEngine.shared.isEnabled("keepAwake") {
            menu.addItem(.separator())
            if ComponentEngine.shared.isKeepingAwake {
                let stop = NSMenuItem(title: "Stop Keep Awake", action: #selector(stopKeepAwake), keyEquivalent: "")
                stop.target = self
                menu.addItem(stop)
            }
            let lengths = NSMenu()
            let selection = ComponentEngine.shared.keepAwakeSnapshot
            if let status = KeepAwakeMenuPresentation.statusText(snapshot: selection) {
                let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                lengths.addItem(statusItem)
                lengths.addItem(.separator())
            }
            for (title, minutes) in KeepAwakeMenuPresentation.choices {
                let choice = NSMenuItem(title: title, action: #selector(startKeepAwake(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = NSNumber(value: minutes)
                if KeepAwakeMenuPresentation.isChecked(minutes: minutes, snapshot: selection) {
                    choice.state = .on
                }
                lengths.addItem(choice)
            }
            let keep = NSMenuItem(title: "Keep Awake With Lid Open", action: nil, keyEquivalent: "")
            keep.submenu = lengths
            menu.addItem(keep)
        }
        if ComponentEngine.shared.isEnabled("cleaningLock") {
            let clean = NSMenuItem(title: "Lock for Cleaning…", action: #selector(lockForCleaning), keyEquivalent: "")
            clean.target = self
            menu.addItem(clean)
        }
        menu.addItem(.separator())
        menu.addItem(item("Components", #selector(AppDelegate.openComponents)))
        menu.addItem(item("Settings…", #selector(AppDelegate.openSettings), key: ","))
        menu.addItem(item("About Wakely", #selector(AppDelegate.showAbout)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Wakely", #selector(AppDelegate.quit), key: "q"))
        // Stable presentation identities survive a full live-model rebuild.
        for entry in menu.items {
            switch entry.action {
            case #selector(AppDelegate.armFromMenu), #selector(AppDelegate.disarmFromMenu): entry.identifier = .init("tour.arm")
            case #selector(AppDelegate.openComponents): entry.identifier = .init("tour.components")
            case #selector(AppDelegate.openSettings): entry.identifier = .init("tour.settings")
            case #selector(AppDelegate.showAbout): entry.identifier = .init("tour.about")
            case #selector(AppDelegate.quit): entry.identifier = .init("tour.quit")
            default: break
            }
            if let submenu = entry.submenu {
                entry.identifier = .init("tour.keepAwake")
                for choice in submenu.items where choice.action == #selector(startKeepAwake(_:)) {
                    choice.identifier = .init("tour.duration.\((choice.representedObject as? NSNumber)?.intValue ?? 0)")
                }
            }
        }
        FluidOpen.shared.updateMenu(menu)
        GuideCoordinator.shared.updateMenuKeepAwakeAvailability(menu.items.contains {
            $0.identifier?.rawValue == "tour.keepAwake" && $0.submenu != nil
        })
    }

    /// Pure label seam: callers/tests can verify the fallback without a live
    /// agent. An empty or missing display name falls back to the provider.
    static func agentSummaryTitle(working: Int, waiting: Int, total: Int) -> String {
        if working > 0 {
            return "\(working) working\(waiting > 0 ? ", \(waiting) waiting on you" : "")"
        }
        if waiting > 0 { return "\(waiting) waiting on you" }
        return total == 1 ? "1 agent running" : "\(total) agents running"
    }

    static func agentRowTitle(for thread: AgentThread) -> String {
        let trimmed = thread.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmed?.isEmpty == false ? trimmed! : thread.provider)
        return "\(name) — \(thread.state.rawValue)"
    }

    @objc private func activateAgent(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? NSNumber else { return }
        if let application = NSRunningApplication(processIdentifier: pid.int32Value), application.activationPolicy == .regular {
            application.activate(options: [])
        } else {
            let processID = pid.int32Value
            Task {
                let ancestors = await Task.detached { Self.parentProcessIDs(of: processID) }.value
                for ancestor in ancestors {
                    if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular {
                        app.activate(options: [])
                        return
                    }
                }
                NSSound.beep()
            }
        }
    }

    nonisolated private static func parentProcessIDs(of pid: Int32) -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid="]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        var parents: [Int32: Int32] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count == 2, let child = Int32(parts[0]), let parent = Int32(parts[1]) { parents[child] = parent }
        }
        var result: [Int32] = []
        var current = pid
        while let parent = parents[current], parent > 1, !result.contains(parent), result.count < 32 {
            result.append(parent)
            current = parent
        }
        return result
    }

    @objc private func startKeepAwake(_ sender: NSMenuItem) {
        let minutes = (sender.representedObject as? NSNumber)?.intValue ?? 0
        ComponentEngine.shared.startKeepAwake(minutes: minutes == 0 ? nil : minutes, source: .menu)
        rebuild()
    }
    @objc private func stopKeepAwake() { ComponentEngine.shared.stopKeepAwake(); rebuild() }
    @objc private func lockForCleaning() { ComponentEngine.shared.beginCleaningLock() }

    private func item(_ title: String, _ action: Selector?, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = NSApp.delegate
        return entry
    }

    private func shortDuration(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \((seconds % 3600) / 60) min"
    }
}
