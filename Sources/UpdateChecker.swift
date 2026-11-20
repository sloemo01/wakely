// UpdateChecker — checks GitHub releases for a newer Wakely and offers to
// install it. The download is the same signed DMG the website serves, so the
// update carries the same signature and needs no Sparkle-style appcast.

import AppKit
import Foundation

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, downloadURL: URL)
    case failed(String)
}

struct LatestRelease {
    let version: String
    let downloadURL: URL?
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    private static let apiURL = URL(string: "https://api.github.com/repos/sloemo01/wakely/releases/latest")!
    private static let automaticKey = "updates.automaticChecks"
    private static let lastCheckKey = "updates.lastCheck"
    private static let dismissedKey = "updates.dismissedVersion"
    /// One automatic check per day is plenty for a hand-shipped app.
    private static let autoCheckInterval: TimeInterval = 20 * 3600

    @Published private(set) var status: UpdateStatus = .idle
    @Published var automaticChecks: Bool {
        didSet { UserDefaults.standard.set(automaticChecks, forKey: Self.automaticKey) }
    }
    @Published private(set) var installing = false
    @Published private(set) var installError: String?

    private init() {
        automaticChecks = UserDefaults.standard.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    var currentVersion: String { AppVersion.current }

    /// Launch entry point: throttled automatic check plus the one-time prompt.
    func checkOnLaunch() {
        guard automaticChecks else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > Self.autoCheckInterval else { return }
        Task { await checkForUpdates() }
    }

    func checkForUpdates() async {
        status = .checking
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        do {
            let release = try await fetchLatestRelease()
            Diagnostics.log("update check: \(currentVersion) → \(release.version)")
            if UpdateVersion.isNewer(release.version, than: currentVersion) {
                status = .available(version: release.version, downloadURL: release.downloadURL ?? Self.fallbackDownloadURL)
                promptIfNeeded(release)
            } else {
                status = .upToDate
            }
        } catch {
            Diagnostics.log("update check failed: \(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

    /// The website's /dl always serves the current signed DMG; its final URL
    /// names the release (Wakely-2.0.6-r9.dmg), so the check needs no API.
    static let fallbackDownloadURL = URL(string: "https://wake-ly.app/dl")!

    private func fetchLatestRelease() async throws -> LatestRelease {
        if let release = try? await fetchReleaseFromSite() { return release }
        return try await fetchLatestReleaseFromGitHub()
    }

    private func fetchReleaseFromSite() async throws -> LatestRelease {
        var request = URLRequest(url: Self.fallbackDownloadURL)
        // /dl redirects to the versioned DMG; a one-byte range keeps the check cheap.
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = response.url else { throw UpdateError.badResponse }
        let name = final.lastPathComponent
        guard let version = UpdateVersion.version(fromDownloadName: name) else { throw UpdateError.badResponse }
        return LatestRelease(version: version, downloadURL: final)
    }

    private func fetchLatestReleaseFromGitHub() async throws -> LatestRelease {
        var request = URLRequest(url: Self.apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Wakely/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else {
            throw UpdateError.badResponse
        }
        var download: URL?
        if let assets = object["assets"] as? [[String: Any]] {
            for asset in assets {
                if let name = asset["name"] as? String, name.hasSuffix(".dmg"),
                   let raw = asset["browser_download_url"] as? String, let url = URL(string: raw) {
                    download = url
                    break
                }
            }
        }
        return LatestRelease(version: UpdateVersion.normalizedTag(tag), downloadURL: download)
    }

    // MARK: - Prompt

    private func promptIfNeeded(_ release: LatestRelease) {
        guard let downloadURL = statusDownloadURL else { return }
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        guard dismissed != release.version else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, case .available = self.status else { return }
            let alert = NSAlert()
            alert.messageText = "Wakely \(release.version) is available"
            alert.informativeText = "You're running Wakely \(self.currentVersion). Download and install the update now?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Update Now")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            let answer = alert.runModal()
            if answer == .alertFirstButtonReturn {
                Task { await self.installUpdate(from: downloadURL) }
            } else {
                UserDefaults.standard.set(release.version, forKey: Self.dismissedKey)
            }
        }
    }

    private var statusDownloadURL: URL? {
        if case .available(_, let url) = status { return url }
        return nil
    }

    // MARK: - Install

    /// Downloads the DMG, mounts it, swaps the app bundle and offers a restart.
    func installUpdate(from url: URL) async {
        installing = true
        installError = nil
        defer { installing = false }
        do {
            let dmg = FileManager.default.temporaryDirectory
                .appendingPathComponent("Wakely-update-\(UUID().uuidString).dmg")
            let (downloaded, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            defer { try? FileManager.default.removeItem(at: dmg) }
            Diagnostics.log("update downloaded: \(dmg.path)")
            let mount = try await Self.attach(dmg)
            defer { Task { await Self.detach(mount) } }
            let mountedApp = mount.appendingPathComponent("Wakely.app")
            guard FileManager.default.fileExists(atPath: mountedApp.path) else {
                throw UpdateError.mountFailed("no Wakely.app in the download")
            }
            try await Self.verifySignature(mountedApp)
            let destination = Bundle.main.bundleURL
            // Stage via a backup of the running bundle so a failed copy can
            // never leave Wakely deleted or half-replaced.
            let backup = FileManager.default.temporaryDirectory
                .appendingPathComponent("Wakely-backup-\(UUID().uuidString).app")
            try FileManager.default.copyItem(at: destination, to: backup)
            try FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.copyItem(at: mountedApp, to: destination)
                try? FileManager.default.removeItem(at: backup)
            } catch {
                do {
                    // Clear the partial copy before restoring the backup.
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.copyItem(at: backup, to: destination)
                    try? FileManager.default.removeItem(at: backup)
                    Diagnostics.log("update restored the previous bundle")
                } catch {
                    Diagnostics.log("update restore failed; backup kept at \(backup.path)")
                }
                throw error
            }
            Diagnostics.log("update installed over \(destination.path)")
            offerRestart()
        } catch {
            Diagnostics.log("update install failed: \(error.localizedDescription)")
            installError = error.localizedDescription
        }
    }

    /// Only accept an update signed by Wakely's own team; the download host
    /// (or a hijacked redirect) must not be able to swap in another app.
    private static let expectedTeamID = "DSMWVZT3B8"

    private static func verifySignature(_ app: URL) async throws {
        _ = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path], result: { _ in () })
        let details = try await run("/usr/bin/codesign", ["-dv", "--verbose=4", app.path], result: { $0 })
        // Exact line match: the mount volume name appears in codesign's
        // output paths, so a substring check could be spoofed.
        let teamLine = "TeamIdentifier=\(expectedTeamID)"
        let matched = details.components(separatedBy: .newlines)
            .contains { $0.trimmingCharacters(in: .whitespaces) == teamLine }
        guard matched else {
            throw UpdateError.verificationFailed("signed by an unexpected team")
        }
    }

    private static func attach(_ dmg: URL) async throws -> URL {
        guard let mount = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", dmg.path], result: { output in
            for line in output.split(separator: "\n") {
                let fields = line.split(separator: "\t")
                if let last = fields.last, last.hasPrefix("/Volumes/") {
                    return URL(fileURLWithPath: String(last))
                }
            }
            return nil
        }) else {
            throw UpdateError.mountFailed("hdiutil gave no mount point")
        }
        return mount
    }

    private static func detach(_ mount: URL) async {
        _ = try? await run("/usr/bin/hdiutil", ["detach", mount.path], result: { _ in })
    }

    private static func run<T>(_ executable: String, _ arguments: [String],
                               result: @escaping (String) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    do { continuation.resume(returning: try result(output)) }
                    catch { continuation.resume(throwing: error) }
                } else {
                    continuation.resume(throwing: UpdateError.mountFailed(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do { try process.run() } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func offerRestart() {
        let alert = NSAlert()
        alert.messageText = "Wakely is updated"
        alert.informativeText = "Restart Wakely now to finish the update?"
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Wait for this process to exit before reopening, however long
        // shutdown takes, and pass the paths through the environment so no
        // shell ever interprets them.
        var environment = ProcessInfo.processInfo.environment
        environment["WAKELY_PID"] = "\(ProcessInfo.processInfo.processIdentifier)"
        environment["WAKELY_APP"] = Bundle.main.bundleURL.path
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "i=0; while kill -0 \"$WAKELY_PID\" 2>/dev/null && [ $i -lt 150 ]; do /bin/sleep 0.2; i=$((i+1)); done; exec /usr/bin/open \"$WAKELY_APP\""]
        relaunch.environment = environment
        relaunch.standardOutput = FileHandle.nullDevice
        relaunch.standardError = FileHandle.nullDevice
        try? relaunch.run()
        // Quit on a later main-queue turn: terminating from inside the
        // install task keeps the main actor busy, so the termination cleanup
        // task never runs and the old process hangs instead of exiting.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case mountFailed(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The update server returned something unexpected."
        case .mountFailed(let detail): return detail.isEmpty ? "The update download could not be mounted." : detail
        case .verificationFailed(let detail): return "The update failed signature verification (\(detail))."
        }
    }
}
