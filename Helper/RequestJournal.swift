// RequestJournal — the daemon's authoritative record of request outcomes.
//
// A transport failure is not evidence that a mutation did not happen. This
// store is written by root before a privileged write starts and again when the
// write reaches a terminal state, so the app can ask the daemon what really
// happened instead of inferring completion from a concurrent lease snapshot.
//
// Storage posture matches BackupStore.swift: a root-only directory (0700), one
// 0600 file, written atomically (sibling temporary file + rename), and symlinks
// or non-regular files are refused. The directory is injectable so tests can
// use a temporary directory and never touch /Library.
//
// Retention is bounded (7 days and at most 500 records) but never drops a
// record in a non-terminal state or one that still needs recovery
// (`interruptedUnknown`, `failedWithRecoveryLease`). Those obligations outlive
// any age or count limit.
//
// A journal that cannot be parsed (corruption, or a revision this daemon does
// not understand) would otherwise refuse every mutation forever. The repair
// path below is deliberately conservative: the unreadable file is moved aside
// inside the same root-only directory and never deleted, and the replacement
// journal is rebuilt only from leases BackupStore actually saved. If those
// leases cannot be read or the replacement cannot be written, the caller keeps
// failing closed; nothing is guessed and no unresolved work is dropped.

import Darwin
import Foundation

final class RequestJournal {
    static let defaultDirectoryPath = "/Library/Application Support/dev.wakely.helper"
    static let fileName = "requests.json"

    /// On-disk document revision. A newer version is refused rather than
    /// decoded as if it were this one.
    static let currentVersion = 1

    /// Records retained regardless of age. Protected records may push the
    /// store above this number; correctness outranks the cap.
    static let maximumRecords = 500

    /// Terminal, resolved records older than this are dropped.
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    struct Record: Codable, Equatable, Sendable {
        var requestID: UUID
        var operation: String
        var componentID: String
        var state: HelperRequestState
        var leaseComponent: String?
        var message: String?
        var createdAt: Date
        var updatedAt: Date
        var finishedAt: Date?
    }

    private struct Document: Codable {
        var version: Int
        var records: [Record]
    }

    enum JournalError: LocalizedError {
        case unreadable(String)
        case unwritable(String)
        case unsupportedVersion(Int)
        case duplicate(requestID: UUID, operation: String, state: HelperRequestState)
        case unknownRequest(UUID)
        case invalidTransition(requestID: UUID,
                               from: HelperRequestState,
                               to: HelperRequestState)

        var errorDescription: String? {
            switch self {
            case .unreadable(let message), .unwritable(let message):
                return message
            case .unsupportedVersion(let version):
                return "The request journal has unsupported version \(version); refusing to read or replace it."
            case .duplicate(let requestID, let operation, let state):
                return "Request \(requestID.uuidString) is already recorded as \(state.rawValue) "
                    + "for operation '\(operation)'; refusing to run a second mutation. "
                    + "Query requestStatus for the authoritative result."
            case .unknownRequest(let requestID):
                return "No request journal record exists for \(requestID.uuidString)."
            case .invalidTransition(let requestID, let from, let to):
                return "Request \(requestID.uuidString) cannot change from \(from.rawValue) to \(to.rawValue)."
            }
        }
    }

    let directoryPath: String

    var filePath: String {
        directoryPath + "/" + Self.fileName
    }

    private let lock = NSLock()

    init(directoryPath: String = RequestJournal.defaultDirectoryPath) {
        self.directoryPath = directoryPath
    }

    // MARK: - Public API

    /// Persist acceptance *before* the caller performs any mutation. If this
    /// throws, nothing may be written: the request cannot be accounted for.
    func begin(requestID: UUID, operation: HelperOperation, componentID: String,
               now: Date = Date()) throws -> Record {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadUnlocked()
        if let existing = records.first(where: { $0.requestID == requestID }) {
            // Never replay a UUID into a second mutation. The client can query
            // the existing record and decide for itself.
            throw JournalError.duplicate(
                requestID: requestID,
                operation: existing.operation,
                state: existing.state
            )
        }

        let record = Record(
            requestID: requestID,
            operation: operation.rawValue,
            componentID: componentID,
            state: .accepted,
            leaseComponent: nil,
            message: nil,
            createdAt: now,
            updatedAt: now,
            finishedAt: nil
        )
        records.append(record)
        records = Self.pruned(records, now: now)
        try writeUnlocked(records)
        return record
    }

    /// Called immediately before the first setting write. Throwing here means
    /// the daemon must not write: the journal can no longer describe the
    /// request.
    @discardableResult
    func markRunning(requestID: UUID, now: Date = Date()) throws -> Record {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadUnlocked()
        guard let index = records.firstIndex(where: { $0.requestID == requestID }) else {
            throw JournalError.unknownRequest(requestID)
        }
        switch records[index].state {
        case .accepted, .running:
            break
        default:
            throw JournalError.invalidTransition(
                requestID: requestID,
                from: records[index].state,
                to: .running
            )
        }
        records[index].state = .running
        records[index].updatedAt = now
        try writeUnlocked(records)
        return records[index]
    }

    /// Record the terminal outcome before the daemon sends its reply.
    /// `leaseComponent` names the component whose BackupStore entry still needs
    /// recovery; it is only meaningful for `failedWithRecoveryLease`.
    @discardableResult
    func finish(requestID: UUID, state: HelperRequestState,
                leaseComponent: String? = nil, message: String? = nil,
                now: Date = Date()) throws -> Record {
        guard state.isTerminal else {
            throw JournalError.invalidTransition(
                requestID: requestID,
                from: .running,
                to: state
            )
        }

        lock.lock()
        defer { lock.unlock() }

        var records = try loadUnlocked()
        guard let index = records.firstIndex(where: { $0.requestID == requestID }) else {
            throw JournalError.unknownRequest(requestID)
        }
        guard !records[index].state.isTerminal else {
            // The same terminal result is idempotent; a different one is a bug.
            guard records[index].state == state else {
                throw JournalError.invalidTransition(
                    requestID: requestID,
                    from: records[index].state,
                    to: state
                )
            }
            return records[index]
        }

        records[index].state = state
        records[index].leaseComponent = leaseComponent
        records[index].message = message
        records[index].updatedAt = now
        records[index].finishedAt = now
        let finished = records[index]
        records = Self.pruned(records, now: now)
        try writeUnlocked(records)
        return finished
    }

    /// Authoritative lookup. A missing record is `nil`; a store that cannot be
    /// read is an error, never silently "unknown".
    func record(requestID: UUID) throws -> Record? {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked().first(where: { $0.requestID == requestID })
    }

    /// Convenience for callers that only need a best-effort answer. The
    /// status query uses `record(requestID:)` so a read failure stays visible.
    func lookup(requestID: UUID) -> Record? {
        do {
            return try record(requestID: requestID)
        } catch {
            return nil
        }
    }

    /// Every stored record, oldest first. Used by diagnostics and tests.
    func records() throws -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked().sorted { $0.createdAt < $1.createdAt }
    }

    /// Run once at daemon startup. `accepted`/`running` mean the process died
    /// between journaling and recording a result, so the outcome is unknown,
    /// not failed and certainly not successful. Returns the number converted.
    @discardableResult
    func recoverInterrupted(now: Date = Date()) throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        var records = try loadUnlocked()
        var recovered = 0
        for index in records.indices {
            switch records[index].state {
            case .accepted, .running:
                records[index].state = .interruptedUnknown
                records[index].updatedAt = now
                // Deliberately no finishedAt: the request may have finished
                // before the crash or not at all. Claiming a completion time
                // would manufacture evidence the daemon does not have.
                records[index].finishedAt = nil
                records[index].message =
                    "The helper restarted before this request recorded a result; "
                    + "its outcome is unknown. Inspect the saved lease before retrying."
                recovered += 1
            case .succeeded, .failedBeforeMutation, .failedWithRecoveryLease,
                 .interruptedUnknown:
                break
            }
        }

        // A missing journal stays missing: recovery alone must not create one.
        guard recovered > 0 else { return 0 }
        records = Self.pruned(records, now: now)
        try writeUnlocked(records)
        return recovered
    }

    // MARK: - Startup repair

    /// The only part of `BackupStore.Entry` repair needs. Keeping this type
    /// here, instead of taking `BackupStore.Entry` directly, lets the journal
    /// be built and tested without the live store; startup maps saved leases
    /// onto it one-for-one.
    struct RecoveryLease: Equatable, Sendable {
        var componentID: String
        var operation: String

        init(componentID: String, operation: String) {
            self.componentID = componentID
            self.operation = operation
        }
    }

    struct RepairOutcome: Equatable, Sendable {
        /// Records written into the fresh journal.
        var repaired: Int
        /// Leases whose stored operation is not one this daemon can own. They
        /// are reported, never invented into records.
        var skipped: Int

        var total: Int { repaired + skipped }
    }

    /// Prefix of the archived copies. They live next to the journal in the
    /// same 0700 directory, so the path is root-only and safe to log.
    static let archivePrefix = "requests.corrupt-"

    /// The message on every reconstructed record. Deliberately says the
    /// outcome is unknown: a lease proves a value *may* need putting back, not
    /// that the request failed (or succeeded).
    static let repairMessage =
        "Reconstructed from a saved helper lease after the request journal could not be read."

    /// BackupStore operation names are not always wire operation names. Touch ID
    /// has a versioned system-scope token as well as the legacy bare name; only
    /// the mutation that saves a lease is eligible here. Administrative and
    /// restore operations never own a lease, so a record for them would be
    /// fabricated.
    static func repairOperation(forStoredOperation name: String) -> HelperOperation? {
        // Kept as a literal: this file is compiled without Operations.swift,
        // where TouchIDHelperPolicy.operation lives. HelperProtocol and
        // Operations must keep the same token.
        if name == "touchIDUnlock.system.v1" {
            return .touchIDUnlock
        }
        guard let operation = HelperOperation(rawValue: name) else { return nil }
        switch operation {
        case .lowPowerMode, .suppressWakeSources, .fanPercent, .touchIDUnlock,
             .bootOnLidOpen, .autoRestartAfterPowerLoss:
            return operation
        case .ping, .status, .restoreComponent, .restoreComponentLegacy, .restoreAll, .requestStatus,
             .restoreSession, .scheduleWake, .cancelWake, .wakeSchedules:
            return nil
        }
    }

    /// Rebuild the journal from saved recovery leases after the unreadable file
    /// has been archived. One record per mappable lease, all in
    /// `interruptedUnknown` with the lease named: the request's outcome is
    /// unknown, and the lease is what keeps the recovery obligation visible.
    ///
    /// This does not read the old journal (it is known to be unreadable) and
    /// writes through the same atomic temporary-file + rename path as every
    /// other mutation. A write failure throws with the old bytes untouched
    /// (the caller archives first); a failed repair must never look like a
    /// successful one. With no leases this writes a valid empty journal, which
    /// is the correct state: nothing was owed.
    @discardableResult
    func repair(from leases: [RecoveryLease], now: Date = Date()) throws -> RepairOutcome {
        lock.lock()
        defer { lock.unlock() }

        var records: [Record] = []
        var skipped = 0
        for lease in leases {
            guard let operation = Self.repairOperation(forStoredOperation: lease.operation) else {
                skipped += 1
                continue
            }
            records.append(Record(
                requestID: UUID(),
                operation: operation.rawValue,
                componentID: lease.componentID,
                state: .interruptedUnknown,
                leaseComponent: lease.componentID,
                message: Self.repairMessage,
                createdAt: now,
                updatedAt: now,
                finishedAt: nil
            ))
        }

        try writeUnlocked(records)
        return RepairOutcome(repaired: records.count, skipped: skipped)
    }

    /// Move the journal out of the way after it failed to decode. It is
    /// evidence, so it is renamed, never deleted, and stays inside
    /// `directoryPath` (the same 0700 directory) where the replacement is
    /// written. Returns `nil` when there is no journal file at all; throws if
    /// the archive cannot be produced, in which case the caller must not write
    /// a replacement.
    @discardableResult
    static func archiveUnreadable(at directoryPath: String,
                                  now: Date = Date()) throws -> URL? {
        let fileManager = FileManager.default
        let filePath = directoryPath + "/" + fileName

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) else {
            return nil
        }
        guard !isDirectory.boolValue else {
            throw JournalError.unreadable("\(filePath) is a directory; refusing to archive it.")
        }

        let sourceURL = URL(fileURLWithPath: filePath)
        if let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            throw JournalError.unreadable("\(filePath) is not a regular file; refusing to archive it.")
        }

        let destinationURL = try archiveDestination(in: directoryPath, now: now, fileManager: fileManager)
        // Same-directory move only: the archive must never leave the protected
        // directory, and copy+remove must never span volumes.
        guard destinationURL.deletingLastPathComponent().standardizedFileURL
                == sourceURL.deletingLastPathComponent().standardizedFileURL else {
            throw JournalError.unwritable("Refusing to archive \(filePath) outside \(directoryPath).")
        }

        // Preferred: rename(2). Atomic, and the bytes are untouched.
        let renamed = sourceURL.path.withCString { source in
            destinationURL.path.withCString { destination in
                rename(source, destination)
            }
        }
        if renamed == 0 {
            // The source was normally already 0600; make sure the archive is
            // too. The directory is 0700, so a failure here does not expose it
            // and must not discard the repair path.
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
            return destinationURL
        }

        // Fallback for a same-directory move that rename refused. Copy and
        // verify first; the original is removed only after the archive exists,
        // so a failure at any step still leaves the unreadable bytes in place.
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw JournalError.unreadable(
                "Could not archive \(filePath): \(error.localizedDescription)"
            )
        }

        guard fileManager.createFile(
            atPath: destinationURL.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw JournalError.unwritable(
                "Could not archive \(filePath) to \(destinationURL.path)."
            )
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            throw JournalError.unwritable(
                "Could not set permissions on \(destinationURL.path): \(error.localizedDescription)"
            )
        }

        do {
            try fileManager.removeItem(atPath: filePath)
        } catch {
            throw JournalError.unwritable(
                "Archived \(filePath) to \(destinationURL.path) but could not remove the original: "
                    + error.localizedDescription
            )
        }
        return destinationURL
    }

    /// `requests.corrupt-<timestamp>.json`, suffixing `-1`, `-2`, ... rather
    /// than ever overwriting an earlier archive.
    private static func archiveDestination(in directoryPath: String, now: Date,
                                           fileManager: FileManager) throws -> URL {
        let base = directoryPath + "/" + archiveBaseName(now: now)
        var candidate = base + ".json"
        var suffix = 1
        while fileManager.fileExists(atPath: candidate) {
            candidate = base + "-\(suffix).json"
            suffix += 1
            if suffix > 1000 {
                throw JournalError.unwritable(
                    "Could not choose an unused archive name in \(directoryPath)."
                )
            }
        }
        return URL(fileURLWithPath: candidate)
    }

    /// ISO-8601-ish and filename-safe: `2026-11-12T07-09-35Z`. Colons become
    /// hyphens so the name is portable and never looks like a path separator.
    static func archiveBaseName(now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withFullDate, .withTime, .withDashSeparatorInDate,
            .withColonSeparatorInTime, .withTimeZone,
        ]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        return archivePrefix + stamp
    }

    // MARK: - Retention

    /// Drops only records that are both terminal and no longer needed. A
    /// record with `needsRecovery` is never evicted, even above the cap.
    private static func pruned(_ records: [Record], now: Date) -> [Record] {
        var kept = records.filter { record in
            guard !record.state.needsRecovery else { return true }
            return now.timeIntervalSince(record.updatedAt) <= retentionInterval
        }

        guard kept.count > maximumRecords else { return kept }
        var overflow = kept.count - maximumRecords
        var drop = Set<UUID>()
        for record in kept.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard overflow > 0 else { break }
            guard !record.state.needsRecovery else { continue }
            drop.insert(record.requestID)
            overflow -= 1
        }
        kept.removeAll { drop.contains($0.requestID) }
        return kept
    }

    // MARK: - Disk

    private func loadUnlocked() throws -> [Record] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: filePath, isDirectory: &isDirectory) else {
            return []
        }
        guard !isDirectory.boolValue else {
            throw JournalError.unreadable("\(filePath) is a directory, not a request journal.")
        }

        let url = URL(fileURLWithPath: filePath)
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            throw JournalError.unreadable("\(filePath) is not a regular file; refusing to read it.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JournalError.unreadable("Could not read \(filePath): \(error.localizedDescription)")
        }
        guard !data.isEmpty else { return [] }

        let document: Document
        do {
            document = try Self.makeDecoder().decode(Document.self, from: data)
        } catch {
            throw JournalError.unreadable("Could not parse \(filePath): \(error.localizedDescription)")
        }
        guard document.version == Self.currentVersion else {
            throw JournalError.unsupportedVersion(document.version)
        }
        return document.records
    }

    private func writeUnlocked(_ records: [Record]) throws {
        try ensureDirectoryUnlocked()

        let data: Data
        do {
            data = try Self.makeEncoder().encode(
                Document(version: Self.currentVersion, records: records)
            )
        } catch {
            throw JournalError.unwritable("Could not encode the request journal: \(error.localizedDescription)")
        }

        // Sibling temporary file with the final mode, then rename over the
        // destination: rename(2) is atomic on one volume, and 0600 is in place
        // before the file has its real name.
        let temporaryPath = directoryPath + "/.\(Self.fileName).\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(
            atPath: temporaryPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw JournalError.unwritable("Could not create a temporary request journal in \(directoryPath).")
        }

        let renamed = temporaryPath.withCString { source in
            filePath.withCString { destination in
                rename(source, destination)
            }
        }
        guard renamed == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: temporaryPath)
            throw JournalError.unwritable("Could not replace \(filePath) atomically (errno \(code)).")
        }

        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: filePath
            )
        } catch {
            throw JournalError.unwritable("Could not set permissions on \(filePath): \(error.localizedDescription)")
        }
    }

    private func ensureDirectoryUnlocked() throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false

        if fileManager.fileExists(atPath: directoryPath, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw JournalError.unwritable("\(directoryPath) exists and is not a directory.")
            }
            let url = URL(fileURLWithPath: directoryPath)
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
               values.isDirectory != true || values.isSymbolicLink == true {
                throw JournalError.unwritable("\(directoryPath) is not a real directory; refusing to write through it.")
            }
        } else {
            do {
                try fileManager.createDirectory(
                    atPath: directoryPath,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw JournalError.unwritable("Could not create \(directoryPath): \(error.localizedDescription)")
            }
        }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryPath
            )
        } catch {
            throw JournalError.unwritable("Could not set permissions on \(directoryPath): \(error.localizedDescription)")
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
