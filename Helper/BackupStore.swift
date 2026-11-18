// BackupStore — the daemon's memory of what it changed.
//
// Every privileged write records the value that was there first, so a component
// can be put back exactly the way it was found. The store lives in a
// root-only directory: 0700 on the directory, 0600 on the file, written
// atomically (temporary file in the same directory + rename).
//
// It holds setting values only. No passwords, tokens, account names, or other
// user data are stored here.

import Darwin
import Foundation

enum BackupStore {
    static let directoryPath = "/Library/Application Support/dev.wakely.helper"
    static let filePath = directoryPath + "/backup.json"

    /// One setting change. `previous` is the value captured before the daemon
    /// wrote anything; `written` is what it wrote. When the same component and
    /// operation are changed again before a restore, the earliest `previous`
    /// is kept: restoration must target the value from before the first
    /// change, not an intermediate one.
    struct Entry: Codable, Sendable, Equatable {
        var componentID: String
        var operation: String
        var previous: String
        var written: String
        var at: Date

        init(componentID: String, operation: String, previous: String, written: String, at: Date) {
            self.componentID = componentID
            self.operation = operation
            self.previous = previous
            self.written = written
            self.at = at
        }
    }

    enum StoreError: LocalizedError {
        case unreadable(String)
        case unwritable(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let message), .unwritable(let message):
                return message
            }
        }
    }

    private static let lock = NSLock()

    // MARK: - Public API

    /// Every saved entry. A missing store is empty, not an error. A malformed
    /// or unreadable store is an error: guessing would lose a restoration
    /// target.
    static func load() throws -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    /// Same as `load()`, named for callers that only want to inspect.
    static func list() throws -> [Entry] {
        try load()
    }

    /// Upsert one entry. An existing entry for the same (componentID, operation)
    /// keeps its original `previous` and `at`; only `written` is refreshed.
    /// Returns the entry actually stored, so callers can report the value
    /// restoration will really target (the earliest captured one).
    @discardableResult
    static func save(_ entry: Entry) throws -> Entry {
        lock.lock()
        defer { lock.unlock() }

        var entries = try loadUnlocked()
        let effective: Entry
        if let index = entries.firstIndex(where: {
            $0.componentID == entry.componentID && $0.operation == entry.operation
        }) {
            var merged = entry
            merged.previous = entries[index].previous
            merged.at = entries[index].at
            entries[index] = merged
            effective = merged
        } else {
            entries.append(entry)
            effective = entry
        }
        try writeUnlocked(entries)
        return effective
    }

    /// Remove every saved value belonging to a component. Called only after all
    /// of that component's values have been re-applied and verified.
    static func remove(componentID: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var entries = try loadUnlocked()
        let before = entries.count
        entries.removeAll { $0.componentID == componentID }
        guard entries.count != before else { return }
        try writeUnlocked(entries)
    }

    // MARK: - Disk

    private static func loadUnlocked() throws -> [Entry] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) else {
            return []
        }
        guard !isDirectory.boolValue else {
            throw StoreError.unreadable("\(filePath) is a directory, not a backup file.")
        }

        let url = URL(fileURLWithPath: filePath)
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            throw StoreError.unreadable("\(filePath) is not a regular file; refusing to read it.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable("Could not read \(filePath): \(error.localizedDescription)")
        }
        guard !data.isEmpty else { return [] }

        do {
            return try makeDecoder().decode([Entry].self, from: data)
        } catch {
            throw StoreError.unreadable("Could not parse \(filePath): \(error.localizedDescription)")
        }
    }

    private static func writeUnlocked(_ entries: [Entry]) throws {
        try ensureDirectoryUnlocked()

        let data: Data
        do {
            data = try makeEncoder().encode(entries)
        } catch {
            throw StoreError.unwritable("Could not encode the backup store: \(error.localizedDescription)")
        }

        // Write a sibling temporary file with the final permissions, then
        // rename it over the destination. rename(2) is atomic on one volume,
        // and the 0600 mode is in place before the file has its real name.
        let temporaryPath = directoryPath + "/.backup.json.\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(
            atPath: temporaryPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw StoreError.unwritable("Could not create a temporary backup file in \(directoryPath).")
        }

        let renamed = temporaryPath.withCString { source in
            filePath.withCString { destination in
                rename(source, destination)
            }
        }
        guard renamed == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: temporaryPath)
            throw StoreError.unwritable("Could not replace \(filePath) atomically (errno \(code)).")
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: filePath
            )
        } catch {
            throw StoreError.unwritable("Could not set permissions on \(filePath): \(error.localizedDescription)")
        }
    }

    private static func ensureDirectoryUnlocked() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: directoryPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw StoreError.unwritable("\(directoryPath) exists and is not a directory.")
            }
            let url = URL(fileURLWithPath: directoryPath)
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               values.isDirectory != true || values.isSymbolicLink == true {
                throw StoreError.unwritable("\(directoryPath) is not a real directory; refusing to write through it.")
            }
        } else {
            do {
                try fileManager.createDirectory(
                    atPath: directoryPath,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw StoreError.unwritable("Could not create \(directoryPath): \(error.localizedDescription)")
            }
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryPath
            )
        } catch {
            throw StoreError.unwritable("Could not set permissions on \(directoryPath): \(error.localizedDescription)")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
