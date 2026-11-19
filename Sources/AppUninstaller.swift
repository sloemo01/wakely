import AppKit
import ServiceManagement

/// Removes Wakely completely: helper, watchdog, login items, macOS privacy
/// grants, settings and data, then moves the app to the Trash and quits.
@MainActor
enum AppUninstaller {
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.wakely.app"

    static func deleteEverything() async {
        Diagnostics.log("delete wakely: started")
        PowerEngine.shared.disarm()

        // The privileged helper restores any protected setting it owns before
        // it goes; the administrator path also removes a fallback-installed daemon.
        await HelperClient.shared.uninstall()
        _ = await HelperClient.shared.uninstallWithAdministratorPrompt()

        try? await SMAppService.agent(plistName: HelperService.agentPlistName).unregister()
        try? await SMAppService.mainApp.unregister()
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(HelperService.agentLabel)"])
        try? FileManager.default.removeItem(at: ManualAgentInstaller.launchAgentURL())

        // Accessibility, Location, Automation and every other TCC grant.
        run("/usr/bin/tccutil", ["reset", "All", bundleID])

        try? FileManager.default.removeItem(at: ManualAgentInstaller.supportDirectory())
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        for path in ["Caches/\(bundleID)", "HTTPStorages/\(bundleID)", "Saved Application State/\(bundleID).savedState"] {
            try? FileManager.default.removeItem(at: library.appendingPathComponent(path))
        }
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()

        let app = Bundle.main.bundleURL
        do {
            try FileManager.default.trashItem(at: app, resultingItemURL: nil)
        } catch {
            NSWorkspace.shared.recycle([app]) { _, _ in }
        }
        NSApp.terminate(nil)
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
