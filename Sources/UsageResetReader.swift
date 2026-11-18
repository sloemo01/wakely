// UsageResetReader — bounded, metadata-only discovery of account usage resets.
//
// Sleep Until Reset needs one fact: when a limited account becomes usable
// again. There is no supported network API and this app never holds provider
// credentials, so the reader inspects only the tail of the local session
// transcripts that Claude Code and Codex already write:
//
//   ~/.claude/projects/**/*.jsonl   (Claude Code)
//   ~/.codex/sessions/**/*.jsonl   (Codex)
//
// Every bound here is deliberately small and closed:
//  * 256 KiB tail per file, at most 48 files per root, 2048 records per file.
//  * Files larger than 64 MiB are ignored outright.
//  * The roots and every directory component must be real directories and the
//    transcript must be a regular file opened with O_NOFOLLOW: a symlink is
//    refused, never followed.
//  * Only the reset instant and a bounded account label are read. Message
//    text, prompts, responses, paths and credentials are never stored, logged
//    or returned: parsing discards everything except the extracted values.
//
// A missing root, an unreadable file or a malformed line is skipped. Absence of
// data is reported as an empty array; the controller treats that as "stay
// inert", never as "nothing is scheduled".

import Darwin
import Foundation

struct UsageLimitReset: Equatable, Sendable {
    enum Provider: String, Equatable, Sendable {
        case claude
        case codex
    }

    let provider: Provider
    /// Bounded, sanitized account label when the record exposed one. Never a
    /// path, email body, prompt or transcript text.
    let account: String?
    let resetsAt: Date

    init(provider: Provider, account: String? = nil, resetsAt: Date) {
        self.provider = provider
        self.account = account
        self.resetsAt = resetsAt
    }
}

struct UsageResetReader: Sendable {
    struct Roots: Equatable, Sendable {
        var claudeProjects: URL?
        var codexSessions: URL?

        init(claudeProjects: URL?, codexSessions: URL?) {
            self.claudeProjects = claudeProjects
            self.codexSessions = codexSessions
        }

        /// The documented Claude Code and Codex locations under one home
        /// directory. Callers may pass a temporary home in tests.
        static func live(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Roots {
            Roots(
                claudeProjects: home.appendingPathComponent(".claude/projects", isDirectory: true),
                codexSessions: home.appendingPathComponent(".codex/sessions", isDirectory: true)
            )
        }
    }

    /// Only the newest 256 KiB of a transcript can describe the next reset.
    static let maximumTailBytes = 256 * 1024
    /// A pathological file is skipped instead of being read at all.
    static let maximumFileBytes = 64 * 1024 * 1024
    static let maximumFilesPerRoot = 48
    /// Hard bound on directory entries visited, so one huge tree cannot stall
    /// a wake.
    static let maximumScannedFilesPerRoot = 4096
    static let maximumRecordsPerFile = 2048
    /// Two reports of the same provider/account instant within this window are
    /// one reset (providers republish the same limit many times).
    static let dedupeWindow: TimeInterval = 60
    /// Supported calendar window for an extracted instant.
    static let minimumEpoch: Double = 946_684_800   // 2000-01-01
    static let maximumEpoch: Double = 4_102_444_800 // 2100-01-01
    /// A single JSONL record larger than this is ignored.
    static let maximumRecordBytes = 1 * 1024 * 1024

    let roots: Roots
    let now: @Sendable () -> Date

    init(roots: Roots, now: @escaping @Sendable () -> Date = { Date() }) {
        self.roots = roots
        self.now = now
    }

    /// Read both providers and return future, deduplicated resets. Never
    /// touches the network, a credential or a command.
    func read() -> [UsageLimitReset] {
        let instant = now()
        guard instant.timeIntervalSince1970.isFinite else { return [] }

        var found: [UsageLimitReset] = []
        if let root = roots.claudeProjects {
            for file in Self.candidateFiles(under: root) {
                guard let tail = Self.readTail(file) else { continue }
                let lines = Self.records(in: tail.data,
                                         truncated: tail.truncated,
                                         maximum: Self.maximumRecordsPerFile)
                found.append(contentsOf: UsageResetRecordParser.claudeRecords(lines, now: instant))
            }
        }
        if let root = roots.codexSessions {
            for file in Self.candidateFiles(under: root) {
                guard let tail = Self.readTail(file) else { continue }
                let lines = Self.records(in: tail.data,
                                         truncated: tail.truncated,
                                         maximum: Self.maximumRecordsPerFile)
                found.append(contentsOf: UsageResetRecordParser.codexRecords(lines, now: instant))
            }
        }
        return UsageResetDedupe.dedupe(found, now: instant)
    }

    // MARK: - Bounded file access

    /// Real directories only: a root that is a symlink is refused rather than
    /// followed, and a symlinked child is skipped without descending.
    static func candidateFiles(under root: URL) -> [URL] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }
        if let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey]),
           rootValues.isSymbolicLink == true {
            return []
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var candidates: [(url: URL, modified: Date)] = []
        var scanned = 0
        for case let url as URL in enumerator {
            scanned += 1
            if scanned > maximumScannedFilesPerRoot { break }

            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                if values?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values?.isDirectory == true { continue }
            guard url.pathExtension.lowercased() == "jsonl",
                  values?.isRegularFile == true else { continue }
            if let size = values?.fileSize,
               size <= 0 || size > maximumFileBytes {
                continue
            }
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }

        // Newest first: the next reset is almost always in the active session.
        candidates.sort { $0.modified > $1.modified }
        return candidates.prefix(maximumFilesPerRoot).map(\.url)
    }

    /// Read at most `maximumTailBytes` from the end of a regular file.
    /// `O_NOFOLLOW` makes the symlink refusal atomic with the open rather than
    /// a separate check that could race.
    static func readTail(_ url: URL) -> (data: Data, truncated: Bool)? {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let size = Int(info.st_size)
        guard size > 0, size <= maximumFileBytes else { return nil }

        let start = max(0, size - maximumTailBytes)
        guard lseek(descriptor, off_t(start), SEEK_SET) >= 0 else { return nil }

        var data = Data()
        data.reserveCapacity(min(size, maximumTailBytes))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count < maximumTailBytes {
            let wanted = min(buffer.count, maximumTailBytes - data.count)
            let readBytes = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(descriptor, pointer.baseAddress, wanted)
            }
            if readBytes < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if readBytes == 0 { break }
            data.append(contentsOf: buffer[0..<readBytes])
        }
        return (data, start > 0)
    }

    /// Split JSONL data into records, dropping the partial first line of a
    /// truncated tail and keeping at most the newest `maximum` records.
    static func records(in data: Data, truncated: Bool, maximum: Int) -> [Data] {
        guard !data.isEmpty, maximum > 0 else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if truncated, !lines.isEmpty { lines.removeFirst() }
        if lines.count > maximum { lines = Array(lines.suffix(maximum)) }
        return lines.map { Data($0) }.filter { !$0.isEmpty }
    }
}

enum UsageResetDedupe {
    /// Future resets only, ordered by instant, with same-provider/account
    /// reports inside `window` collapsed to the first one.
    static func dedupe(_ resets: [UsageLimitReset],
                       now: Date,
                       window: TimeInterval = UsageResetReader.dedupeWindow) -> [UsageLimitReset] {
        let nowEpoch = now.timeIntervalSince1970
        guard nowEpoch.isFinite else { return [] }

        let future = resets
            .filter { reset in
                let epoch = reset.resetsAt.timeIntervalSince1970
                return epoch.isFinite && epoch > nowEpoch
            }
            .sorted { $0.resetsAt < $1.resetsAt }

        // Cluster per provider+account, not per sorted neighbour: two accounts
        // can interleave their reports of the same limit.
        var lastKept: [String: Date] = [:]
        var kept: [UsageLimitReset] = []
        for reset in future {
            let key = "\(reset.provider.rawValue)|\(reset.account ?? "")"
            if let last = lastKept[key],
               reset.resetsAt.timeIntervalSince(last) <= window {
                continue
            }
            lastKept[key] = reset.resetsAt
            kept.append(reset)
        }
        return kept
    }
}

// MARK: - Record patterns

/// The two documented local conventions, parsed into instants only.
enum UsageResetRecordParser {
    /// Claude Code appends transcript JSONL records. Two shapes are recognized:
    ///  * message text containing `usage limit reached|<epoch seconds>` (the
    ///    CLI's own notice), and
    ///  * an error object mentioning `rate_limit` with `resets_at`/`resetsAt`.
    static func claudeRecords(_ lines: [Data], now: Date) -> [UsageLimitReset] {
        var results: [UsageLimitReset] = []
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            let account = accountLabel(in: object)

            if let epoch = claudeUsageLimitEpoch(in: object) {
                results.append(UsageLimitReset(provider: .claude,
                                               account: account,
                                               resetsAt: Date(timeIntervalSince1970: epoch)))
                continue
            }
            if let epoch = claudeRateLimitEpoch(in: object) {
                results.append(UsageLimitReset(provider: .claude,
                                               account: account,
                                               resetsAt: Date(timeIntervalSince1970: epoch)))
            }
        }
        return results.filter { $0.resetsAt.timeIntervalSince1970 > now.timeIntervalSince1970 }
    }

    /// Codex appends `event_msg` records. A `rate_limits` payload, or a
    /// `token_count` payload carrying `rate_limits`, has `primary` and
    /// `secondary` windows with either an absolute `resets_at` (epoch) or
    /// `resets_in_seconds` relative to the record's own timestamp.
    static func codexRecords(_ lines: [Data], now: Date) -> [UsageLimitReset] {
        var results: [UsageLimitReset] = []
        for line in lines {
            guard let object = jsonObject(line) else { continue }
            guard (object["type"] as? String) == "event_msg",
                  let payload = object["payload"] as? [String: Any] else { continue }

            let payloadType = payload["type"] as? String
            let rateLimits: [String: Any]
            switch payloadType {
            case "rate_limits":
                rateLimits = payload
            case "token_count":
                guard let nested = payload["rate_limits"] as? [String: Any] else { continue }
                rateLimits = nested
            default:
                continue
            }

            let recordInstant = dateValue(object["timestamp"])
            let account = accountLabel(in: object)

            for key in ["primary", "secondary"] {
                guard let window = rateLimits[key] as? [String: Any] else { continue }
                var epoch: Double?
                if let absolute = dateValue(window["resets_at"]) ?? dateValue(window["resetsAt"]) {
                    epoch = absolute
                } else if let seconds = secondsValue(window["resets_in_seconds"]),
                          let base = recordInstant {
                    epoch = base + seconds
                }
                guard let epoch, epoch.isFinite,
                      epoch >= UsageResetReader.minimumEpoch,
                      epoch < UsageResetReader.maximumEpoch else { continue }
                results.append(UsageLimitReset(provider: .codex,
                                               account: account,
                                               resetsAt: Date(timeIntervalSince1970: epoch)))
            }
        }
        return results.filter { $0.resetsAt.timeIntervalSince1970 > now.timeIntervalSince1970 }
    }

    // MARK: Claude patterns

    private static let usageLimitPattern = #"(?i)usage limit reached\s*\|\s*(\d{10,19})"#
    private static let usageLimitRegex = try? NSRegularExpression(pattern: usageLimitPattern)

    private static func claudeUsageLimitEpoch(in object: [String: Any]) -> Double? {
        guard let regex = usageLimitRegex else { return nil }
        for text in messageTexts(in: object) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let captured = Range(match.range(at: 1), in: text),
                  let raw = Double(text[captured]) else { continue }
            if let epoch = normalizeEpoch(raw) { return epoch }
        }
        return nil
    }

    /// An error object must actually mention `rate_limit`; the reset instant
    /// then comes from that object or from the record around it.
    private static func claudeRateLimitEpoch(in object: [String: Any]) -> Double? {
        var candidates: [[String: Any]] = []
        if let error = object["error"] as? [String: Any] { candidates.append(error) }
        if let message = object["message"] as? [String: Any],
           let error = message["error"] as? [String: Any] { candidates.append(error) }
        if let nested = object["rate_limit"] as? [String: Any] { candidates.append(nested) }

        for candidate in candidates {
            let type = (candidate["type"] as? String ?? "").lowercased()
            let message = (candidate["message"] as? String ?? "").lowercased()
            guard type.contains("rate_limit") || message.contains("rate_limit")
                    || message.contains("rate limit") else { continue }
            if let epoch = dateValue(candidate["resets_at"]) ?? dateValue(candidate["resetsAt"]) {
                return epoch
            }
        }

        // A record may name the error type at the top level and carry the
        // instant beside it.
        let topType = (object["type"] as? String ?? "").lowercased()
        if topType.contains("rate_limit") {
            return dateValue(object["resets_at"]) ?? dateValue(object["resetsAt"])
        }
        return nil
    }

    /// Every user/assistant text field this reader is willing to look at.
    /// The text is inspected for one regex match and then discarded.
    private static func messageTexts(in object: [String: Any]) -> [String] {
        var texts: [String] = []
        appendTexts(object["content"], into: &texts)
        if let message = object["message"] as? [String: Any] {
            appendTexts(message["content"], into: &texts)
            appendTexts(message["text"], into: &texts)
            if let error = message["error"] as? [String: Any] {
                appendTexts(error["message"], into: &texts)
            }
        }
        if let error = object["error"] as? [String: Any] {
            appendTexts(error["message"], into: &texts)
        }
        return texts
    }

    private static func appendTexts(_ value: Any?, into texts: inout [String]) {
        switch value {
        case let text as String:
            if texts.count < 8 { texts.append(text) }
        case let blocks as [[String: Any]]:
            for block in blocks {
                if let text = block["text"] as? String, texts.count < 8 { texts.append(text) }
                if let nested = block["content"] { appendTexts(nested, into: &texts) }
            }
        case let items as [Any]:
            for item in items { appendTexts(item, into: &texts) }
        default:
            break
        }
    }

    // MARK: Shared value extraction

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty, data.count <= UsageResetReader.maximumRecordBytes else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A bounded account label from recognized keys. Values with control
    /// characters, whitespace padding or an absurd length are dropped.
    private static func accountLabel(in object: [String: Any]) -> String? {
        var containers: [[String: Any]] = [object]
        if let payload = object["payload"] as? [String: Any] { containers.append(payload) }
        for container in containers {
            for key in ["account_id", "accountId", "account"] {
                guard let raw = container[key] as? String,
                      let safe = safeAccount(raw) else { continue }
                return safe
            }
        }
        return nil
    }

    private static func safeAccount(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 128, trimmed == raw else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@+")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    /// Epoch seconds from a JSON number or numeric string. Milliseconds are
    /// normalized; booleans and out-of-calendar values are refused.
    private static func dateValue(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            return normalizeEpoch(number.doubleValue)
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw = Double(trimmed) { return normalizeEpoch(raw) }
            return isoInstant(trimmed)
        }
        return nil
    }

    private static func normalizeEpoch(_ raw: Double) -> Double? {
        guard raw.isFinite, raw >= 0 else { return nil }
        let seconds = raw > 1_000_000_000_000 ? raw / 1000 : raw
        guard seconds.isFinite,
              seconds >= UsageResetReader.minimumEpoch,
              seconds < UsageResetReader.maximumEpoch else { return nil }
        return seconds
    }

    private static func secondsValue(_ value: Any?) -> Double? {
        guard let value, !(value is Bool) else { return nil }
        var seconds: Double?
        if let number = value as? NSNumber { seconds = number.doubleValue }
        if let text = value as? String { seconds = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let seconds, seconds.isFinite, seconds >= 0, seconds <= 31 * 24 * 60 * 60 else { return nil }
        return seconds
    }

    private static func isoInstant(_ text: String) -> Double? {
        guard !text.isEmpty, text.count <= 64 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) {
            return normalizeEpoch(date.timeIntervalSince1970)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) {
            return normalizeEpoch(date.timeIntervalSince1970)
        }
        return nil
    }
}
