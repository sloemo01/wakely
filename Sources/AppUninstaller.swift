import AppKit
import ServiceManagement

/// Removes Wakely completely: helper, watchdog, login items, macOS privacy
/// grants, settings and data, then moves the app to the Trash and quits.
@MainActor
enum AppUninstaller {
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.wakely.app"

    static func deleteEverything() async {
        Diagnostics.log("delete wakely: started")
        // The same drain as a normal quit, while the helper is still here to
        // put back every system setting Wakely changed.
        AgentMonitor.shared.stop()
        ComponentRuntime.shared.stop()
        ComponentEngine.shared.stop()
        PowerEngine.shared.shutDown()
        _ = await ComponentEngine.shared.awaitShutdownRestoration(timeout: 8)
        _ = await PowerEngine.shared.awaitShutdownCleanup(timeout: 3)
        AppLiveness.clear()

        // The administrator path also removes a fallback-installed daemon and
        // the helper's root-owned data.
        await HelperClient.shared.uninstall()
        _ = await HelperClient.shared.uninstallWithAdministratorPrompt(removeData: true)

        try? await SMAppService.agent(plistName: HelperService.agentPlistName).unregister()
        try? await SMAppService.mainApp.unregister()
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(HelperService.agentLabel)"])
        try? FileManager.default.removeItem(at: ManualAgentInstaller.launchAgentURL())

        // Accessibility, Location, Automation and every other TCC grant.
        run("/usr/bin/tccutil", ["reset", "All", bundleID])

        try? FileManager.default.removeItem(at: ManualAgentInstaller.supportDirectory())
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for path in ["Caches/\(bundleID)", "Caches/Wakely", "HTTPStorages/\(bundleID)", "Saved Application State/\(bundleID).savedState"] {
            try? FileManager.default.removeItem(at: library.appendingPathComponent(path))
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        run("/usr/bin/defaults", ["delete", bundleID])
        try? FileManager.default.removeItem(at: library.appendingPathComponent("Preferences/\(bundleID).plist"))

        let app = Bundle.main.bundleURL
        do {
            try FileManager.default.trashItem(at: app, resultingItemURL: nil)
        } catch {
            NSWorkspace.shared.recycle([app]) { _, _ in }
        }
        // Cleanup already ran; a normal quit would redo it and write settings
        // back, so leave right away.
        Diagnostics.log("delete wakely: finished")
        try? FileManager.default.removeItem(at: ManualAgentInstaller.supportDirectory())
        exit(0)
    }

    @discardableResult
    private static func run(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus } catch { return -1 }
    }
}
