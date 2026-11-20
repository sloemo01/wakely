// InstallRecord — where the installed app lives, published on every launch.
//
// The uninstall watcher (a LaunchAgent whose binary survives deletion) and
// the privileged helper (which self-cleans when the app is gone) both need
// one fact they cannot ask the app for after a Trash: which path counts as
// "the app". This record answers it. It is deliberately tiny — bundle path,
// bundle id, timestamp — and lives next to the other per-user state in
// ~/Library/Application Support/Wakely/install.json.
//
// The read side is UninstallWatcher/Presence.swift (tolerant: a missing or
// malformed record just means "no recorded path"); the field name is mirrored
// in UninstallWatcherPolicy.installRecordFileName and the test suite checks
// the two stay in agreement.

import Foundation

enum InstallRecord {
    /// Wire field names. `appPath` is the only one the watcher reads.
    struct Record: Codable {
        var appPath: String
        var bundleID: String
        var writtenAt: TimeInterval
    }

    // Mirrored from UninstallWatcher/Policy.swift (installRecordFileName);
    // Tests/test_uninstall_watcher.py keeps them in agreement.
    static var fileName: String { "install.json" }

    static func fileURL(supportDirectory: URL = SupportPaths.baseDirectory) -> URL {
        supportDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Publish this launch's bundle location. Atomic sibling-then-rename,
    /// same posture as the liveness record. Best-effort: a failure only means
    /// the watcher falls back to the standard install locations.
    static func publish(bundleURL: URL = Bundle.main.bundleURL,
                        bundleID: String? = Bundle.main.bundleIdentifier) {
        guard let bundleID, bundleID.hasPrefix("dev.wakely") else { return }
        let record = Record(appPath: bundleURL.path,
                            bundleID: bundleID,
                            writtenAt: Date().timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(record) else { return }
        let directory = SupportPaths.baseDirectory
        let destination = fileURL(supportDirectory: directory)
        let temporary = directory.appendingPathComponent(".install-\(getpid())-\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary, options: .atomic)
            _ = try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            Diagnostics.log("install record: could not publish \(error.localizedDescription)")
        }
    }
}
