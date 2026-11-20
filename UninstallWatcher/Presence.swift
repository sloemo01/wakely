// UninstallWatcherPresence — the file/process probes the watcher and the
// privileged helper share.
//
// Foundation-only on purpose: the watcher binary and the helper daemon both
// compile this file, and the test suite compiles it standalone. Everything
// here is read-only except the install-record writer, which the APP uses
// (Sources/InstallRecord.swift) — the watcher never writes the record.
//
// Existence rule: the app counts as present when any candidate location
// holds it. Candidates are the path the app recorded at its last launch plus
// the two standard install folders. Build outputs inside project folders
// deliberately do NOT count: they are not the installed app, and counting
// them would let a stray `build/Wakely.app` block the cleanup forever.

import Foundation

enum WakelyPresence {
    /// Read the app path the app published on its last launch, if any.
    /// Tolerant by design: a missing, oversized or malformed record simply
    /// means "no recorded path", never an error.
    static func recordedAppPath(supportDirectory: URL) -> String? {
        let url = supportDirectory.appendingPathComponent(
            UninstallWatcherPolicy.installRecordFileName, isDirectory: false)
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,
              info.st_size <= 16 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        struct Record: Decodable { let appPath: String? }
        guard let record = try? JSONDecoder().decode(Record.self, from: data),
              let path = record.appPath,
              path.hasPrefix("/"), !path.contains("..") else { return nil }
        return path
    }

    /// Every location that proves an installed Wakely exists. Order is
    /// irrelevant; duplicates are removed.
    static func candidateAppPaths(recordedPath: String?, homeDirectory: URL) -> [String] {
        var paths = ["/Applications/Wakely.app",
                     homeDirectory.appendingPathComponent("Applications/Wakely.app").path]
        if let recordedPath { paths.insert(recordedPath, at: 0) }
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    static func anyCandidateExists(_ paths: [String]) -> Bool {
        let manager = FileManager.default
        return paths.contains { manager.fileExists(atPath: $0) }
    }

    /// True when Spotlight knows of a Wakely.app bundle anywhere the user can
    /// reach — a move to another folder or a rename keeps the bundle id, so
    /// this is what stops a relocation from looking like a deletion. The Trash
    /// is not Spotlight-indexed, so a genuinely trashed app never shows up
    /// here. Uncertainty resolves toward "present": a probe failure must
    /// never cause a wipe.
    static func spotlightFindsApp(homeDirectory: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemCFBundleIdentifier == '\(UninstallWatcherPolicy.bundleID)'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return true }
            let trashPath = homeDirectory.appendingPathComponent(".Trash").path + "/"
            let manager = FileManager.default
            return text.components(separatedBy: .newlines).contains { line in
                let path = line.trimmingCharacters(in: .whitespaces)
                guard path.hasSuffix(".app"), !path.hasPrefix(trashPath) else { return false }
                return manager.fileExists(atPath: path)
            }
        } catch {
            return true
        }
    }

    /// True while ANY Wakely process runs — installed app or a development
    /// build. A running instance is proof the user still has Wakely, so the
    /// watcher must never wipe underneath it.
    ///
    /// Detection goes through `ps` and a path-suffix match on the executable:
    /// comm is the full executable path on macOS (verified against a live
    /// /Applications/Wakely.app), and the suffix rejects unrelated processes
    /// whose names merely contain "wakely".
    static func appIsRunning() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.components(separatedBy: .newlines).contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasSuffix(".app/Contents/MacOS/Wakely")
            }
        } catch {
            // If the probe itself fails, assume the app might be running:
            // a false "absent" is what causes a wipe, so uncertainty must
            // resolve toward keeping everything.
            return true
        }
    }
}
