import AppKit
import ServiceManagement

/// Removes Wakely completely: helper, watchdog, login items, macOS privacy
/// grants, settings and data, then moves the app to the Trash and quits.
@MainActor
enum AppUninstaller {
    static let bundleID = Bundle.main.bundleIdentifier ?? "dev.wakely.app"

    /// Returns why nothing (or not everything) was deleted, or never returns:
    /// on success Wakely quits. It stops before removing the helper and its
    /// backups unless every system setting is back, and before removing the app
    /// unless the helper is gone, so a failure never strands either.
    static func deleteEverything() async -> String {
        Diagnostics.log("delete wakely: started")
        AgentMonitor.shared.stop()
        ComponentRuntime.shared.stop()
        ComponentEngine.shared.stop()
        PowerEngine.shared.shutDown()
        let sessionRestored = await ComponentEngine.shared.awaitShutdownRestoration(timeout: 8)
        _ = await PowerEngine.shared.awaitShutdownCleanup(timeout: 3)
        // Persistent settings (Home Server's autorestart, Stay Off When
        // Opened's boot preference, ...) survive a quit but not a delete.
        let allRestored = await ProtectedComponents.shared.restoreEverythingBeforeDelete(timeout: 15)
        guard sessionRestored, allRestored else {
            Diagnostics.log("delete wakely: stopped, some system settings could not be restored")
            return "Wakely couldn't put back every system setting it changed, so nothing was deleted and its backups are kept. Quit and reopen Wakely, then try again."
        }
        AppLiveness.clear()

        // Pending wakes are helper-owned and survive a quit; cancel them and
        // wait for the round trips BEFORE the helper is removed, or they would
        // outlive the uninstall.
        _ = await SleepUntilResetController.shared.cancelOwnedWakesForDelete(reason: "Wakely is being deleted")

        // The administrator path also removes a fallback-installed daemon and
        // the helper's root-owned data.
        // The admin step goes first: if it is canceled, nothing has been
        // unregistered yet and the helper keeps running.
        if case .failure(let error) = await HelperClient.shared.uninstallWithAdministratorPrompt(removeData: true) {
            Diagnostics.log("delete wakely: stopped, helper removal failed: \(error.localizedDescription)")
            return "The privileged helper wasn't removed (\(error.localizedDescription)), so Wakely was not deleted. Quit and reopen Wakely, then try again."
        }
        await HelperClient.shared.uninstall()

        try? await SMAppService.agent(plistName: HelperService.agentPlistName).unregister()
        try? await SMAppService.mainApp.unregister()
        run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(HelperService.agentLabel)"])
        try? FileManager.default.removeItem(at: ManualAgentInstaller.launchAgentURL())
        // The deletion watcher must not outlive a Delete Wakely: it would
        // race this uninstaller and wipe the support directory twice.
        UninstallWatcherInstaller.uninstall()

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
