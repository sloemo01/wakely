// Operations — the daemon's complete allowlist.
//
// A request can only name a HelperOperation and carry a Bool/Int/componentID or a
// validated Unix instant (`dateValue`, for owned wakes).
// Nothing from the peer becomes an executable, an argument, a path, or an
// environment variable: every command below is a fixed argv array. Each
// command runs with a hard five-second deadline on a background queue so a
// hung tool can never wedge the XPC reply thread forever.
//
// Fan/SMC control lives in Helper/SMC.swift (owned elsewhere). This file only
// calls FanControl's public API and reports its errors.

import Darwin
import Foundation

// BEGIN TESTABLE TOUCH ID POLICY
/// Pure system-scope policy. No process, account, backup IO or hardware access.
enum TouchIDHelperPolicy {
    static let path = "/usr/bin/bioutil"
    static let operation = "touchIDUnlock.system.v1"
    static let legacyOperation = "touchIDUnlock"
    static let readArguments = ["-r", "-s"]
    static func writeArguments(_ enabled: Bool) -> [String] {
        ["-w", "-s", "-u", enabled ? "1" : "0"]
    }
    static func binary(_ value: String) -> Bool? {
        switch value {
        case "0": return false
        case "1": return true
        default: return nil
        }
    }
    static func parse(_ output: String) -> Bool? {
        let prefix = "Biometrics for unlock:"
        var found: Bool?
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix(prefix) else { continue }
            // Duplicate configured fields are ambiguous, even if they agree.
            guard found == nil,
                  let value = binary(String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            found = value
        }
        return found
    }
    static func restoreError(operation token: String, previous: String,
                             written: String, current: Bool?) -> String? {
        guard token == operation else {
            if token == legacyOperation {
                return "Ambiguous legacy Touch ID backup has no system scope; manual recovery is required. No setting was written and the lease is retained."
            }
            return "Unrecognised Touch ID backup version; the lease is retained."
        }
        guard binary(previous) != nil, let owned = binary(written) else {
            return "Invalid saved system Touch ID binary value; the lease is retained."
        }
        guard let current else {
            return "Could not read current system Touch ID unlock; the lease is retained."
        }
        guard current == owned else {
            return "System Touch ID ownership mismatch: current value differs from saved written value; refusing to overwrite an external change. The lease is retained."
        }
        return nil
    }
}
// END TESTABLE TOUCH ID POLICY

// BEGIN TESTABLE BOOT POLICY
/// Pure `BootPreference` policy: the single NVRAM key, the percent-encoded byte
/// tokens, the `nvram -p` parser and the restore decision. No process is run,
/// no NVRAM is read or written, and no backup store is touched here.
enum BootPreferencePolicy {
    /// The original's only key for this feature. `auto-boot` is never read or
    /// written: neither reference binary contains that string.
    static let key = "BootPreference"
    /// The three percent-encoded byte values the original can represent.
    static let tokens = ["%00", "%01", "%02"]
    /// `.preventLidAndPower` — written when stayOffWhenOpened is enabled. The
    /// component's own copy says "When your Mac is shut down, opening the lid or
    /// plugging it in leaves it off", naming the lid *and* power, so this
    /// component maps to %00 rather than %01 (lid only).
    static let lidAndPowerToken = "%00"
    /// "The key is not present" is a valid prior state, not a read failure.
    static let absentToken = "absent"
    static let readArguments = ["-p"]

    enum Read: Equatable {
        /// A recognised `%00`/`%01`/`%02` value.
        case state(String)
        /// The key is absent from `nvram -p`; a valid state.
        case absent
        /// Unreadable output or a value outside the three tokens; do not guess.
        case unsupported
    }

    enum RestorePlan: Equatable {
        case write(String)
        case delete
        case refuse(String)
    }

    /// The value to write for the request's "boot allowed" boolean. The wire
    /// protocol says `boolValue: false keeps a shut-down Mac off`, and
    /// stayOffWhenOpened applies with `false`, so false is the preventing state:
    /// %00. Allowing boot again restores the absent state by deleting the key.
    static func writeToken(bootAllowed: Bool) -> String {
        bootAllowed ? absentToken : lidAndPowerToken
    }

    /// argv for a token: a value sets `BootPreference=<token>`, absent deletes
    /// the key. Unknown tokens produce no argv at all.
    static func writeArguments(for token: String) -> [String]? {
        switch token {
        case absentToken:
            return ["-d", key]
        case let value where tokens.contains(value):
            return ["\(key)=\(value)"]
        default:
            return nil
        }
    }

    /// A saved token is valid only when it is exactly one of the three byte
    /// values or the absent sentinel; no trimming, no case folding.
    static func token(_ value: String) -> String? {
        value == absentToken || tokens.contains(value) ? value : nil
    }

    /// Parses `nvram -p` stdout: lines split on newline, each line split at the
    /// first tab only, exactly two fields required, the key compared exactly
    /// (case-sensitive, untrimmed), and the value trimmed of spaces before it
    /// must be one of the three byte tokens. The first matching line decides;
    /// no matching line means absent, an unrecognised value means unsupported.
    static func parse(_ output: String) -> Read {
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let fields = raw.split(separator: "\t", maxSplits: 1,
                                   omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == key else { continue }
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            return tokens.contains(value) ? .state(value) : .unsupported
        }
        return .absent
    }

    /// Restore decision, in the original's order: validate the saved tokens,
    /// read the current value, require that it is still what the helper wrote,
    /// then replay the prior (`absent` deletes the key). Anything else refuses
    /// without writing so the lease is retained and the user's change stands.
    static func restorePlan(previous: String, written: String, current: Read) -> RestorePlan {
        guard let prior = token(previous) else {
            return .refuse("Invalid saved BootPreference value '\(previous)'; no setting was written and the lease is retained.")
        }
        guard token(written) != nil else {
            return .refuse("Invalid saved BootPreference written value '\(written)'; no setting was written and the lease is retained.")
        }

        let currentToken: String
        switch current {
        case .unsupported:
            return .refuse("Could not read the current BootPreference value; no setting was written and the lease is retained.")
        case .absent:
            currentToken = absentToken
        case .state(let value):
            currentToken = value
        }

        guard currentToken == written else {
            return .refuse("BootPreference ownership mismatch: the current value differs from the saved written value; refusing to overwrite an external change. The lease is retained.")
        }

        return prior == absentToken ? .delete : .write(prior)
    }
}
// END TESTABLE BOOT POLICY

enum Operations {
    static let version = "1"

    private static let pmsetPath = "/usr/bin/pmset"
    private static let bioutilPath = TouchIDHelperPolicy.path
    private static let nvramPath = "/usr/sbin/nvram"

    /// All mutating operations are serialized. ping/status/requestStatus stay
    /// concurrent so a slow restore cannot make the helper look dead or hide a
    /// request's recorded outcome.
    private static let mutationLock = NSLock()

    /// One journal for the daemon's lifetime. It has its own lock, so a status
    /// query never waits behind a mutation.
    private static let journal = RequestJournal()

    /// Owned one-off wakes. The scheduler writes only its own root-only record
    /// and runs the two fixed pmset subcommands; the runner is the same
    /// five-second-deadline helper every other operation uses.
    private static let wakeScheduler = WakeScheduler(
        store: WakeStore(),
        now: { Date().timeIntervalSince1970 },
        run: { Command.run($0, $1).wakeCommandResult }
    )

    // MARK: - Entry point

    static func perform(_ request: HelperRequest) -> HelperReply {
        switch request.operation {
        case .ping, .status:
            return statusReply(for: request)

        case .requestStatus:
            return requestStatusReply(for: request)

        case .wakeSchedules:
            // Read-only and deliberately outside the mutation lock: listing
            // owned wakes must not wait behind (or disturb) a restore.
            return wakeSchedulesReply(for: request)

        case .lowPowerMode, .suppressWakeSources, .fanPercent, .touchIDUnlock,
             .bootOnLidOpen, .autoRestartAfterPowerLoss, .restoreComponent,
             .restoreComponentLegacy, .restoreAll, .restoreSession, .scheduleWake,
             .cancelWake:
            mutationLock.lock()
            defer { mutationLock.unlock() }
            return performMutation(request)
        }
    }

    /// Called once by the daemon before it starts listening. Requests that were
    /// accepted or running when the previous process died are not failures and
    /// not successes: they are unknown until their lease is inspected.
    ///
    /// A journal that cannot be parsed, or that comes from a newer revision, is
    /// evidence rather than garbage: it is archived inside the same root-only
    /// directory and a fresh journal is rebuilt from the leases BackupStore
    /// really saved. The lease store is read *before* archiving so a
    /// BackupStore failure leaves the unusable journal in place and every later
    /// start keeps failing closed, instead of opening mutations against an
    /// empty journal while recovery obligations still exist.
    static func recoverJournalAtStartup() -> String {
        do {
            let count = try journal.recoverInterrupted()
            if count == 0 {
                return "request journal: no interrupted requests to recover"
            }
            return "request journal: marked \(count) interrupted request(s) as unknown"
        } catch let error as RequestJournal.JournalError {
            switch error {
            case .unreadable, .unsupportedVersion:
                return repairUnreadableJournal(reason: error)
            default:
                return journalStartupFailure(error)
            }
        } catch {
            return journalStartupFailure(error)
        }
    }

    private static func journalStartupFailure(_ error: Error) -> String {
        return "request journal unavailable at startup (\(error.localizedDescription)); "
            + "mutations will be refused until it can be written"
    }

    /// Archive the unreadable journal, then rebuild it from saved leases. Every
    /// failure path returns without writing a journal, so the caller keeps
    /// failing closed and nothing unresolved is discarded.
    private static func repairUnreadableJournal(reason: Error) -> String {
        let savedLeases: [BackupStore.Entry]
        do {
            savedLeases = try BackupStore.list()
        } catch {
            return "request journal is unusable at startup (\(reason.localizedDescription)) and the saved "
                + "leases could not be read (\(error.localizedDescription)); leaving the journal untouched "
                + "and refusing mutations until both can be inspected"
        }

        let archived: URL?
        do {
            archived = try RequestJournal.archiveUnreadable(at: journal.directoryPath)
        } catch {
            return "request journal is unusable at startup (\(reason.localizedDescription)) and could not be "
                + "archived (\(error.localizedDescription)); mutations will be refused until it can be repaired"
        }

        let archivePath = archived?.path ?? "no journal file was present to archive"
        do {
            let outcome = try journal.repair(from: savedLeases.map {
                RequestJournal.RecoveryLease(componentID: $0.componentID, operation: $0.operation)
            })
            return "request journal was unusable (\(reason.localizedDescription)); archived to \(archivePath); "
                + "rebuilt \(outcome.repaired) recovery record(s) from saved leases, "
                + "skipped \(outcome.skipped) unrepairable lease(s)"
        } catch {
            let restored = restoreUnrepairedJournal(archived)
            return "request journal was unusable and archived to \(archivePath), but the repaired journal "
                + "could not be written (\(error.localizedDescription)); \(restored) Mutations stay refused "
                + "until the journal can be written."
        }
    }

    /// Undo the archive half of a failed repair when no replacement journal
    /// exists. Leaving the path empty would let the next `begin` create a
    /// fresh, empty journal and forget the saved leases, which is exactly the
    /// silent discard this repair path exists to prevent. If `repair` did
    /// manage to write before failing at a later step (for example setting
    /// permissions), its file is valid and is left in place.
    private static func restoreUnrepairedJournal(_ archived: URL?) -> String {
        guard let archived else {
            return "No archived journal was available to restore."
        }
        guard !FileManager.default.fileExists(atPath: journal.filePath) else {
            return "The repaired journal is present but could not be finalized."
        }
        do {
            try FileManager.default.moveItem(
                at: archived,
                to: URL(fileURLWithPath: journal.filePath)
            )
            return "The unreadable journal was restored in place so mutations keep failing closed."
        } catch {
            return "The unreadable journal could not be restored (\(error.localizedDescription)); "
                + "its archived copy remains at \(archived.path)."
        }
    }

    private static func performMutation(_ request: HelperRequest) -> HelperReply {
        switch request.operation {
        case .lowPowerMode:
            guard let enabled = request.boolValue else {
                return .failure(request.id, "lowPowerMode requires a boolean value.")
            }
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            return journaled(request, componentID: componentID) { journal in
                setLowPowerMode(enabled, componentID: componentID, request: request, journal: journal)
            }

        case .suppressWakeSources:
            guard request.boolValue == true else {
                return .failure(request.id, "suppressWakeSources requires true; use restoreComponent to undo it.")
            }
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            return journaled(request, componentID: componentID) { journal in
                setWakeSourcesSuppressed(componentID: componentID, request: request, journal: journal)
            }

        case .fanPercent:
            guard let percent = request.intValue else {
                return .failure(request.id, "fanPercent requires 30...100, or 0 for automatic control.")
            }
            // Original forced targets accept 30...100. The OSS protocol reserves
            // zero for hand-back. Reject before probing hardware or saving a lease.
            guard percent == 0 || (30...100).contains(percent) else {
                return .failure(request.id, "fanPercent must be 30...100 (0 restores automatic control).")
            }
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            return journaled(request, componentID: componentID) { journal in
                setFanPercent(percent, componentID: componentID, request: request, journal: journal)
            }

        case .touchIDUnlock:
            guard let enabled = request.boolValue else {
                return .failure(request.id, "touchIDUnlock requires a boolean value.")
            }
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            return journaled(request, componentID: componentID) { journal in
                setTouchIDUnlock(enabled, componentID: componentID, request: request, journal: journal)
            }

        case .bootOnLidOpen:
            guard let enabled = request.boolValue else {
                return .failure(request.id, "bootOnLidOpen requires a boolean value.")
            }
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            return journaled(request, componentID: componentID) { journal in
                setBootOnLidOpen(enabled, componentID: componentID, request: request, journal: journal)
            }

        case .autoRestartAfterPowerLoss:
            guard let enabled = request.boolValue else {
                return .failure(request.id, "autoRestartAfterPowerLoss requires a boolean value.")
            }
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            return journaled(request, componentID: componentID) { journal in
                setAutoRestart(enabled, componentID: componentID, request: request, journal: journal)
            }

        case .restoreComponent, .restoreComponentLegacy:
            guard isValidComponentID(request.componentID) else {
                return .failure(request.id, "restoreComponent requires a non-empty, well-formed component identifier.")
            }
            return journaled(request, componentID: request.componentID) { journal in
                restoreComponent(request.componentID, request: request, journal: journal)
            }

        case .restoreSession:
            return journaled(request, componentID: "", leaseProbe: anyLeaseExists) { journal in
                restoreSession(request, journal: journal)
            }

        case .restoreAll:
            return journaled(request, componentID: "", leaseProbe: anyLeaseExists) { journal in
                restoreAll(request, journal: journal)
            }

        case .scheduleWake:
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            // No BackupStore lease is involved: the ownership record is what
            // proves a wake exists, and `wakeSchedules` reports it. The journal
            // still records the request and its outcome, never the event.
            return journaled(request, componentID: componentID) { journal in
                scheduleOwnedWake(request, componentID: componentID, journal: journal)
            }

        case .cancelWake:
            guard let componentID = checkedComponentID(for: request) else {
                return .failure(request.id, invalidComponentMessage)
            }
            return journaled(request, componentID: componentID) { journal in
                cancelOwnedWake(request, journal: journal)
            }

        default:
            return .failure(request.id, "Unknown privileged operation.")
        }
    }

    // MARK: - Request journal

    /// Journal the request, run it, and record its terminal outcome before the
    /// reply is sent. `begin` is the fail-closed gate: if the journal cannot be
    /// persisted, the body never runs, so no setting is written.
    ///
    /// `leaseProbe` decides whether a failed reply left a BackupStore entry
    /// behind. It is only consulted after a failure, so it cannot change the
    /// success path.
    private static func journaled(_ request: HelperRequest,
                                  componentID: String,
                                  _ body: (RequestJournal) -> HelperReply) -> HelperReply {
        journaled(request, componentID: componentID,
                  leaseProbe: { componentHasLease(componentID) }, body)
    }

    private static func journaled(_ request: HelperRequest,
                                  componentID: String,
                                  leaseProbe: () -> Bool,
                                  _ body: (RequestJournal) -> HelperReply) -> HelperReply {
        do {
            _ = try journal.begin(
                requestID: request.id,
                operation: request.operation,
                componentID: componentID
            )
        } catch {
            return .failure(
                request.id,
                "Refusing to run \(request.operation.rawValue): the request journal could not "
                    + "record it (\(error.localizedDescription)). No setting was changed. "
                    + "Query requestStatus with this request's UUID before retrying."
            )
        }

        var reply = body(journal)
        let hasLease = reply.ok ? false : leaseProbe()
        let state: HelperRequestState = reply.ok
            ? .succeeded
            : (hasLease ? .failedWithRecoveryLease : .failedBeforeMutation)
        let leaseComponent = hasLease && !componentID.isEmpty ? componentID : nil

        do {
            _ = try journal.finish(
                requestID: request.id,
                state: state,
                leaseComponent: leaseComponent,
                message: reply.message
            )
        } catch {
            // The mutation may have happened; never let the caller keep an
            // optimistic reply when the journal could not record the result.
            reply.ok = false
            reply.message += " The request journal could not record the result "
                + "(\(error.localizedDescription)); the outcome is unknown until "
                + "requestStatus or the saved lease is inspected."
        }
        return reply
    }

    /// Marks the record running immediately before a setting write. A journal
    /// failure here aborts before the first write, so the lease may exist but
    /// no setting changed; the wrapper classifies that as a recovery-lease
    /// failure, which is exactly the truth.
    private static func markRunning(_ journal: RequestJournal,
                                    _ request: HelperRequest,
                                    _ what: String) -> HelperReply? {
        do {
            try journal.markRunning(requestID: request.id)
            return nil
        } catch {
            return .failure(
                request.id,
                "Refusing to \(what): the request journal could not record that the "
                    + "write started (\(error.localizedDescription)). No setting was changed."
            )
        }
    }

    private static func anyLeaseExists() -> Bool {
        do {
            return try !BackupStore.list().isEmpty
        } catch {
            // An unreadable store cannot prove that no lease exists, so the
            // conservative classification is "recovery may be needed".
            return true
        }
    }

    private static func componentHasLease(_ componentID: String) -> Bool {
        do {
            return try BackupStore.list().contains { $0.componentID == componentID }
        } catch {
            return true
        }
    }

    private static func requestStatusReply(for request: HelperRequest) -> HelperReply {
        let requestID = request.requestID ?? request.id
        let key = "request.\(requestID.uuidString)"
        var details: [String: String] = [
            "protocol": HelperService.protocolVersion,
        ]

        do {
            if let record = try journal.record(requestID: requestID) {
                details["\(key).state"] = record.state.rawValue
                details["\(key).operation"] = record.operation
                details["\(key).lease"] = record.leaseComponent ?? ""
                details["\(key).message"] = record.message ?? ""
                details["\(key).finishedAt"] = record.finishedAt.map(iso8601) ?? ""
                return HelperReply(
                    id: request.id,
                    ok: true,
                    message: "Request \(requestID.uuidString) is \(record.state.rawValue).",
                    details: details
                )
            }
            details["\(key).state"] = "unknown"
            return HelperReply(
                id: request.id,
                ok: true,
                message: "No journal record exists for request \(requestID.uuidString).",
                details: details
            )
        } catch {
            details["\(key).state"] = "unknown"
            details["\(key).message"] = "The request journal could not be read: \(error.localizedDescription)"
            return HelperReply(
                id: request.id,
                ok: false,
                message: "The privileged helper could not read its request journal: "
                    + "\(error.localizedDescription)",
                details: details
            )
        }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Status

    private static func statusReply(for request: HelperRequest) -> HelperReply {
        var details: [String: String] = [
            "version": version,
            "protocol": HelperService.protocolVersion,
            "fan": FanControl.isSupported() ? "yes" : "no",
            "bioutil": FileManager.default.fileExists(atPath: bioutilPath) ? "yes" : "no",
            "nvram": FileManager.default.fileExists(atPath: nvramPath) ? "yes" : "no",
        ]

        // Saved leases let the app restore settings left behind by a crash
        // without mutating anything during the probe.
        let leases = (try? BackupStore.list()) ?? []
        details["leases"] = Array(Set(leases.map(\.componentID))).sorted().joined(separator: ",")

        // Per-operation readiness, so the app can refuse to enable a component the
        // hardware cannot support instead of finding out after the first write.
        func capability(_ operation: String, supported: Bool, reason: String) {
            details[operation] = supported ? "supported" : "unsupported"
            if !supported { details["\(operation).reason"] = reason }
        }
        let lowPowerOK = (try? readLowPowerMode()) != nil
        capability("lowPowerMode", supported: lowPowerOK,
                   reason: "pmset does not report a readable lowpowermode value")
        capability("autoRestartAfterPowerLoss",
                   supported: pmsetReportsAutorestart(),
                   reason: "pmset does not report autorestart on this Mac")
        let wakeSources = (try? readBatteryWakeSources()) ?? [:]
        capability("suppressWakeSources", supported: !wakeSources.isEmpty,
                   reason: "pmset does not report battery powernap, proximitywake or womp on this Mac")
        capability("fanPercent", supported: FanControl.isSupported(),
                   reason: FanControl.supportReason())
        let touchIDOK = readTouchIDUnlock() != nil
        capability("touchIDUnlock", supported: touchIDOK,
                   reason: "bioutil did not report a readable Touch ID setting")
        let bootOK: Bool
        switch readBootPreference() {
        case .unsupported: bootOK = false
        case .absent, .state: bootOK = true
        }
        capability("bootOnLidOpen", supported: bootOK,
                   reason: "nvram did not report a readable BootPreference value")
        let wakeDir = WakeStore.defaultDirectoryPath
        let wakeOK = FileManager.default.fileExists(atPath: wakeDir)
            ? FileManager.default.isWritableFile(atPath: wakeDir)
            : FileManager.default.isWritableFile(atPath: "/Library/Application Support")
        for operation in ["ping", "status", "restoreComponent", "restoreModule",
                          "restoreAll", "restoreSession", "requestStatus"] {
            capability(operation, supported: true, reason: "")
        }
        for operation in ["scheduleWake", "cancelWake", "wakeSchedules"] {
            capability(operation, supported: wakeOK,
                       reason: "the helper wake store is not writable")
        }

        let message: String
        switch request.operation {
        case .ping:
            message = "pong"
        case .status:
            message = "Wakely privileged helper \(version) is ready."
        default:
            message = "ok"
        }
        return HelperReply(id: request.id, ok: true, message: message, details: details)
    }

    // MARK: - Component identifiers

    private static let invalidComponentMessage = "The component identifier is missing or malformed."

    /// The app may send an empty componentID for a direct operation. The daemon
    /// groups such changes under the component that owns the setting, so a later
    /// restoreComponent("lowPowerWhileClosed") can still find them.
    private static func checkedComponentID(for request: HelperRequest) -> String? {
        if request.componentID.isEmpty {
            let fallback = defaultComponentID(for: request.operation)
            return isValidComponentID(fallback) ? fallback : nil
        }
        return isValidComponentID(request.componentID) ? request.componentID : nil
    }

    private static func defaultComponentID(for operation: HelperOperation) -> String {
        switch operation {
        case .lowPowerMode: return "lowPowerWhileClosed"
        case .suppressWakeSources: return "sleepMeansSleep"
        case .fanPercent: return "fanBoost"
        case .touchIDUnlock: return "passwordAfterClose"
        case .bootOnLidOpen: return "stayOffWhenOpened"
        case .autoRestartAfterPowerLoss: return "homeServer"
        case .scheduleWake, .cancelWake: return "sleepUntilReset"
        default: return ""
        }
    }

    private static func isValidComponentID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    // MARK: - Low power mode

    private static func setLowPowerMode(_ enabled: Bool, componentID: String,
                                        request: HelperRequest,
                                        journal: RequestJournal) -> HelperReply {
        let prior: Int
        do {
            prior = try readLowPowerMode()
        } catch {
            return .failure(
                request.id,
                "Could not read the current low power mode: \(error.localizedDescription)"
            )
        }

        let previous = String(prior)
        let written = enabled ? "1" : "0"

        let saved: BackupStore.Entry
        do {
            saved = try BackupStore.save(BackupStore.Entry(
                componentID: componentID,
                operation: HelperOperation.lowPowerMode.rawValue,
                previous: previous,
                written: written,
                at: Date()
            ))
        } catch {
            return .failure(
                request.id,
                "Refusing to change low power mode without recording its previous value: \(error.localizedDescription)"
            )
        }

        if let refusal = markRunning(journal, request, "change low power mode") {
            return refusal
        }
        do {
            try applyLowPowerMode(enabled)
        } catch {
            return .failure(request.id, error.localizedDescription)
        }

        return HelperReply(
            id: request.id,
            ok: true,
            message: enabled ? "Low power mode enabled." : "Low power mode disabled.",
            details: ["previous": saved.previous, "current": written]
        )
    }

    private static func readLowPowerMode() throws -> Int {
        let direct = Command.run(pmsetPath, ["-b", "-g", "lowpowermode"])
        if direct.succeeded, let value = trailingInteger(direct.stdout) {
            guard (0...2).contains(value) else { throw OperationError("Unsupported low power mode value \(value).") }
            return value
        }

        // Some macOS builds reject the dedicated query ("unhandled argument")
        // while still listing lowpowermode in `-g custom`. Read-only fallback:
        // it never guesses a value and never changes anything.
        let listing = Command.run(pmsetPath, ["-b", "-g", "custom"])
        if listing.succeeded, let value = settingInteger(in: listing.stdout, key: "lowpowermode") {
            guard (0...2).contains(value) else { throw OperationError("Unsupported low power mode value \(value).") }
            return value
        }

        let primary = direct.succeeded
            ? "pmset returned no lowpowermode value"
            : direct.summary
        let fallback = listing.succeeded
            ? "the custom listing did not contain lowpowermode"
            : listing.summary
        throw OperationError("pmset could not report low power mode (\(primary); fallback: \(fallback))")
    }

    private static func applyLowPowerMode(_ enabled: Bool) throws {
        try applyLowPowerModeValue(enabled ? 1 : 0)
    }

    private static func applyLowPowerModeValue(_ value: Int) throws {
        guard (0...2).contains(value) else { throw OperationError("Invalid low power mode value.") }
        let written = String(value)
        let result = Command.run(pmsetPath, ["-b", "lowpowermode", written])
        guard result.succeeded else {
            throw OperationError("pmset could not set low power mode: \(result.summary)")
        }

        let after = try readLowPowerMode()
        guard after == value else {
            throw OperationError("pmset reported success but low power mode reads back as \(after).")
        }
    }

    // MARK: - Sleep Means Sleep

    /// Suppress the battery wake sources the Mac actually reports. The complete
    /// previous map is saved before the first write; a partial failure leaves
    /// that lease so a later restore can put every captured value back.
    private static func setWakeSourcesSuppressed(componentID: String,
                                                 request: HelperRequest,
                                                 journal: RequestJournal) -> HelperReply {
        let snapshot: [String: Int]
        do {
            snapshot = try readBatteryWakeSources()
        } catch {
            return .failure(request.id, error.localizedDescription)
        }

        let lease: WakeSourceSuppression.Lease
        do {
            lease = try WakeSourceSuppression.makeLease(from: snapshot)
        } catch {
            return .failure(request.id, error.localizedDescription)
        }

        let saved: BackupStore.Entry
        do {
            saved = try BackupStore.save(BackupStore.Entry(
                componentID: componentID,
                operation: WakeSourceSuppression.operation,
                previous: WakeSourceSuppression.encode(lease.previous),
                written: WakeSourceSuppression.encode(lease.written),
                at: Date()
            ))
        } catch {
            return .failure(
                request.id,
                "Refusing to change wake sources without recording their previous values: \(error.localizedDescription)"
            )
        }

        if let refusal = markRunning(journal, request, "suppress battery wake sources") {
            return refusal
        }
        do {
            for key in WakeSourceSuppression.settingNames where lease.previous[key] != nil {
                try applyBatteryWakeSource(key, value: 0)
            }
        } catch {
            return .failure(request.id, error.localizedDescription)
        }

        let sources = WakeSourceSuppression.settingNames
            .filter { lease.previous[$0] != nil }
            .joined(separator: ",")
        return HelperReply(
            id: request.id,
            ok: true,
            message: "Battery wake sources suppressed.",
            details: ["sources": sources, "previous": saved.previous,
                      "current": saved.written]
        )
    }

    /// Read only the battery source's custom pmset listing. Keys absent from a
    /// model are simply omitted; at least one must be present to be supported.
    private static func readBatteryWakeSources() throws -> [String: Int] {
        let result = Command.run(pmsetPath, ["-b", "-g", "custom"])
        guard result.succeeded else {
            throw OperationError("pmset could not read battery power settings: \(result.summary)")
        }
        var values: [String: Int] = [:]
        for key in WakeSourceSuppression.settingNames {
            if let value = settingInteger(in: result.stdout, key: key), (0...2).contains(value) {
                values[key] = value
            }
        }
        return values
    }

    private static func applyBatteryWakeSource(_ key: String, value: Int) throws {
        guard WakeSourceSuppression.settingNames.contains(key), (0...2).contains(value) else {
            throw OperationError("Refusing an unrecognised wake-source setting.")
        }
        let result = Command.run(pmsetPath, ["-b", key, String(value)])
        guard result.succeeded else {
            throw OperationError("pmset could not set battery \(key): \(result.summary)")
        }
        let after = try readBatteryWakeSources()
        guard after[key] == value else {
            throw OperationError(
                "pmset reported success but battery \(key) reads back as "
                    + "\(after[key].map(String.init) ?? "missing")."
            )
        }
    }

    // MARK: - Automatic restart after power loss

    private static func setAutoRestart(_ enabled: Bool, componentID: String,
                                       request: HelperRequest,
                                       journal: RequestJournal) -> HelperReply {
        guard let prior = readAutoRestart() else {
            return .failure(request.id, "autorestart is not reported on this Mac")
        }

        let previous = String(prior)
        let written = enabled ? "1" : "0"

        let saved: BackupStore.Entry
        do {
            saved = try BackupStore.save(BackupStore.Entry(
                componentID: componentID,
                operation: HelperOperation.autoRestartAfterPowerLoss.rawValue,
                previous: previous,
                written: written,
                at: Date()
            ))
        } catch {
            return .failure(
                request.id,
                "Refusing to change autorestart without recording its previous value: \(error.localizedDescription)"
            )
        }

        if let refusal = markRunning(journal, request, "change automatic restart") {
            return refusal
        }
        do {
            try applyAutoRestart(enabled)
        } catch {
            return .failure(request.id, error.localizedDescription)
        }

        return HelperReply(
            id: request.id,
            ok: true,
            message: enabled
                ? "Automatic restart after power loss enabled."
                : "Automatic restart after power loss disabled.",
            details: ["previous": saved.previous, "current": written]
        )
    }

    /// `nil` means the setting is not reported here: the query failed, the
    /// output did not mention autorestart, or no 0/1 value could be parsed.
    /// Read-only probe used by the status reply: is `autorestart` even reported?
    private static func pmsetReportsAutorestart() -> Bool {
        readAutoRestart() != nil
    }

    private static func readAutoRestart() -> Int? {
        let result = Command.run(pmsetPath, ["-c", "-g", "autorestart"])
        guard result.succeeded, result.stdout.lowercased().contains("autorestart") else {
            return nil
        }
        let value = settingInteger(in: result.stdout, key: "autorestart")
            ?? trailingInteger(result.stdout)
        guard let value, (0...1).contains(value) else { return nil }
        return value
    }

    private static func applyAutoRestart(_ enabled: Bool) throws {
        try applyAutoRestartValue(enabled ? 1 : 0)
    }

    private static func applyAutoRestartValue(_ value: Int) throws {
        guard (0...1).contains(value) else { throw OperationError("Invalid autorestart value.") }
        guard readAutoRestart() != nil else {
            throw OperationError("autorestart is not reported on this Mac")
        }

        let written = String(value)
        let result = Command.run(pmsetPath, ["-c", "autorestart", written])
        guard result.succeeded else {
            throw OperationError("pmset could not set autorestart: \(result.summary)")
        }

        guard let after = readAutoRestart() else {
            throw OperationError("autorestart is not reported after the change on this Mac")
        }
        guard after == value else {
            throw OperationError("pmset reported success but autorestart reads back as \(after).")
        }
    }

    // MARK: - Touch ID unlock

    private static func setTouchIDUnlock(_ enabled: Bool, componentID: String,
                                         request: HelperRequest,
                                         journal: RequestJournal) -> HelperReply {
        guard FileManager.default.isExecutableFile(atPath: bioutilPath) else {
            return .failure(
                request.id,
                "bioutil is missing at \(bioutilPath); Touch ID unlock cannot be changed on this Mac."
            )
        }
        guard let prior = readTouchIDUnlock() else {
            return .failure(
                request.id,
                "bioutil did not report a Touch ID unlock setting that could be parsed."
            )
        }

        let previous = prior ? "1" : "0"
        let written = enabled ? "1" : "0"

        let saved: BackupStore.Entry
        do {
            saved = try BackupStore.save(BackupStore.Entry(
                componentID: componentID,
                operation: TouchIDHelperPolicy.operation,
                previous: previous,
                written: written,
                at: Date()
            ))
        } catch {
            return .failure(
                request.id,
                "Refusing to change Touch ID unlock without recording its previous value: \(error.localizedDescription)"
            )
        }

        if let refusal = markRunning(journal, request, "change Touch ID unlock") {
            return refusal
        }
        do {
            try applyTouchIDUnlock(enabled)
        } catch {
            return .failure(request.id, error.localizedDescription)
        }

        return HelperReply(
            id: request.id,
            ok: true,
            message: enabled
                ? "System Touch ID unlock enabled."
                : "System Touch ID unlock disabled.",
            details: ["previous": saved.previous, "current": written]
        )
    }

    private static func readTouchIDUnlock() -> Bool? {
        let result = Command.run(bioutilPath, TouchIDHelperPolicy.readArguments)
        guard result.succeeded else { return nil }
        return TouchIDHelperPolicy.parse(result.stdout)
    }

    private static func applyTouchIDUnlock(_ enabled: Bool) throws {
        let result = Command.run(bioutilPath, TouchIDHelperPolicy.writeArguments(enabled))
        guard result.succeeded else {
            throw OperationError(
                "bioutil could not change system Touch ID unlock: \(result.summary)"
            )
        }

        guard let after = readTouchIDUnlock() else {
            throw OperationError("bioutil did not report a Touch ID unlock setting after the change.")
        }
        guard after == enabled else {
            throw OperationError(
                "bioutil reported success but Touch ID unlock reads back as \(after ? "1" : "0")."
            )
        }
    }

    // MARK: - Boot on lid open (NVRAM)

    /// The original's `BootPreference` mechanism: one percent-encoded byte in
    /// NVRAM, never an `auto-boot` boolean. The request boolean means "boot
    /// allowed" (`false keeps a shut-down Mac off`), so stayOffWhenOpened —
    /// which applies with `false` — writes `%00`, preventing boot on lid **and**
    /// power, matching this component's own copy: "opening the lid or plugging it
    /// in leaves it off". `true` restores the absent state by deleting the key,
    /// which is how the original says "off". An absent key is a valid prior.
    private static func setBootOnLidOpen(_ bootAllowed: Bool, componentID: String,
                                         request: HelperRequest,
                                         journal: RequestJournal) -> HelperReply {
        let prior: String
        switch readBootPreference() {
        case .unsupported:
            // Classified here, at engage time, exactly like the original: there
            // is no up-front probe beyond "nvram exists".
            return .failure(
                request.id,
                "BootPreference is not readable from NVRAM; refusing to change a value that cannot be read back."
            )
        case .absent:
            prior = BootPreferencePolicy.absentToken
        case .state(let value):
            prior = value
        }

        let written = BootPreferencePolicy.writeToken(bootAllowed: bootAllowed)

        let saved: BackupStore.Entry
        do {
            saved = try BackupStore.save(BackupStore.Entry(
                componentID: componentID,
                operation: HelperOperation.bootOnLidOpen.rawValue,
                previous: prior,
                written: written,
                at: Date()
            ))
        } catch {
            return .failure(
                request.id,
                "Refusing to change BootPreference without recording its previous value: \(error.localizedDescription)"
            )
        }

        if let refusal = markRunning(journal, request, "change BootPreference") {
            return refusal
        }
        do {
            try applyBootPreference(written)
        } catch {
            return .failure(request.id, error.localizedDescription)
        }

        return HelperReply(
            id: request.id,
            ok: true,
            message: bootAllowed
                ? "The Mac will boot when the lid opens."
                : "The Mac will stay off when the lid opens.",
            details: ["previous": saved.previous, "current": written]
        )
    }

    /// Reads only the `BootPreference` key from `nvram -p`. Other NVRAM keys are
    /// never touched, and a missing key is reported as `.absent`, not an error.
    private static func readBootPreference() -> BootPreferencePolicy.Read {
        let result = Command.run(nvramPath, BootPreferencePolicy.readArguments)
        guard result.succeeded else { return .unsupported }
        return BootPreferencePolicy.parse(result.stdout)
    }

    /// Runs the single argv the policy derives: `BootPreference=%00` to prevent
    /// boot, `-d BootPreference` to restore the absent state. The key is never
    /// read back afterwards; the original discards the `nvram` result and does
    /// not re-read, so a write is never retracted into a failure after it
    /// happened. A non-zero exit is still reported.
    private static func applyBootPreference(_ token: String) throws {
        guard let arguments = BootPreferencePolicy.writeArguments(for: token) else {
            throw OperationError("Refusing to write an unrecognised BootPreference value '\(token)'.")
        }
        let result = Command.run(nvramPath, arguments)
        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderr.isEmpty ? result.summary : stderr
            throw OperationError(
                "nvram could not \(arguments.contains("-d") ? "delete" : "write") "
                    + "BootPreference: \(detail)"
            )
        }
    }

    // MARK: - Fans

    private static func setFanPercent(_ percent: Int, componentID: String,
                                      request: HelperRequest,
                                      journal: RequestJournal) -> HelperReply {
        guard FanControl.isSupported() else {
            return .failure(request.id, "Fan control is not supported on this Mac.")
        }
        // The exact per-fan snapshot is captured before the lease is saved and
        // before any SMC write. If it is incomplete, nothing is approximated:
        // the request is refused and no lease is created or changed.
        guard let prior = FanControl.currentSnapshot(),
              let previous = FanSnapshotPolicy.encode(prior) else {
            return .failure(
                request.id,
                "Fan control is supported but the exact per-fan state could not be read; "
                    + "refusing to change fans without an exact snapshot."
            )
        }

        let target = percent
        let saved: BackupStore.Entry
        do {
            saved = try BackupStore.save(BackupStore.Entry(
                componentID: componentID,
                operation: HelperOperation.fanPercent.rawValue,
                previous: previous,
                written: FanSnapshotPolicy.unrecordedWrittenToken,
                at: Date()
            ))
        } catch {
            return .failure(
                request.id,
                "Refusing to change fan control without recording its previous value: \(error.localizedDescription)"
            )
        }

        if let refusal = markRunning(journal, request, "change fan control") {
            // The journal refused before any SMC write; do not leave an
            // unrestorable "unrecorded" lease behind.
            try? BackupStore.remove(componentID: componentID)
            return refusal
        }
        let readback: FanSnapshot
        do {
            if target == 0 {
                readback = try applyAutomaticFan()
            } else {
                readback = try applyFanPercent(target)
            }
        } catch {
            // If the fans are still byte-for-byte in the pre-write state, no
            // mutation happened. Remove the pre-saved lease instead of leaving
            // a permanent "unrecorded" entry that blocks future attempts.
            if let current = FanControl.currentSnapshot(),
               let encoded = FanSnapshotPolicy.encode(current),
               encoded == previous {
                try? BackupStore.remove(componentID: componentID)
            }
            return .failure(request.id, "Fan control failed: \(error.localizedDescription)")
        }

        // The post-change snapshot is what proves ownership at restore time.
        // Recording it is part of the lease, so a failure here is reported and
        // the (retained) lease is not silently left without one.
        guard let written = FanSnapshotPolicy.encode(readback) else {
            return .failure(
                request.id,
                "Fan control changed, but the resulting per-fan state could not be encoded; "
                    + "the lease is retained for manual recovery."
            )
        }
        do {
            try BackupStore.save(BackupStore.Entry(
                componentID: componentID,
                operation: HelperOperation.fanPercent.rawValue,
                previous: saved.previous,
                written: written,
                at: saved.at
            ))
        } catch {
            return .failure(
                request.id,
                "Fan control changed, but the state it wrote could not be recorded: "
                    + "\(error.localizedDescription). The lease is retained for manual recovery."
            )
        }

        var details = [
            "previous": saved.previous,
            "current": FanSnapshotPolicy.summary(readback),
            "readback": FanSnapshotPolicy.summary(readback),
        ]
        if target != 0 {
            let exact = readback.fans.allSatisfy { fan in
                guard fan.modeRaw == 1,
                      let expected = FanPolicy.targetRPM(
                          percent: target,
                          minimumRPM: fan.minimumRPM,
                          maximumRPM: fan.maximumRPM
                      ) else { return false }
                return abs(fan.targetRPM - expected) <= FanSnapshotPolicy.targetToleranceRPM
            }
            details["exact"] = exact ? "yes" : "no"
        }

        return HelperReply(
            id: request.id,
            ok: true,
            message: target == 0
                ? "Fan control restored to automatic."
                : "Fan control set to \(target)%.",
            details: details
        )
    }

    @discardableResult
    private static func applyFanPercent(_ percent: Int) throws -> FanSnapshot {
        do {
            try FanControl.setPercent(percent)
        } catch {
            throw OperationError("FanControl.setPercent(\(percent)) failed: \(error.localizedDescription)")
        }

        guard let after = FanControl.currentSnapshot() else {
            throw OperationError("Fan control did not report its exact per-fan state after setting \(percent)%.")
        }
        guard !FanSnapshotPolicy.isAllAutomatic(after) else {
            throw OperationError("Fan control still reports automatic mode after setting \(percent)%.")
        }
        // The SMC layer owns hardware clamping, so the readback can differ from
        // the requested percentage. It is reported instead of hidden.
        return after
    }

    @discardableResult
    private static func applyAutomaticFan() throws -> FanSnapshot {
        do {
            try FanControl.restoreAutomatic()
        } catch {
            throw OperationError("FanControl.restoreAutomatic failed: \(error.localizedDescription)")
        }

        guard let after = FanControl.currentSnapshot() else {
            throw OperationError("Fan control did not report its exact per-fan state after restoring automatic mode.")
        }
        guard FanSnapshotPolicy.isAllAutomatic(after) else {
            throw OperationError(
                "Fan control did not return to automatic mode (read back "
                    + "\(FanSnapshotPolicy.summary(after)))."
            )
        }
        return after
    }

    /// Restores one fan lease. All decisions are made by the pure policy before
    /// it returns `.restore`/`.restoreAutomatic`, and the SMC layer re-validates
    /// and re-reads the live state before its first write. A refusal leaves the
    /// lease untouched so the caller does not delete it.
    private static func restoreFan(_ entry: BackupStore.Entry) throws {
        guard FanControl.isSupported() else {
            throw OperationError("fan control is not supported on this Mac")
        }
        guard let current = FanControl.currentSnapshot() else {
            throw OperationError(
                "the current per-fan fan state could not be read; no fan was written "
                    + "and the lease is retained"
            )
        }

        switch FanSnapshotPolicy.restoreDecision(
            previousToken: entry.previous,
            writtenToken: entry.written,
            current: current
        ) {
        case .refuse(let message):
            throw OperationError(message)

        case .restoreAutomatic:
            _ = try applyAutomaticFan()

        case .restore(let snapshot):
            do {
                try FanControl.restore(snapshot, verifiedCurrent: current)
            } catch {
                throw OperationError(error.localizedDescription)
            }
        }
    }

    // MARK: - Restore

    private struct RestoreOutcome {
        let ok: Bool
        let message: String
    }

    private static func restoreComponent(_ componentID: String, request: HelperRequest,
                                      journal: RequestJournal) -> HelperReply {
        let entries: [BackupStore.Entry]
        do {
            entries = try BackupStore.list().filter { $0.componentID == componentID }
        } catch {
            return .failure(
                request.id,
                "Could not read the backup store: \(error.localizedDescription)"
            )
        }
        guard !entries.isEmpty else {
            return .failure(request.id, "No saved settings were recorded for component \(componentID).")
        }

        if let refusal = markRunning(journal, request, "restore \(componentID)") {
            return refusal
        }
        var details: [String: String] = ["component": componentID]
        for entry in entries {
            let outcome = restore(entry)
            details["\(entry.operation).previous"] = entry.previous
            details["\(entry.operation).result"] = outcome.ok ? "restored" : outcome.message
            guard outcome.ok else {
                return HelperReply(
                    id: request.id,
                    ok: false,
                    message: "Could not restore \(componentID): \(outcome.message)",
                    details: details
                )
            }
        }

        do {
            try BackupStore.remove(componentID: componentID)
        } catch {
            return HelperReply(
                id: request.id,
                ok: false,
                message: "Restored \(componentID), but its backup record could not be removed: \(error.localizedDescription)",
                details: details
            )
        }

        return HelperReply(
            id: request.id,
            ok: true,
            message: "Restored \(componentID).",
            details: details
        )
    }

    /// Restores only session-scoped leases (low power mode, fan control, Touch
    /// ID unlock). Persistent settings — autorestart and BootPreference — are
    /// never applied here, and their BackupStore records are never removed by
    /// this operation. That is the app/watchdog-safe cleanup path.
    private static func restoreSession(_ request: HelperRequest,
                                       journal: RequestJournal) -> HelperReply {
        let allEntries: [BackupStore.Entry]
        do {
            allEntries = try BackupStore.list()
        } catch {
            return .failure(
                request.id,
                "Could not read the backup store: \(error.localizedDescription)"
            )
        }

        let sessionEntries = allEntries.filter {
            HelperRestoreScope.scope(forStoredOperation: $0.operation) == .sessionComponents
        }
        guard !sessionEntries.isEmpty else {
            return HelperReply(
                id: request.id,
                ok: true,
                message: "No session settings to restore.",
                details: ["components": "0"]
            )
        }

        if let refusal = markRunning(journal, request, "restore session settings") {
            return refusal
        }

        var order: [String] = []
        var grouped: [String: [BackupStore.Entry]] = [:]
        for entry in sessionEntries {
            if grouped[entry.componentID] == nil {
                order.append(entry.componentID)
            }
            grouped[entry.componentID, default: []].append(entry)
        }

        var details: [String: String] = ["components": String(order.count)]
        var restoredCount = 0
        var failedComponents: [String] = []

        for componentID in order {
            let label = componentID.isEmpty ? "unassigned" : componentID
            var failures: [String] = []

            for entry in grouped[componentID] ?? [] {
                let outcome = restore(entry)
                if !outcome.ok {
                    failures.append("\(entry.operation): \(outcome.message)")
                }
            }

            if failures.isEmpty {
                // A component can also own a persistent entry. Removing the whole
                // component record would destroy a lease this operation is
                // forbidden to touch, so retain the record in that case.
                let hasOtherScopes = allEntries.contains {
                    $0.componentID == componentID
                        && HelperRestoreScope.scope(forStoredOperation: $0.operation) != .sessionComponents
                }
                if hasOtherScopes {
                    details[label] = "restored; backup record retained for persistent settings"
                    restoredCount += 1
                } else {
                    do {
                        try BackupStore.remove(componentID: componentID)
                        details[label] = "restored"
                        restoredCount += 1
                    } catch {
                        details[label] = "restored, but the backup record could not be removed: "
                            + error.localizedDescription
                        failedComponents.append(label)
                    }
                }
            } else {
                details[label] = "failed: " + failures.joined(separator: "; ")
                failedComponents.append(label)
            }
        }

        let ok = failedComponents.isEmpty
        let message: String
        if ok {
            message = "Restored \(restoredCount) session component\(restoredCount == 1 ? "" : "s")."
        } else {
            message = "Restored \(restoredCount) of \(order.count) session component"
                + "\(order.count == 1 ? "" : "s"); failed: \(failedComponents.joined(separator: ", "))."
        }

        return HelperReply(id: request.id, ok: ok, message: message, details: details)
    }

    private static func restoreAll(_ request: HelperRequest,
                                   journal: RequestJournal) -> HelperReply {
        let entries: [BackupStore.Entry]
        do {
            entries = try BackupStore.list()
        } catch {
            return .failure(
                request.id,
                "Could not read the backup store: \(error.localizedDescription)"
            )
        }
        guard !entries.isEmpty else {
            return HelperReply(
                id: request.id,
                ok: true,
                message: "No saved settings to restore.",
                details: ["components": "0"]
            )
        }

        if let refusal = markRunning(journal, request, "restore all saved settings") {
            return refusal
        }
        var order: [String] = []
        var grouped: [String: [BackupStore.Entry]] = [:]
        for entry in entries {
            if grouped[entry.componentID] == nil {
                order.append(entry.componentID)
            }
            grouped[entry.componentID, default: []].append(entry)
        }

        var details: [String: String] = ["components": String(order.count)]
        var restoredCount = 0
        var failedComponents: [String] = []

        for componentID in order {
            let label = componentID.isEmpty ? "unassigned" : componentID
            var failures: [String] = []

            for entry in grouped[componentID] ?? [] {
                let outcome = restore(entry)
                if !outcome.ok {
                    failures.append("\(entry.operation): \(outcome.message)")
                }
            }

            if failures.isEmpty {
                do {
                    try BackupStore.remove(componentID: componentID)
                    details[label] = "restored"
                    restoredCount += 1
                } catch {
                    details[label] = "restored, but the backup record could not be removed: \(error.localizedDescription)"
                    failedComponents.append(label)
                }
            } else {
                details[label] = "failed: " + failures.joined(separator: "; ")
                failedComponents.append(label)
            }
        }

        let ok = failedComponents.isEmpty
        let message: String
        if ok {
            message = "Restored \(restoredCount) component\(restoredCount == 1 ? "" : "s")."
        } else {
            message = "Restored \(restoredCount) of \(order.count) component\(order.count == 1 ? "" : "s"); "
                + "failed: \(failedComponents.joined(separator: ", "))."
        }

        return HelperReply(id: request.id, ok: ok, message: message, details: details)
    }

    /// Re-apply one saved prior value and verify it. The backup entry is not
    /// touched here: the caller removes it only after every entry for the
    /// component has verified.
    private static func restore(_ entry: BackupStore.Entry) -> RestoreOutcome {
        // Legacy default/user-scope baselines must never become system writes.
        if entry.operation == TouchIDHelperPolicy.legacyOperation {
            return RestoreOutcome(ok: false, message: TouchIDHelperPolicy.restoreError(
                operation: entry.operation, previous: entry.previous,
                written: entry.written, current: nil)!)
        }
        if entry.operation == TouchIDHelperPolicy.operation {
            if let error = TouchIDHelperPolicy.restoreError(
                operation: entry.operation, previous: entry.previous,
                written: entry.written, current: readTouchIDUnlock()) {
                return RestoreOutcome(ok: false, message: error)
            }
            do {
                try applyTouchIDUnlock(TouchIDHelperPolicy.binary(entry.previous)!)
                return RestoreOutcome(ok: true, message: "restored")
            } catch {
                return RestoreOutcome(ok: false, message: error.localizedDescription)
            }
        }
        // No-backup enable recovery is intentionally not synthesized: evidence
        // for the special original branch's dispatch/preconditions is incomplete.
        guard let operation = HelperOperation(rawValue: entry.operation) else {
            return RestoreOutcome(
                ok: false,
                message: "the saved operation '\(entry.operation)' is not recognised"
            )
        }

        do {
            switch operation {
            case .lowPowerMode:
                switch PowerSettingRestorePolicy.plan(previous: entry.previous, written: entry.written,
                                                      current: try? readLowPowerMode()) {
                case .alreadyRestored: break
                case .write(let prior): try applyLowPowerModeValue(prior)
                case .refuse(let message): return RestoreOutcome(ok: false, message: message)
                }

            case .autoRestartAfterPowerLoss:
                switch PowerSettingRestorePolicy.plan(previous: entry.previous, written: entry.written,
                                                      current: readAutoRestart()) {
                case .alreadyRestored: break
                case .write(let prior): try applyAutoRestartValue(prior)
                case .refuse(let message): return RestoreOutcome(ok: false, message: message)
                }

            case .suppressWakeSources:
                let current = try readBatteryWakeSources()
                switch WakeSourceSuppression.restoration(
                    previousText: entry.previous,
                    writtenText: entry.written,
                    current: current
                ) {
                case .refuse(let message):
                    return RestoreOutcome(ok: false, message: message)
                case .write(let changes):
                    for change in changes {
                        try applyBatteryWakeSource(change.key, value: change.value)
                    }
                }

            case .bootOnLidOpen:
                // The ownership check runs before any write: a value changed
                // elsewhere wins, and the lease stays put for the report.
                switch BootPreferencePolicy.restorePlan(
                    previous: entry.previous,
                    written: entry.written,
                    current: readBootPreference()
                ) {
                case .refuse(let message):
                    return RestoreOutcome(ok: false, message: message)
                case .delete:
                    try applyBootPreference(BootPreferencePolicy.absentToken)
                case .write(let token):
                    try applyBootPreference(token)
                }

            case .fanPercent:
                try restoreFan(entry)

            default:
                return RestoreOutcome(
                    ok: false,
                    message: "operation '\(entry.operation)' is not restorable"
                )
            }
        } catch {
            return RestoreOutcome(ok: false, message: error.localizedDescription)
        }

        return RestoreOutcome(ok: true, message: "restored")
    }

    private static func booleanToken(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes": return true
        case "0", "false", "no": return false
        default: return nil
        }
    }

    // MARK: - Owned wake events

    /// `dateValue` and its formatted text are validated inside the scheduler
    /// before the ownership record is written or pmset runs. A failure removes
    /// the record it wrote (best effort), so no entry ever claims an event that
    /// was not created.
    private static func scheduleOwnedWake(_ request: HelperRequest, componentID: String,
                                          journal: RequestJournal) -> HelperReply {
        if let refusal = markRunning(journal, request, "schedule a wake") {
            return refusal
        }
        return wakeReply(request, wakeScheduler.schedule(dateValue: request.dateValue,
                                                         createdBy: componentID))
    }

    private static func cancelOwnedWake(_ request: HelperRequest,
                                        journal: RequestJournal) -> HelperReply {
        if let refusal = markRunning(journal, request, "cancel a wake") {
            return refusal
        }
        return wakeReply(request, wakeScheduler.cancel(dateValue: request.dateValue))
    }

    /// Read-only: no journal record and no store write. `wakeSchedules` is a
    /// query, not a mutation, so it must not consume a request UUID or take the
    /// mutation lock.
    private static func wakeSchedulesReply(for request: HelperRequest) -> HelperReply {
        wakeReply(request, wakeScheduler.list())
    }

    private static func wakeReply(_ request: HelperRequest, _ outcome: WakeOutcome) -> HelperReply {
        HelperReply(id: request.id, ok: outcome.ok,
                    message: outcome.message, details: outcome.details)
    }

    // MARK: - Parser helpers

    private static func trailingInteger(_ text: String) -> Int? {
        let tokens = text.split(whereSeparator: {
            $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
        })
        guard let last = tokens.last else { return nil }
        return Int(last)
    }

    /// Finds a `key value` line (pmset's `-g custom` layout) and returns the
    /// integer on that line.
    private static func settingInteger(in text: String, key: String) -> Int? {
        for line in text.split(separator: "\n") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 2, tokens[0].lowercased() == key.lowercased() else { continue }
            if let value = Int(tokens[tokens.count - 1]) {
                return value
            }
        }
        return nil
    }


}

// MARK: - Command execution

private struct OperationError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let launchError: String?

    var succeeded: Bool {
        launchError == nil && !timedOut && status == 0
    }

    /// Adapter for `WakeScheduler`, so wake commands use this same runner and
    /// the same five-second deadline as every other operation.
    var wakeCommandResult: WakeCommandResult {
        WakeCommandResult(status: status, stdout: stdout, stderr: stderr,
                          timedOut: timedOut, launchError: launchError)
    }

    var summary: String {
        if let launchError { return launchError }
        if timedOut { return "timed out after \(Int(Command.deadline)) seconds" }

        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty && !err.isEmpty { return "\(out) (\(err))" }
        if !out.isEmpty { return out }
        if !err.isEmpty { return err }
        return "exit status \(status)"
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private enum Command {
    /// Hard deadline for one external command. Operations may run several
    /// commands, but none of them can hang forever.
    static let deadline: TimeInterval = 5

    static func run(_ executable: String, _ arguments: [String]) -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return CommandResult(
                status: -1,
                stdout: "",
                stderr: "",
                timedOut: false,
                launchError: "\(executable) is not available"
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(
                status: -1,
                stdout: "",
                stderr: "",
                timedOut: false,
                launchError: "could not launch \(executable): \(error.localizedDescription)"
            )
        }

        // The child has its own descriptors now. Closing the parent's write
        // ends lets the reader threads see EOF when the child exits.
        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readers = DispatchGroup()

        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + deadline) == .timedOut {
            timedOut = true
            if process.isRunning {
                process.terminate()
            }
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                _ = exited.wait(timeout: .now() + 0.5)
            }
        }

        // After a normal exit or a kill the pipes reach EOF quickly. Do not
        // wait forever for an escaped grandchild holding a descriptor.
        _ = readers.wait(timeout: .now() + 1)

        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return CommandResult(
            status: status,
            stdout: String(decoding: stdoutBox.value, as: UTF8.self),
            stderr: String(decoding: stderrBox.value, as: UTF8.self),
            timedOut: timedOut,
            launchError: nil
        )
    }
}
