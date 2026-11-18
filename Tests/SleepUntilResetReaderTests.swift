// SleepUntilResetReaderTests — fixture-driven reset discovery (M6b).
//
// Every test writes its own temporary directory tree and injects the clock.
// Nothing here reads a real home directory, a credential, the network, a helper
// or a power schedule. Compile with the reader alone:
//
//   xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
//     -module-cache-path build/componentcache \
//     Sources/UsageResetReader.swift Tests/SleepUntilResetReaderTests.swift \
//     -o /tmp/wakely-usage-reset-reader
//   /tmp/wakely-usage-reset-reader

import Foundation

@main
struct SleepUntilResetReaderTests {
    static let now = Date(timeIntervalSince1970: 1_781_000_000)
    static let fileManager = FileManager.default

    static func main() {
        do {
            try claudeEpochMessage()
            try claudeRateLimitError()
            try codexWindows()
            try codexTokenCount()
            try malformedRecords()
            try pastAndDuplicateResets()
            try absentRoots()
            try oversizedFile()
            try symlinksRefused()
            try boundedTail()
            try boundedFileCount()
        } catch {
            fatalError("Sleep Until Reset reader tests failed: \(error)")
        }
        print("Sleep Until Reset reader tests passed (Claude epoch + rate_limit, "
            + "Codex primary/secondary + resets_in_seconds, malformed, past, "
            + "duplicate, absent, oversized, symlink, tail and file bounds)")
    }

    // MARK: - Fixtures

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    /// A fresh temporary home with both provider roots.
    static func makeHome() throws -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("wakely-usage-reset-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @discardableResult
    static func write(_ lines: [String], to file: URL) throws -> URL {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: file)
        return file
    }

    static func projectFile(_ home: URL, _ relative: String) -> URL {
        home.appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(relative)
    }

    static func codexFile(_ home: URL, _ relative: String) -> URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(relative)
    }

    static func read(_ home: URL) -> [UsageLimitReset] {
        UsageResetReader(roots: .live(home: home), now: { now }).read()
    }

    static func claudeLine(epoch: Int, account: String? = nil) -> String {
        let accountField = account.map { ",\"account_id\":\"\($0)\"" } ?? ""
        return "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\","
            + "\"text\":\"Claude AI usage limit reached|\(epoch)\"}]}\(accountField)}"
    }

    // MARK: - Claude

    static func claudeEpochMessage() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }
        let epoch = 1_781_007_200
        try write([claudeLine(epoch: epoch)],
                  to: projectFile(home, "-Users-me/9f3a.jsonl"))

        let resets = read(home)
        require(resets.count == 1, "one epoch message is one reset")
        require(resets[0].provider == .claude, "the provider is Claude")
        require(resets[0].account == nil, "no account field means no account label")
        require(resets[0].resetsAt == Date(timeIntervalSince1970: Double(epoch)),
                "the message epoch is the reset instant")
    }

    static func claudeRateLimitError() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let errorEpoch = 1_781_007_500
        try write([
            "{\"type\":\"assistant\",\"error\":{\"type\":\"rate_limit_error\","
                + "\"message\":\"Rate limit exceeded\",\"resets_at\":\(errorEpoch)}}",
            // The same reset spelled as ISO-8601 on a `resetsAt` key.
            "{\"type\":\"error\",\"account_id\":\"acct-a\",\"error\":{"
                + "\"type\":\"rate_limit_error\",\"message\":\"slow down\","
                + "\"resetsAt\":\"2026-06-09T12:00:00Z\"}}",
            // A rate-limit error with no instant is not a reset.
            "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"no reset\"}}",
            // An unrelated error that merely carries a reset instant is not one.
            "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"busy\",\"resets_at\":1781008000}}",
        ], to: projectFile(home, "a.jsonl"))

        let resets = read(home)
        let errorReset = Date(timeIntervalSince1970: Double(errorEpoch))
        require(resets.contains { $0.resetsAt == errorReset && $0.provider == .claude },
                "rate_limit plus resets_at is a reset")
        require(resets.contains { $0.account == "acct-a" },
                "a bounded account label is retained for dedupe")
        require(!resets.contains { $0.resetsAt == Date(timeIntervalSince1970: 1_781_008_000) },
                "a reset beside an unrelated error is ignored")
        require(resets.count == 2, "only the two recognized rate-limit records produce resets")
    }

    // MARK: - Codex

    static func codexWindows() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let primary = 1_781_001_234
        let secondary = 1_781_002_000
        try write([
            "{\"timestamp\":1781000000,\"type\":\"event_msg\",\"payload\":{"
                + "\"type\":\"rate_limits\",\"account_id\":\"acct-codex\","
                + "\"primary\":{\"resets_at\":\(primary)},\"secondary\":{\"resets_at\":\(secondary)}}}",
        ], to: codexFile(home, "2026/06/09/rollout.jsonl"))

        let resets = read(home)
        require(resets.count == 2, "primary and secondary are two windows")
        require(resets.allSatisfy { $0.provider == .codex }, "the provider is Codex")
        require(resets.allSatisfy { $0.account == "acct-codex" }, "the payload account is retained")
        require(resets.map(\.resetsAt) == [
            Date(timeIntervalSince1970: Double(primary)),
            Date(timeIntervalSince1970: Double(secondary)),
        ], "absolute epoch resets_at values are read")
    }

    static func codexTokenCount() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let base = formatter.date(from: "2026-06-10T00:00:00Z") else {
            fatalError("fixture timestamp did not parse")
        }
        try write([
            "{\"timestamp\":\"2026-06-10T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{"
                + "\"type\":\"token_count\",\"rate_limits\":{"
                + "\"primary\":{\"resets_in_seconds\":600},"
                + "\"secondary\":{\"resets_in_seconds\":7200}}}}",
            // A relative reset with no record timestamp has no base and is refused.
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\","
                + "\"rate_limits\":{\"primary\":{\"resets_in_seconds\":600}}}}",
            // An event_msg that is neither of the two known payloads is ignored.
            "{\"timestamp\":1781000000,\"type\":\"event_msg\",\"payload\":{\"type\":\"agent_message\"}}",
        ], to: codexFile(home, "rollout-2.jsonl"))

        let resets = read(home)
        require(resets.count == 2, "both token_count windows are read")
        require(resets.map(\.resetsAt) == [
            base.addingTimeInterval(600),
            base.addingTimeInterval(7200),
        ], "resets_in_seconds is relative to the record timestamp")
    }

    // MARK: - Robustness

    static func malformedRecords() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let valid = 1_781_003_000
        try write([
            "not json at all",
            "{\"type\":\"assistant\",\"message\":",
            "",
            "[1,2,3]",
            claudeLine(epoch: valid),
            "{\"type\":\"assistant\",\"message\":{\"content\":42}}",
        ], to: projectFile(home, "malformed.jsonl"))

        let resets = read(home)
        require(resets.count == 1, "malformed records are skipped, not guessed at")
        require(resets[0].resetsAt == Date(timeIntervalSince1970: Double(valid)),
                "the one valid record survives")
    }

    static func pastAndDuplicateResets() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let past = 1_780_999_000
        let future = 1_781_004_000
        try write([
            claudeLine(epoch: past),
            claudeLine(epoch: future, account: "acct-1"),
            claudeLine(epoch: future + 20, account: "acct-1"),
            claudeLine(epoch: future + 50, account: "acct-1"),
            claudeLine(epoch: future + 90, account: "acct-1"),
            claudeLine(epoch: future + 10, account: "acct-2"),
        ], to: projectFile(home, "dupes.jsonl"))

        let resets = read(home)
        require(!resets.contains { $0.resetsAt == Date(timeIntervalSince1970: Double(past)) },
                "a past reset is not reported")
        let first = Date(timeIntervalSince1970: Double(future))
        let secondAccount = Date(timeIntervalSince1970: Double(future + 10))
        require(resets.contains { $0.resetsAt == first && $0.account == "acct-1" },
                "the first report of the reset is kept")
        require(resets.contains { $0.resetsAt == secondAccount && $0.account == "acct-2" },
                "a different account at the same instant is a separate reset")
        require(!resets.contains { $0.resetsAt == first.addingTimeInterval(20) },
                "a same-account report within 60 s is deduplicated")
        require(!resets.contains { $0.resetsAt == first.addingTimeInterval(50) },
                "a same-account report 50 s later is deduplicated")
        require(resets.contains { $0.resetsAt == first.addingTimeInterval(90) },
                "a same-account report outside 60 s is a new reset")
        require(resets.count == 3, "past dropped, two accounts plus the later report kept")
    }

    static func absentRoots() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let resets = UsageResetReader(
            roots: UsageResetReader.Roots(
                claudeProjects: home.appendingPathComponent("nope/claude"),
                codexSessions: home.appendingPathComponent("nope/codex")
            ),
            now: { now }
        ).read()
        require(resets.isEmpty, "absent roots are empty, not an error")

        require(UsageResetReader(roots: UsageResetReader.Roots(claudeProjects: nil, codexSessions: nil),
                                 now: { now }).read().isEmpty,
                "no roots configured means no resets")
    }

    static func oversizedFile() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let file = projectFile(home, "huge.jsonl")
        try write([claudeLine(epoch: 1_781_005_000)], to: file)
        // A sparse file: cheap to create and far past the reader's size bound.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(UsageResetReader.maximumFileBytes + 1))
        try handle.close()

        require(read(home).isEmpty, "a file larger than the bound is ignored outright")
    }

    static func symlinksRefused() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        // A real transcript outside the project tree, and a symlink to it inside.
        let outside = home.appendingPathComponent("outside/real.jsonl")
        try write([claudeLine(epoch: 1_781_005_500)], to: outside)
        let projectRoot = home.appendingPathComponent(".claude/projects", isDirectory: true)
        try fileManager.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: projectRoot.appendingPathComponent("linked.jsonl"),
                                           withDestinationURL: outside)
        require(read(home).isEmpty, "a symlinked transcript is refused, never followed")

        // A symlinked project root is refused just as firmly.
        let symlinkRoot = home.appendingPathComponent("linked-projects", isDirectory: true)
        try fileManager.createSymbolicLink(at: symlinkRoot, withDestinationURL: projectRoot)
        let linked = UsageResetReader(
            roots: UsageResetReader.Roots(claudeProjects: symlinkRoot, codexSessions: nil),
            now: { now }
        ).read()
        require(linked.isEmpty, "a symlinked root is refused")

        try fileManager.removeItem(at: projectRoot.appendingPathComponent("linked.jsonl"))
        try write([claudeLine(epoch: 1_781_005_500)],
                  to: projectRoot.appendingPathComponent("regular.jsonl"))
        require(read(home).count == 1, "a regular transcript in the same tree is still read")
    }

    static func boundedTail() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        // A valid record before more padding than the tail window.
        var lines = [claudeLine(epoch: 1_781_006_000)]
        let padding = String(repeating: "x\n", count: (UsageResetReader.maximumTailBytes / 2) + 64 * 1024)
        lines.append(padding)
        try write(lines, to: projectFile(home, "long.jsonl"))

        let file = projectFile(home, "long.jsonl")
        let size = (try fileManager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        require(size > UsageResetReader.maximumTailBytes, "the fixture is larger than one tail window")
        require(read(home).isEmpty, "only the bounded tail is inspected")
    }

    static func boundedFileCount() throws {
        let home = try makeHome()
        defer { try? fileManager.removeItem(at: home) }

        let directory = home.appendingPathComponent(".claude/projects/-Users-me", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        // 12 valid but oldest files, then 48 empty newer ones. The reader keeps
        // the newest 48, so the valid records must not be seen.
        for index in 0..<60 {
            let file = directory.appendingPathComponent("s\(index).jsonl")
            if index < 12 {
                try write([claudeLine(epoch: 1_781_006_500 + index)], to: file)
            } else {
                try write(["{\"type\":\"summary\"}"], to: file)
            }
            let modified = now.addingTimeInterval(TimeInterval(index))
            try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }

        require(read(home).isEmpty, "at most 48 files are read, newest first")
    }
}
