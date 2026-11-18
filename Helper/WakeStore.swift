// WakeStore — the helper's ownership record for one-off wake events.
//
// `pmset` keeps one machine-wide schedule. It offers no per-installation
// namespace and `pmset -g sched` lines do not carry a token this helper
// controls: the OSS argv is only the date. Ownership therefore lives here, in
// a root-only record next to the backup store, and every cancellation is
// matched against it. A scheduled event is "ours" only when an entry with kind
// `wake` and the same instant (within 1 s) is present. Nothing here cancels by
// date alone and `cancelall` is never used.
//
// The file is 0600 in a 0700 directory, written atomically (sibling temporary
// file + rename), and refuses to read through a symlink or a non-regular file,
// mirroring BackupStore. There is no fsync; see the residual-risk note in the
// M6a report.
//
// This file also holds the pure, injectable pieces the tests use:
//  * PmsetSchedule — the one fixed local date format, a strict parser for
//    `pmset -g sched`, and presence matching by kind + instant.
//  * WakeSchedulePolicy — the closed date bounds (finite, >= 30 s ahead, and
//    within 30 days), including a format round-trip check.
//  * WakeScheduler — schedule/cancel/list orchestration with an injected clock
//    and command runner. No test ever executes pmset.

import Darwin
import Foundation

/// The closed allowlist of scheduled-event kinds this helper may own. An
/// unknown kind in the record is an error, never a guess: guessing could let a
/// cancel match something this helper did not create.
enum WakeKind: String, Codable, CaseIterable, Sendable {
    case wake
}

/// One owned wake. `at` is always Unix epoch seconds; the human-readable
/// `MM/dd/yy HH:mm:ss` text is derived only at the pmset boundary.
struct WakeEntry: Codable, Sendable, Equatable {
    var id: UUID
    var at: Double
    var kind: WakeKind
    var createdBy: String
}

struct WakeStore {
    static let defaultDirectoryPath = "/Library/Application Support/dev.wakely.helper"
    static let fileName = "wakes.json"

    /// Past events older than this are pruned on the next write. A one-off
    /// event whose instant is a week in the past cannot still be pending: it
    /// either fired or was canceled. Future entries — and past entries that are
    /// still within the window, whose presence has not been checked yet — are
    /// never pruned.
    static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Reject absurd timestamps. pmset's input format is 2-digit-year, and the
    /// scheduling policy only accepts the next 30 days; this bound only keeps
    /// a corrupt record from claiming a date outside the supported calendar.
    static let maximumEpoch: Double = 4_102_444_800  // 2100-01-01

    let directoryPath: String

    var filePath: String { directoryPath + "/" + Self.fileName }

    init(directoryPath: String = WakeStore.defaultDirectoryPath) {
        self.directoryPath = directoryPath
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

    // The daemon serializes mutations, but `wakeSchedules` is read-only and may
    // run concurrently with a schedule/cancel write. One process-wide lock
    // keeps the record coherent.
    private static let lock = NSLock()

    // MARK: - Public API

    /// Every stored entry. A missing store is empty, not an error. A malformed
    /// or unreadable store is an error: guessing would lose an ownership claim
    /// and make a later cancel unsafe.
    func load() throws -> [WakeEntry] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try loadUnlocked()
    }

    /// Same as `load()`, named for callers that only want to inspect.
    func list() throws -> [WakeEntry] {
        try load()
    }

    /// Insert or replace one entry, pruning expired entries first. Persisting
    /// must succeed before any external command runs, so a schedule that fails
    /// here leaves no event and no claim.
    @discardableResult
    func save(_ entry: WakeEntry, now: Date = Date()) throws -> WakeEntry {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        if let problem = Self.validate(entry) {
            throw StoreError.unwritable("Refusing to save an invalid wake record: \(problem)")
        }

        var entries = Self.retained(try loadUnlocked(), now: now.timeIntervalSince1970)
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        try writeUnlocked(entries)
        return entry
    }

    /// Remove one entry by its identity. Returns false when it was already
    /// gone. The caller removes the claim only after the event itself is known
    /// to be absent or canceled.
    @discardableResult
    func remove(id: UUID) throws -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        var entries = try loadUnlocked()
        let before = entries.count
        entries.removeAll { $0.id == id }
        guard entries.count != before else { return false }
        try writeUnlocked(entries)
        return true
    }

    /// The entry that owns this instant, if any. A cancel request must match
    /// within one second; anything else is someone else's event.
    func owned(at epoch: Double, kind: WakeKind = .wake,
               tolerance: TimeInterval = 1) throws -> WakeEntry? {
        try load().first {
            $0.kind == kind && abs($0.at - epoch) <= tolerance
        }
    }

    /// Prune expired entries and persist the result. Returns how many entries
    /// were removed. This is the only place retention writes; `load()` and
    /// `wakeSchedules` never mutate.
    @discardableResult
    func prune(now: Date = Date()) throws -> Int {
        Self.lock.lock()
        defer { Self.lock.unlock() }

        let entries = try loadUnlocked()
        let kept = Self.retained(entries, now: now.timeIntervalSince1970)
        guard kept.count != entries.count else { return 0 }
        try writeUnlocked(kept)
        return entries.count - kept.count
    }

    // MARK: - Retention

    /// Pure retention decision: keep future entries and past entries that are
    /// still inside the window; drop only events whose instant is older than
    /// `retentionInterval`.
    static func retained(_ entries: [WakeEntry], now: Double) -> [WakeEntry] {
        guard now.isFinite else { return entries }
        let cutoff = now - retentionInterval
        return entries.filter { $0.at >= cutoff }
    }

    // MARK: - Validation

    /// A stored record must name exactly one supported kind, one finite instant
    /// inside the supported calendar, and a bounded, printable owner. Returns
    /// nil when valid.
    static func validate(_ entry: WakeEntry) -> String? {
        guard entry.at.isFinite else {
            return "wake \(entry.id.uuidString) has a non-finite time"
        }
        guard entry.at >= 0, entry.at < maximumEpoch else {
            return "wake \(entry.id.uuidString) is outside the supported calendar range"
        }
        guard !entry.createdBy.isEmpty, entry.createdBy.count <= 128 else {
            return "wake \(entry.id.uuidString) has an empty or oversized owner"
        }
        guard entry.createdBy == entry.createdBy.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "wake \(entry.id.uuidString) has an owner with surrounding whitespace"
        }
        guard !entry.createdBy.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return "wake \(entry.id.uuidString) has an owner with control characters"
        }
        return nil
    }

    // MARK: - Disk

    private func loadUnlocked() throws -> [WakeEntry] {
        let path = filePath
        let fileManager = FileManager.default

        // The containing path exists but is not a directory: the record cannot
        // be trusted (and a previous write may have been replaced), so refuse
        // rather than report "no owned wakes".
        var directoryIsDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directoryPath, isDirectory: &directoryIsDirectory),
           !directoryIsDirectory.boolValue {
            throw StoreError.unreadable("\(directoryPath) is not a directory; refusing to read the wake record.")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return []
        }
        guard !isDirectory.boolValue else {
            throw StoreError.unreadable("\(path) is a directory, not a wake record.")
        }

        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
           values.isRegularFile != true || values.isSymbolicLink == true {
            throw StoreError.unreadable("\(path) is not a regular file; refusing to read it.")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable("Could not read \(path): \(error.localizedDescription)")
        }
        guard !data.isEmpty else { return [] }

        let entries: [WakeEntry]
        do {
            entries = try JSONDecoder().decode([WakeEntry].self, from: data)
        } catch {
            throw StoreError.unreadable("Could not parse \(path): \(error.localizedDescription)")
        }

        // A duplicate identity makes removal and ownership ambiguous; treat the
        // whole record as unusable rather than dropping one copy silently.
        guard Set(entries.map(\.id)).count == entries.count else {
            throw StoreError.unreadable("\(path) contains duplicate wake identities; refusing to guess which entry owns an event.")
        }
        for entry in entries {
            if let problem = Self.validate(entry) {
                throw StoreError.unreadable("\(path) contains an invalid record: \(problem)")
            }
        }
        return entries
    }

    private func writeUnlocked(_ entries: [WakeEntry]) throws {
        try ensureDirectoryUnlocked()

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(entries)
        } catch {
            throw StoreError.unwritable("Could not encode the wake record: \(error.localizedDescription)")
        }

        // Write a sibling temporary file with the final permissions, then
        // rename it over the destination: rename(2) is atomic on one volume and
        // the 0600 mode is in place before the file has its real name.
        let temporaryPath = directoryPath + "/.wakes.json.\(UUID().uuidString).tmp"
        guard FileManager.default.createFile(
            atPath: temporaryPath,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw StoreError.unwritable("Could not create a temporary wake record in \(directoryPath).")
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

    private func ensureDirectoryUnlocked() throws {
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
}

// MARK: - pmset schedule format and parser

/// The one date format pmset accepts and prints, plus a strict parser.
///
/// Scheduling writes `MM/dd/yy HH:mm:ss` in local time with an `en_US_POSIX`
/// formatter. Reading accepts two- or four-digit years because `pmset -g sched`
/// has been observed to print `11/11/2026` while its input syntax documents
/// `MM/dd/yy`; the instant, not the spelling, is what presence matching uses.
enum PmsetSchedule {
    static let inputFormat = "MM/dd/yy HH:mm:ss"
    static let readingFormat = "MM/dd/yyyy HH:mm:ss"

    /// The scheduled-event kinds pmset prints. Unknown kinds are ignored rather
    /// than treated as a wake.
    static let eventKinds: Set<String> = [
        "wake", "sleep", "poweron", "wakeorpoweron", "shutdown", "restart",
    ]

    struct Event: Equatable, Sendable {
        var kind: String
        var at: Double
        var dateText: String
        var owner: String?
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    /// The date text for one instant, in the fixed local format. `""` means the
    /// instant cannot be represented (non-finite or outside the calendar this
    /// helper accepts).
    static func format(_ epoch: Double) -> String {
        guard epoch.isFinite, epoch >= 0, epoch < WakeStore.maximumEpoch else { return "" }
        return formatter(inputFormat).string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Strictly parse `MM/dd/yy[yy] HH:mm:ss` in local time. The parsed value is
    /// formatted again and compared with the canonical input, so impossible
    /// dates and DST gaps are rejected instead of silently normalized.
    static func parseDate(_ text: String) -> Double? {
        guard let canonical = canonicalText(text) else { return nil }
        let formatter = formatter(readingFormat)
        guard let date = formatter.date(from: canonical),
              formatter.string(from: date) == canonical else { return nil }
        let epoch = date.timeIntervalSince1970
        return epoch.isFinite ? epoch : nil
    }

    /// Normalize a printed date to `MM/dd/yyyy HH:mm:ss`, or nil when the text is
    /// not exactly a two- or four-digit-year pmset date. This is the
    /// "does it round-trip?" check: the caller can require that
    /// `parseDate`/`format` agree rather than trusting a lenient parse.
    static func canonicalText(_ text: String) -> String? {
        let fields = text.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 2, !text.contains("\t") else { return nil }
        let dateFields = fields[0].split(separator: "/", omittingEmptySubsequences: false)
        let timeFields = fields[1].split(separator: ":", omittingEmptySubsequences: false)
        guard dateFields.count == 3, timeFields.count == 3 else { return nil }

        let yearText = String(dateFields[2])
        guard yearText.count == 2 || yearText.count == 4,
              let month = exactInteger(dateFields[0], digits: 2),
              let day = exactInteger(dateFields[1], digits: 2),
              let yearValue = exactInteger(dateFields[2], digits: yearText.count),
              let hour = exactInteger(timeFields[0], digits: 2),
              let minute = exactInteger(timeFields[1], digits: 2),
              let second = exactInteger(timeFields[2], digits: 2) else { return nil }

        // A two-digit year can only mean this century here: the scheduling
        // policy accepts at most 30 days ahead, and pmset's printed two-digit
        // years are current dates too.
        let year = yearText.count == 2 ? 2000 + yearValue : yearValue
        guard (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute),
              (0...59).contains(second), year >= 1 else { return nil }

        return pad(month, 2) + "/" + pad(day, 2) + "/" + pad(year, 4) + " "
            + pad(hour, 2) + ":" + pad(minute, 2) + ":" + pad(second, 2)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        guard text.count < width else { return text }
        return String(repeating: "0", count: width - text.count) + text
    }

    private static func exactInteger(_ field: Substring, digits: Int) -> Int? {
        guard field.count == digits else { return nil }
        var value = 0
        for scalar in field.unicodeScalars {
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            value = value * 10 + Int(scalar.value - 48)
        }
        return value
    }

    /// Parse `pmset -g sched`. Lines look like:
    ///
    ///     [0]  wake at 11/11/2026 22:25:23 by 'com.apple.alarm...'
    ///
    /// Headers ("Scheduled power events:"), repeating events and any other line
    /// that does not start with an event index are ignored. Duplicate dates are
    /// kept as separate events; presence matching only asks whether at least
    /// one matching event exists.
    static func parse(_ output: String) -> [Event] {
        var events: [Event] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            line = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            let tokens = line.split(omittingEmptySubsequences: true,
                                    whereSeparator: { $0 == " " || $0 == "\t" })
            guard tokens.count >= 4, tokens[1] == "at" else { continue }

            let kind = String(tokens[0]).lowercased()
            guard eventKinds.contains(kind) else { continue }

            let dateText = String(tokens[2]) + " " + String(tokens[3])
            guard let at = parseDate(dateText) else { continue }

            var owner: String?
            if tokens.count >= 6, tokens[4] == "by" {
                var quoted = tokens[5...].joined(separator: " ")
                if quoted.count >= 2, quoted.hasPrefix("'"), quoted.hasSuffix("'") {
                    quoted = String(quoted.dropFirst().dropLast())
                }
                owner = quoted
            }
            events.append(Event(kind: kind, at: at, dateText: dateText, owner: owner))
        }
        return events
    }

    /// True when a parsed schedule contains this kind at this instant (±1 s).
    static func contains(_ events: [Event], kind: String = "wake",
                         at epoch: Double, tolerance: TimeInterval = 1) -> Bool {
        events.contains {
            $0.kind == kind.lowercased() && abs($0.at - epoch) <= tolerance
        }
    }
}

// MARK: - Date policy

/// Pure scheduling bounds. Every rejection happens before the ownership record
/// is written and before pmset is run.
enum WakeSchedulePolicy {
    static let minimumLead: TimeInterval = 30
    static let maximumHorizon: TimeInterval = 30 * 24 * 60 * 60

    enum Decision: Equatable {
        case accepted(text: String, at: Double)
        case rejected(String)
    }

    static func plan(dateValue: Double?, now: Double) -> Decision {
        guard now.isFinite else {
            return .rejected("The helper clock is not usable; no wake was scheduled.")
        }
        guard let epoch = dateValue, epoch.isFinite else {
            return .rejected("scheduleWake requires a finite Unix timestamp; no wake was scheduled.")
        }
        guard epoch >= 0, epoch < WakeStore.maximumEpoch else {
            return .rejected("The requested wake time is outside the supported calendar range; no wake was scheduled.")
        }

        let lead = epoch - now
        guard lead >= minimumLead else {
            return .rejected("A wake must be at least 30 seconds in the future; no wake was scheduled.")
        }
        guard lead <= maximumHorizon else {
            return .rejected("A wake must be within 30 days; no wake was scheduled.")
        }

        let text = PmsetSchedule.format(epoch)
        guard !text.isEmpty,
              let parsed = PmsetSchedule.parseDate(text),
              abs(parsed - epoch) < 1 else {
            return .rejected("The requested wake time does not survive pmset's local MM/dd/yy HH:mm:ss format (timezone or DST edge); no wake was scheduled.")
        }
        return .accepted(text: text, at: epoch)
    }
}

// MARK: - Command injection

/// The slice of a command result the wake scheduler needs. Operations maps its
/// existing 5 s-deadline `Command.run` into this shape; tests supply their own.
struct WakeCommandResult: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var launchError: String?

    var succeeded: Bool {
        launchError == nil && !timedOut && status == 0
    }

    var summary: String {
        if let launchError { return launchError }
        if timedOut { return "timed out after \(Int(WakeScheduler.commandDeadline)) seconds" }
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty && !err.isEmpty { return "\(out) (\(err))" }
        if !out.isEmpty { return out }
        if !err.isEmpty { return err }
        return "exit status \(status)"
    }
}

struct WakeOutcome: Sendable, Equatable {
    var ok: Bool
    var message: String
    var details: [String: String]

    init(ok: Bool, message: String, details: [String: String] = [:]) {
        self.ok = ok
        self.message = message
        self.details = details
    }

    static func failure(_ message: String) -> WakeOutcome {
        WakeOutcome(ok: false, message: message)
    }
}

// MARK: - Owned schedule / cancel / list

/// Orchestrates the two fixed pmset subcommands and the ownership record.
///
/// Security posture: the executable and every argument are constants here. The
/// only peer-influenced value is an instant that has already been validated
/// and formatted into `MM/dd/yy HH:mm:ss`; it never becomes a shell word, path,
/// environment entry or format string.
struct WakeScheduler {
    static let pmsetPath = "/usr/bin/pmset"
    static let commandDeadline: TimeInterval = 5

    let store: WakeStore
    let now: () -> Double
    let run: (String, [String]) -> WakeCommandResult

    init(store: WakeStore = WakeStore(),
         now: @escaping () -> Double = { Date().timeIntervalSince1970 },
         run: @escaping (String, [String]) -> WakeCommandResult = WakeScheduler.runSystemCommand) {
        self.store = store
        self.now = now
        self.run = run
    }

    /// Fixed argv for creating one wake. No owner token is passed: pmset's
    /// owner argument is not part of this OSS contract, so ownership is tracked
    /// in `WakeStore` and verified by date + kind.
    static func scheduleArguments(_ text: String) -> [String] {
        ["schedule", "wake", text]
    }

    /// Fixed argv for cancelling one wake. It names a single date; `cancelall`
    /// is never generated.
    static func cancelArguments(_ text: String) -> [String] {
        ["schedule", "cancel", "wake", text]
    }

    static let scheduleListArguments = ["-g", "sched"]

    // MARK: Mutations

    func schedule(dateValue: Double?, createdBy: String) -> WakeOutcome {
        let text: String
        let epoch: Double
        switch WakeSchedulePolicy.plan(dateValue: dateValue, now: now()) {
        case .rejected(let message):
            return .failure(message)
        case .accepted(let acceptedText, let acceptedEpoch):
            text = acceptedText
            epoch = acceptedEpoch
        }

        let entry = WakeEntry(id: UUID(), at: epoch, kind: .wake, createdBy: createdBy)
        do {
            try store.save(entry)
        } catch {
            return .failure("Refusing to schedule a wake without recording which event this helper owns: "
                + "\(error.localizedDescription). pmset was not run.")
        }

        let created = run(Self.pmsetPath, Self.scheduleArguments(text))
        guard created.succeeded else {
            return failureAfterDiscarding(
                entry,
                message: "pmset could not schedule the wake at \(text): \(created.summary)."
            )
        }

        // A zero exit is not a scheduled event. Read the machine-wide schedule
        // back and require exactly this date and kind before claiming success.
        let listing = run(Self.pmsetPath, Self.scheduleListArguments)
        guard listing.succeeded else {
            return failureAfterDiscarding(
                entry,
                message: "pmset returned success for the wake at \(text), but its schedule could not be read back "
                    + "(\(listing.summary)); the wake was not verified and is not reported as scheduled."
            )
        }
        guard PmsetSchedule.contains(PmsetSchedule.parse(listing.stdout), kind: "wake", at: epoch) else {
            return failureAfterDiscarding(
                entry,
                message: "pmset returned success for the wake at \(text), but no wake at that time appears in "
                    + "`pmset -g sched`; the wake was not verified and is not reported as scheduled."
            )
        }

        return WakeOutcome(
            ok: true,
            message: "Scheduled an owned wake at \(text).",
            details: [
                "id": entry.id.uuidString,
                "at": text,
                "epoch": String(epoch),
                "kind": entry.kind.rawValue,
                "createdBy": entry.createdBy,
            ]
        )
    }

    func cancel(dateValue: Double?) -> WakeOutcome {
        guard let epoch = dateValue, epoch.isFinite else {
            return .failure("cancelWake requires a finite Unix timestamp; no event was canceled.")
        }

        let owned: WakeEntry
        do {
            guard let match = try store.owned(at: epoch) else {
                return .failure("Refusing to cancel a wake at \(PmsetSchedule.format(epoch)): this helper owns no "
                    + "wake matching that time within 1 second. No event was canceled.")
            }
            owned = match
        } catch {
            return .failure("Could not read the wake ownership record: \(error.localizedDescription). No event was canceled.")
        }

        // The stored instant must survive the same formatting the schedule used,
        // or a cancel could name a different second than the event we own.
        let text = PmsetSchedule.format(owned.at)
        guard !text.isEmpty, let roundTrip = PmsetSchedule.parseDate(text), abs(roundTrip - owned.at) < 1 else {
            return .failure("The owned wake's saved time does not survive pmset's local date format; "
                + "refusing to cancel a possibly different event. The ownership record is retained.")
        }

        let before = run(Self.pmsetPath, Self.scheduleListArguments)
        guard before.succeeded else {
            return .failure("Could not read `pmset -g sched` to check the owned wake at \(text) "
                + "(\(before.summary)). The ownership record is retained.")
        }
        if !PmsetSchedule.contains(PmsetSchedule.parse(before.stdout), kind: "wake", at: owned.at) {
            // A fired or externally canceled owned event needs no cancellation.
            // This is satisfaction, not failure.
            return finishCancellation(owned,
                message: "The owned wake at \(text) was already absent from `pmset -g sched`; the ownership record was removed.")
        }

        let cancelled = run(Self.pmsetPath, Self.cancelArguments(text))
        guard cancelled.succeeded else {
            return .failure("pmset could not cancel the owned wake at \(text): \(cancelled.summary). "
                + "The ownership record is retained.")
        }

        let after = run(Self.pmsetPath, Self.scheduleListArguments)
        guard after.succeeded else {
            return .failure("pmset canceled the wake at \(text), but its schedule could not be re-read "
                + "(\(after.summary)); the cancellation was not verified. The ownership record is retained.")
        }
        guard !PmsetSchedule.contains(PmsetSchedule.parse(after.stdout), kind: "wake", at: owned.at) else {
            return .failure("pmset reported success, but the owned wake at \(text) is still listed in "
                + "`pmset -g sched`. The ownership record is retained.")
        }

        return finishCancellation(owned, message: "Canceled the owned wake at \(text).")
    }

    // MARK: Read-only listing

    /// Read-only: reports every owned entry and whether its event is present.
    /// It never writes the store, so it is safe outside the mutation lock. If
    /// `pmset -g sched` cannot be read, presence is `unknown`, never a guess.
    func list() -> WakeOutcome {
        let stored: [WakeEntry]
        do {
            stored = try store.load()
        } catch {
            return .failure("Could not read the wake ownership record: \(error.localizedDescription)")
        }
        let entries = WakeStore.retained(stored, now: now())

        let listing = run(Self.pmsetPath, Self.scheduleListArguments)
        let events = listing.succeeded ? PmsetSchedule.parse(listing.stdout) : []

        var details: [String: String] = ["count": String(entries.count)]
        for entry in entries {
            let key = "wake.\(entry.id.uuidString)"
            details["\(key).at"] = PmsetSchedule.format(entry.at)
            details["\(key).epoch"] = String(entry.at)
            details["\(key).kind"] = entry.kind.rawValue
            details["\(key).createdBy"] = entry.createdBy
            details["\(key).present"] = listing.succeeded
                ? (PmsetSchedule.contains(events, kind: entry.kind.rawValue, at: entry.at) ? "yes" : "no")
                : "unknown"
        }

        if !listing.succeeded {
            details["probe"] = "failed"
            details["probe.message"] = listing.summary
            return WakeOutcome(
                ok: false,
                message: "Could not read `pmset -g sched` (\(listing.summary)); "
                    + "owned wake presence is unknown.",
                details: details
            )
        }

        return WakeOutcome(
            ok: true,
            message: "\(entries.count) owned wake\(entries.count == 1 ? "" : "s").",
            details: details
        )
    }

    /// Ownership probe: does this instant have an owned wake? A future
    /// journal/recovery path can use this to distinguish a discarded claim from
    /// a retained one. The command journal's BackupStore lease probe is
    /// deliberately not used for wakes because no BackupStore entry exists.
    func owns(at epoch: Double?) -> Bool {
        guard let epoch, epoch.isFinite else { return false }
        do {
            return try store.owned(at: epoch) != nil
        } catch {
            return true
        }
    }

    // MARK: Helpers

    private func finishCancellation(_ entry: WakeEntry, message: String) -> WakeOutcome {
        do {
            _ = try store.remove(id: entry.id)
            return WakeOutcome(ok: true, message: message)
        } catch {
            return .failure(message + " The ownership record could not be removed "
                + "(\(error.localizedDescription)); query wakeSchedules before retrying.")
        }
    }

    private func failureAfterDiscarding(_ entry: WakeEntry, message: String) -> WakeOutcome {
        do {
            _ = try store.remove(id: entry.id)
            return .failure(message + " The ownership record was removed, so no event is claimed.")
        } catch {
            return .failure(message + " The ownership record could not be removed "
                + "(\(error.localizedDescription)); query wakeSchedules before retrying.")
        }
    }

    // MARK: Default runner

    /// Fallback runner used only when no caller injects one. Operations always
    /// passes its existing 5 s-deadline `Command.run`, so the helper has a
    /// single production execution path; this default keeps the type usable on
    /// its own without reaching into Operations.
    static func runSystemCommand(_ executable: String, _ arguments: [String]) -> WakeCommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return WakeCommandResult(status: -1, stdout: "", stderr: "", timedOut: false,
                                     launchError: "\(executable) is not available")
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
            return WakeCommandResult(status: -1, stdout: "", stderr: "", timedOut: false,
                                     launchError: "could not launch \(executable): \(error.localizedDescription)")
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let stdoutBox = WakeDataBox()
        let stderrBox = WakeDataBox()
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
        if exited.wait(timeout: .now() + commandDeadline) == .timedOut {
            timedOut = true
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                _ = exited.wait(timeout: .now() + 0.5)
            }
        }

        // An escaped grandchild holding a descriptor must not wedge the
        // scheduler; the pipes are drained by the readers above.
        _ = readers.wait(timeout: .now() + 1)

        let stdout = String(decoding: stdoutBox.value, as: UTF8.self)
        let stderr = String(decoding: stderrBox.value, as: UTF8.self)
        let status: Int32 = process.isRunning ? -1 : process.terminationStatus
        return WakeCommandResult(status: status, stdout: stdout, stderr: stderr,
                                 timedOut: timedOut, launchError: nil)
    }
}

private final class WakeDataBox: @unchecked Sendable {
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
