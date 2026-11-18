// RequestJournalTests — durable request outcome bookkeeping.
//
// Foundation only: no XPC, no root, no real settings, no BackupStore, no
// hardware. Every test uses a fresh temporary directory and deletes it.
// Standalone compile:
//   xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
//     -module-cache-path build/componentcache \
//     Sources/HelperProtocol.swift Helper/RequestJournal.swift \
//     Tests/RequestJournalTests.swift -o build/tests/request-journal

import Foundation

@main
struct RequestJournalTests {
    static func main() {
        do {
            try roundTrip()
            try duplicateIsRefused()
            try interruptedRecovery()
            try retentionKeepsUnresolved()
            try directoryRefusal()
            try unknownLookup()
            try requestCodingCompatibility()
            try restoreScopeMapping()
            try corruptJournalRepair()
            try unsupportedVersionRepair()
            try repairMapsLeasesAndSkipsUnknown()
            try repairWithNoLeasesAllowsNewRequests()
            try repairWriteFailureLeavesNoPartialState()
            try archiveNeverOverwritesOrDeletes()
            print("Request journal tests passed (round trip, coding compatibility, recovery, retention, refusal, scopes, corrupt-journal repair; no system access)")
        } catch {
            FileHandle.standardError.write(
                Data("Request journal tests failed: \(error.localizedDescription)\n".utf8)
            )
            fatalError("Request journal tests failed")
        }
    }

    // MARK: - Harness

    private static func makeTemporaryDirectory() throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "wakely-request-journal-\(UUID().uuidString)",
                isDirectory: true
            )
            .path
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return path
    }

    private static func remove(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Whole-second dates so JSON's ISO-8601 encoding round-trips exactly.
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Tests

    private static func roundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        let journal = RequestJournal(directoryPath: directory)
        let id = UUID()
        let accepted = try journal.begin(
            requestID: id,
            operation: .lowPowerMode,
            componentID: "lowPowerWhileClosed",
            now: base
        )
        precondition(accepted.state == .accepted)
        precondition(accepted.operation == HelperOperation.lowPowerMode.rawValue)
        precondition(accepted.componentID == "lowPowerWhileClosed")
        precondition(accepted.leaseComponent == nil)
        precondition(accepted.finishedAt == nil)

        precondition(journal.lookup(requestID: id)?.state == .accepted)

        let running = try journal.markRunning(requestID: id, now: base.addingTimeInterval(1))
        precondition(running.state == .running)
        precondition(running.finishedAt == nil)

        let finished = try journal.finish(
            requestID: id,
            state: .succeeded,
            leaseComponent: "lowPowerWhileClosed",
            message: "Low power mode enabled.",
            now: base.addingTimeInterval(2)
        )
        precondition(finished.state == .succeeded)
        precondition(finished.leaseComponent == "lowPowerWhileClosed")
        precondition(finished.message == "Low power mode enabled.")
        precondition(finished.finishedAt == base.addingTimeInterval(2))

        // A fresh instance proves the record really went through JSON and the
        // same directory, not just memory.
        let reopened = RequestJournal(directoryPath: directory)
        guard let seen = reopened.lookup(requestID: id) else {
            fatalError("A finished record did not survive a reopen")
        }
        precondition(seen == finished)

        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: reopened.filePath
        )
        let fileMode = (fileAttributes[.posixPermissions] as? NSNumber)?.intValue
        precondition(fileMode == 0o600, "the journal file must be 0600, got \(String(fileMode ?? -1, radix: 8))")

        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory)
        let directoryMode = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
        precondition(directoryMode == 0o700, "the journal directory must be 0700, got \(String(directoryMode ?? -1, radix: 8))")

        // The same terminal finish is idempotent.
        let repeated = try journal.finish(
            requestID: id,
            state: .succeeded,
            now: base.addingTimeInterval(10)
        )
        precondition(repeated.state == .succeeded)
        precondition(repeated.finishedAt == base.addingTimeInterval(2))
    }

    private static func duplicateIsRefused() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        let journal = RequestJournal(directoryPath: directory)
        let id = UUID()
        _ = try journal.begin(
            requestID: id,
            operation: .lowPowerMode,
            componentID: "lowPowerWhileClosed",
            now: base
        )

        // Reusing a UUID must never become a second mutation.
        do {
            _ = try journal.begin(
                requestID: id,
                operation: .lowPowerMode,
                componentID: "lowPowerWhileClosed",
                now: base.addingTimeInterval(1)
            )
            fatalError("A duplicate request UUID was accepted")
        } catch {
            precondition(error.localizedDescription.contains("already recorded"))
        }

        // The same UUID with a different payload is also refused.
        do {
            _ = try journal.begin(
                requestID: id,
                operation: .fanPercent,
                componentID: "fanBoost",
                now: base.addingTimeInterval(1)
            )
            fatalError("A duplicate request UUID with a different operation was accepted")
        } catch {
            precondition(error.localizedDescription.contains("already recorded"))
        }

        let recordCount = try journal.records().count
        precondition(recordCount == 1)
    }

    private static func interruptedRecovery() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        let journal = RequestJournal(directoryPath: directory)

        let acceptedID = UUID()
        _ = try journal.begin(requestID: acceptedID, operation: .lowPowerMode,
                              componentID: "lowPowerWhileClosed", now: base)

        let runningID = UUID()
        _ = try journal.begin(requestID: runningID, operation: .fanPercent,
                              componentID: "fanBoost", now: base)
        _ = try journal.markRunning(requestID: runningID, now: base)

        let succeededID = UUID()
        _ = try journal.begin(requestID: succeededID, operation: .lowPowerMode,
                              componentID: "lowPowerWhileClosed", now: base)
        _ = try journal.finish(requestID: succeededID, state: .succeeded, now: base)

        let failedID = UUID()
        _ = try journal.begin(requestID: failedID, operation: .touchIDUnlock,
                              componentID: "passwordAfterClose", now: base)
        _ = try journal.finish(requestID: failedID, state: .failedBeforeMutation, now: base)

        let leaseID = UUID()
        _ = try journal.begin(requestID: leaseID, operation: .fanPercent,
                              componentID: "fanBoost", now: base)
        _ = try journal.finish(requestID: leaseID, state: .failedWithRecoveryLease,
                               leaseComponent: "fanBoost", now: base)

        let recovered = try journal.recoverInterrupted(now: base.addingTimeInterval(60))
        precondition(recovered == 2, "accepted and running must both become interruptedUnknown")

        precondition(journal.lookup(requestID: acceptedID)?.state == .interruptedUnknown)
        precondition(journal.lookup(requestID: runningID)?.state == .interruptedUnknown)
        precondition(journal.lookup(requestID: succeededID)?.state == .succeeded)
        precondition(journal.lookup(requestID: failedID)?.state == .failedBeforeMutation)
        precondition(journal.lookup(requestID: leaseID)?.state == .failedWithRecoveryLease)

        // A restart must not invent success or failure for the interrupted pair,
        // and must not claim a completion time it cannot know.
        let recoveredRecord = journal.lookup(requestID: runningID)
        precondition(recoveredRecord?.finishedAt == nil)
        precondition(recoveredRecord?.message?.contains("unknown") == true)

        // Recovery is idempotent and stays on disk for the next process.
        let recoveredAgain = try journal.recoverInterrupted(now: base.addingTimeInterval(120))
        precondition(recoveredAgain == 0)
        let reopened = RequestJournal(directoryPath: directory)
        precondition(reopened.lookup(requestID: acceptedID)?.state == .interruptedUnknown)
        precondition(reopened.lookup(requestID: runningID)?.state == .interruptedUnknown)
        precondition(reopened.lookup(requestID: succeededID)?.state == .succeeded)
    }

    private static func retentionKeepsUnresolved() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        let journal = RequestJournal(directoryPath: directory)
        let ancient = base.addingTimeInterval(-30 * 24 * 60 * 60)

        // An unresolved lease from a month ago: retention must keep it.
        let leaseID = UUID()
        _ = try journal.begin(requestID: leaseID, operation: .fanPercent,
                              componentID: "fanBoost", now: ancient)
        _ = try journal.markRunning(requestID: leaseID, now: ancient)
        _ = try journal.finish(requestID: leaseID, state: .failedWithRecoveryLease,
                               leaseComponent: "fanBoost", message: "manual recovery required",
                               now: ancient)

        // An interrupted request recovered long ago stays protected too.
        let interruptedID = UUID()
        _ = try journal.begin(requestID: interruptedID, operation: .lowPowerMode,
                              componentID: "lowPowerWhileClosed", now: ancient)
        _ = try journal.recoverInterrupted(now: ancient.addingTimeInterval(1))

        // A resolved record from a month ago is expendable.
        let oldResolvedID = UUID()
        _ = try journal.begin(requestID: oldResolvedID, operation: .lowPowerMode,
                              componentID: "lowPowerWhileClosed", now: ancient)
        _ = try journal.finish(requestID: oldResolvedID, state: .succeeded,
                               message: "old success", now: ancient)

        // More recent resolved records than the cap allows.
        for index in 0..<505 {
            let id = UUID()
            let stamp = base.addingTimeInterval(TimeInterval(index))
            _ = try journal.begin(requestID: id, operation: .lowPowerMode,
                                  componentID: "bulk", now: stamp)
            _ = try journal.finish(requestID: id, state: .succeeded,
                                   message: "bulk", now: stamp)
        }

        let records = try journal.records()
        precondition(
            records.contains { $0.requestID == leaseID },
            "retention must never drop a record that still needs recovery"
        )
        precondition(
            records.contains { $0.requestID == interruptedID },
            "interruptedUnknown must survive retention until reconciled"
        )
        precondition(
            !records.contains { $0.requestID == oldResolvedID },
            "a resolved record older than the retention window must be dropped"
        )
        precondition(
            records.count <= RequestJournal.maximumRecords,
            "resolved records must be capped at \(RequestJournal.maximumRecords), got \(records.count)"
        )
        precondition(
            records.filter { $0.state == .succeeded }.count <= RequestJournal.maximumRecords
        )
    }

    private static func directoryRefusal() throws {
        let root = try makeTemporaryDirectory()
        defer { remove(root) }

        // The journal path is an existing regular file, not a directory.
        let blocked = root + "/blocked"
        guard FileManager.default.createFile(atPath: blocked, contents: Data("not a directory".utf8)) else {
            fatalError("Could not create the blocking file")
        }
        let journal = RequestJournal(directoryPath: blocked)
        do {
            _ = try journal.begin(requestID: UUID(), operation: .lowPowerMode,
                                  componentID: "lowPowerWhileClosed", now: base)
            fatalError("The journal wrote through a regular file")
        } catch {
            precondition(!FileManager.default.fileExists(atPath: blocked + "/" + RequestJournal.fileName))
        }

        // A path below a regular file cannot be created either.
        let nested = RequestJournal(directoryPath: blocked + "/requests")
        do {
            _ = try nested.begin(requestID: UUID(), operation: .lowPowerMode,
                                 componentID: "lowPowerWhileClosed", now: base)
            fatalError("The journal wrote below a regular file")
        } catch {
            precondition(!FileManager.default.fileExists(atPath: nested.filePath))
        }

        // A symlinked directory is refused rather than followed.
        let real = root + "/real"
        try FileManager.default.createDirectory(atPath: real, withIntermediateDirectories: true)
        let link = root + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)
        let linked = RequestJournal(directoryPath: link)
        do {
            _ = try linked.begin(requestID: UUID(), operation: .lowPowerMode,
                                 componentID: "lowPowerWhileClosed", now: base)
            fatalError("The journal wrote through a symlinked directory")
        } catch {
            precondition(!FileManager.default.fileExists(atPath: real + "/" + RequestJournal.fileName))
        }
    }

    private static func unknownLookup() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        let journal = RequestJournal(directoryPath: directory)
        let unknown = UUID()
        precondition(journal.lookup(requestID: unknown) == nil)
        let missingRecord = try journal.record(requestID: unknown)
        precondition(missingRecord == nil)

        do {
            _ = try journal.markRunning(requestID: unknown, now: base)
            fatalError("markRunning accepted an unknown request")
        } catch {
            precondition(error.localizedDescription.contains("No request journal record"))
        }

        do {
            _ = try journal.finish(requestID: unknown, state: .succeeded, now: base)
            fatalError("finish accepted an unknown request")
        } catch {
            precondition(error.localizedDescription.contains("No request journal record"))
        }
    }

    private static func requestCodingCompatibility() throws {
        // A version-1 request has neither requestID nor protocolVersion and
        // must still decode.
        let legacyID = UUID()
        let legacyJSON = Data("""
        {"id":"\(legacyID.uuidString)","operation":"lowPowerMode","componentID":"lowPowerWhileClosed","boolValue":true}
        """.utf8)
        guard let legacy = HelperCoding.decode(HelperRequest.self, from: legacyJSON) else {
            fatalError("A version-1 HelperRequest no longer decodes")
        }
        precondition(legacy.id == legacyID)
        precondition(legacy.requestID == nil)
        precondition(legacy.protocolVersion == nil)
        precondition(legacy.operation == .lowPowerMode)
        precondition(legacy.boolValue == true)

        // The new query fields and operation names round-trip.
        let requestID = UUID()
        let query = HelperRequest(operation: .requestStatus, requestID: requestID,
                                  protocolVersion: 2)
        let encoded = HelperCoding.encode(query)
        guard let decoded = HelperCoding.decode(HelperRequest.self, from: encoded) else {
            fatalError("A version-2 HelperRequest did not round-trip")
        }
        precondition(decoded.operation == .requestStatus)
        precondition(decoded.requestID == requestID)
        precondition(decoded.protocolVersion == 2)

        guard let restore = HelperOperation(rawValue: "restoreSession") else {
            fatalError("restoreSession is not a wire operation")
        }
        precondition(restore == .restoreSession)
        precondition(HelperService.protocolVersion == "5")
    }

    private static func restoreScopeMapping() throws {
        // Session cleanup may touch these three, and only these three.
        precondition(HelperRestoreScope.sessionComponents.includes(.lowPowerMode))
        precondition(HelperRestoreScope.sessionComponents.includes(.fanPercent))
        precondition(HelperRestoreScope.sessionComponents.includes(.touchIDUnlock))
        precondition(HelperRestoreScope.sessionComponents.includes(storedOperation: "touchIDUnlock.system.v1"))
        precondition(HelperRestoreScope.sessionComponents.includes(storedOperation: "touchIDUnlock"))

        // Persistent settings survive a session.
        precondition(HelperRestoreScope.persistentComponents.includes(.autoRestartAfterPowerLoss))
        precondition(HelperRestoreScope.persistentComponents.includes(.bootOnLidOpen))
        precondition(HelperRestoreScope.persistentComponents.includes(.suppressWakeSources))
        precondition(!HelperRestoreScope.sessionComponents.includes(.autoRestartAfterPowerLoss))
        precondition(!HelperRestoreScope.sessionComponents.includes(.bootOnLidOpen))
        precondition(!HelperRestoreScope.sessionComponents.includes(.suppressWakeSources))

        // Administrative/query operations have no scope.
        precondition(HelperRestoreScope.scope(for: .restoreAll) == nil)
        precondition(HelperRestoreScope.scope(for: .restoreSession) == nil)
        precondition(HelperRestoreScope.scope(for: .requestStatus) == nil)
        precondition(HelperRestoreScope.scope(for: .ping) == nil)

        // An unrecognised stored operation is never treated as session scope.
        precondition(HelperRestoreScope.scope(forStoredOperation: "somethingElse") == nil)

        precondition(Set(HelperRestoreScope.sessionComponents.operations)
            == Set([.lowPowerMode, .fanPercent, .touchIDUnlock]))
        precondition(Set(HelperRestoreScope.persistentComponents.operations)
            == Set([.autoRestartAfterPowerLoss, .bootOnLidOpen, .suppressWakeSources]))
    }

    // MARK: - Corrupt journal repair

    private static func writeJournal(_ directory: String, _ text: String) throws {
        let path = directory + "/" + RequestJournal.fileName
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            fatalError("Could not write the test journal at \(path)")
        }
    }

    private static func fileMode(_ path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private static func archives(in directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix(RequestJournal.archivePrefix) }.sorted()
    }

    private static func temporaryFiles(in directory: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasPrefix(".\(RequestJournal.fileName).") && $0.hasSuffix(".tmp") }
    }

    private static func archive(_ directory: String, now: Date = base) throws -> URL {
        guard let url = try RequestJournal.archiveUnreadable(at: directory, now: now) else {
            fatalError("A journal that needs repair was not archived")
        }
        return url
    }

    /// A parse failure must never be silently replaced: the bytes are archived
    /// (0600, unchanged) and the rebuilt journal is a normal versioned file that
    /// recovery treats as already settled.
    private static func corruptJournalRepair() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        let corrupt = "{ this is not a request journal"
        try writeJournal(directory, corrupt)

        let journal = RequestJournal(directoryPath: directory)
        do {
            _ = try journal.recoverInterrupted(now: base)
            fatalError("recoverInterrupted accepted a corrupt journal")
        } catch {
            // Expected: the fail-closed gate still refuses mutations.
        }

        let archived = try archive(directory)
        precondition(FileManager.default.fileExists(atPath: archived.path))
        let archivedBytes = try Data(contentsOf: archived)
        precondition(archivedBytes == Data(corrupt.utf8),
                     "the archive must preserve the original bytes")
        precondition(fileMode(archived.path) == 0o600,
                     "the archive must be 0600, got \(String(fileMode(archived.path) ?? -1, radix: 8))")
        precondition(!FileManager.default.fileExists(atPath: journal.filePath))

        let outcome = try journal.repair(from: [])
        precondition(outcome.repaired == 0)
        precondition(outcome.skipped == 0)
        precondition(outcome.total == 0)

        // A repaired journal is valid and carries no interrupted records, so a
        // second startup pass is a no-op: no archive, no write.
        let recovered = try journal.recoverInterrupted(now: base.addingTimeInterval(1))
        precondition(recovered == 0)
        let records = try journal.records()
        precondition(records.isEmpty)

        let archivesBefore = archives(in: directory)
        let contentBefore = try Data(contentsOf: URL(fileURLWithPath: journal.filePath))
        let recoveredAgain = try journal.recoverInterrupted(now: base.addingTimeInterval(2))
        precondition(recoveredAgain == 0)
        precondition(archives(in: directory) == archivesBefore,
                     "a repaired journal must not be archived again")
        let contentAfter = try Data(contentsOf: URL(fileURLWithPath: journal.filePath))
        precondition(contentAfter == contentBefore,
                     "a repaired journal must not be rewritten when nothing is interrupted")
        precondition(temporaryFiles(in: directory).isEmpty)
    }

    /// A journal from a newer daemon is refused, not migrated, then archived and
    /// replaced exactly like a corrupt one.
    private static func unsupportedVersionRepair() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        try writeJournal(directory, "{\"version\":999,\"records\":[]}")
        let journal = RequestJournal(directoryPath: directory)
        do {
            _ = try journal.recoverInterrupted(now: base)
            fatalError("recoverInterrupted accepted an unsupported journal version")
        } catch let error as RequestJournal.JournalError {
            guard case .unsupportedVersion(999) = error else {
                fatalError("unexpected error for an unsupported version: \(error)")
            }
        }

        let archived = try archive(directory)
        precondition(fileMode(archived.path) == 0o600)

        let outcome = try journal.repair(
            from: [RequestJournal.RecoveryLease(componentID: "fanBoost",
                                                operation: "fanPercent")],
            now: base
        )
        precondition(outcome.repaired == 1)
        precondition(outcome.skipped == 0)
        let repairedRecords = try journal.records()
        precondition(repairedRecords.count == 1)
        let recoveredOnce = try journal.recoverInterrupted(now: base.addingTimeInterval(60))
        precondition(recoveredOnce == 0)
        let recoveredTwice = try journal.recoverInterrupted(now: base.addingTimeInterval(120))
        precondition(recoveredTwice == 0)
        precondition(archives(in: directory).count == 1)
    }

    /// One lease maps through the versioned Touch ID token; one unknown
    /// operation is skipped and counted instead of being invented as a record.
    private static func repairMapsLeasesAndSkipsUnknown() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        try writeJournal(directory, "not json at all")
        _ = try archive(directory)

        let leases = [
            RequestJournal.RecoveryLease(componentID: "passwordAfterClose",
                                         operation: "touchIDUnlock.system.v1"),
            RequestJournal.RecoveryLease(componentID: "mysteryComponent",
                                         operation: "futureOperation.v9"),
        ]
        let outcome = try journal(directory).repair(from: leases, now: base)
        precondition(outcome.repaired == 1)
        precondition(outcome.skipped == 1,
                     "the unmappable lease must be reported, got \(outcome.skipped)")
        precondition(outcome.total == 2)

        let records = try journal(directory).records()
        precondition(records.count == 1)
        guard let record = records.first else {
            fatalError("The repaired journal lost its reconstructed record")
        }
        precondition(record.operation == HelperOperation.touchIDUnlock.rawValue)
        precondition(record.componentID == "passwordAfterClose")
        precondition(record.state == .interruptedUnknown)
        precondition(record.leaseComponent == "passwordAfterClose")
        precondition(record.message == RequestJournal.repairMessage)
        precondition(record.createdAt == base)
        precondition(record.updatedAt == base)
        precondition(record.finishedAt == nil,
                     "a reconstructed record must not claim a completion time")
        precondition(!records.contains { $0.componentID == "mysteryComponent" })

        // The recovery obligation stays visible and is already terminal, so
        // startup recovery does not manufacture a second state change.
        let recovered = try journal(directory).recoverInterrupted(now: base.addingTimeInterval(60))
        precondition(recovered == 0)
        let reloaded = try journal(directory).record(requestID: record.requestID)
        precondition(reloaded?.state == .interruptedUnknown)
    }

    /// No saved leases means nothing is owed: an empty but valid journal, after
    /// which a normal begin/finish cycle works again.
    private static func repairWithNoLeasesAllowsNewRequests() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        try writeJournal(directory, "{\"version\":1,\"records\":[{\"requestID\":")
        _ = try archive(directory)

        let journal = RequestJournal(directoryPath: directory)
        let outcome = try journal.repair(from: [])
        precondition(outcome.repaired == 0)
        precondition(outcome.skipped == 0)
        let emptyRecords = try journal.records()
        precondition(emptyRecords.isEmpty)

        let id = UUID()
        let accepted = try journal.begin(requestID: id, operation: .fanPercent,
                                        componentID: "fanBoost", now: base)
        precondition(accepted.state == .accepted)
        let finished = try journal.finish(requestID: id, state: .succeeded,
                                          now: base.addingTimeInterval(1))
        precondition(finished.state == .succeeded)

        // A fresh instance proves the empty journal was persisted, not implied.
        let reopened = RequestJournal(directoryPath: directory)
        let reopenedRecord = try reopened.record(requestID: id)
        precondition(reopenedRecord?.state == .succeeded)
    }

    /// A repair that cannot write must throw and leave neither a half-written
    /// journal nor a temporary file. The gate then still refuses mutations.
    private static func repairWriteFailureLeavesNoPartialState() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        // `requests.json` as a directory makes the final rename fail after the
        // sibling temporary file was created: deterministic and uid-independent
        // (root cannot make this succeed either).
        let blocked = directory + "/" + RequestJournal.fileName
        try FileManager.default.createDirectory(atPath: blocked, withIntermediateDirectories: false)

        let journal = RequestJournal(directoryPath: directory)
        do {
            _ = try journal.repair(
                from: [RequestJournal.RecoveryLease(componentID: "fanBoost",
                                                    operation: "fanPercent")],
                now: base
            )
            fatalError("repair reported success although the journal could not be written")
        } catch {
            // Expected: the caller must keep failing closed.
        }

        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: blocked, isDirectory: &isDirectory))
        precondition(isDirectory.boolValue, "the failed repair replaced the blocking directory")
        precondition(temporaryFiles(in: directory).isEmpty,
                     "a failed repair left a temporary journal behind: \(temporaryFiles(in: directory))")

        // No valid journal exists, so no mutation may begin.
        do {
            _ = try journal.begin(requestID: UUID(), operation: .fanPercent,
                                  componentID: "fanBoost", now: base)
            fatalError("a mutation began without a valid journal")
        } catch {
            // Expected: fail closed.
        }
    }

    /// Archives are never overwritten and a non-file journal is never moved or
    /// deleted.
    private static func archiveNeverOverwritesOrDeletes() throws {
        let directory = try makeTemporaryDirectory()
        defer { remove(directory) }

        // Pretend an earlier archive for this exact second already exists.
        let firstPath = directory + "/" + RequestJournal.archiveBaseName(now: base) + ".json"
        guard FileManager.default.createFile(
            atPath: firstPath,
            contents: Data("earlier archive".utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            fatalError("Could not create the earlier archive")
        }

        try writeJournal(directory, "corrupt")
        let second = try archive(directory)
        precondition(second.path != firstPath)
        precondition(second.lastPathComponent.hasSuffix("-1.json"),
                     "a second archive in the same second must be suffixed, got \(second.lastPathComponent)")
        let earlier = try Data(contentsOf: URL(fileURLWithPath: firstPath))
        precondition(earlier == Data("earlier archive".utf8),
                     "an existing archive must never be overwritten")
        precondition(fileMode(second.path) == 0o600)

        // A journal path that is not a regular file is refused, not moved.
        let nested = try makeTemporaryDirectory()
        defer { remove(nested) }
        let directoryPath = nested + "/" + RequestJournal.fileName
        try FileManager.default.createDirectory(atPath: directoryPath, withIntermediateDirectories: false)
        do {
            _ = try RequestJournal.archiveUnreadable(at: nested, now: base)
            fatalError("archiveUnreadable moved a directory")
        } catch {
            // Expected.
        }
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: directoryPath, isDirectory: &isDirectory))
        precondition(isDirectory.boolValue)
    }

    private static func journal(_ directory: String) -> RequestJournal {
        RequestJournal(directoryPath: directory)
    }
}
