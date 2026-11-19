// Read-only, metadata-only task adapters. Unknown is deliberately not busy.
import Foundation

enum AgentTaskState: String, Equatable, Sendable {
    case working, waiting, idle, unknown
    var working: Bool { self == .working }
    var busy: Bool { self == .working || self == .waiting }
}

// MARK: - Display activity

/// The last display-capable tool call observed in a transcript. `tool` is raw
/// metadata used only for classification and change detection: it is never
/// logged, displayed, or sent anywhere. `DisplayToolKind` and its classifier
/// live in `AgentDisplayPolicy.swift`, which keeps this model policy-free.
struct AgentDisplayActivity: Equatable, Sendable {
    let tool: String
    let startedAt: Date
    var endedAt: Date?
    var callID: String?

    var isActive: Bool { endedAt == nil }
    var lastActivityAt: Date { endedAt ?? startedAt }
}

// MARK: - Claude registry metadata

/// Status strings observed as leads. Unknown values
/// stay unknown; they are never upgraded to busy.
enum AgentRegistryStatus: String, Equatable, Sendable {
    case busy, shell, waiting, idle

    /// Only positive claims can override an unknown transcript state. `idle`
    /// is deliberately excluded: a stale registry record must not fabricate a
    /// busy -> idle completion.
    var claimedState: AgentTaskState? {
        switch self {
        case .busy, .shell: return .working
        case .waiting: return .waiting
        case .idle: return nil
        }
    }
}

enum AgentNameSource: String, Equatable, Sendable {
    case chosen, generated, derived
}

/// One defensive, read-only view of a registry line. The exact schema
/// is not established (see `ClaudeSessionRegistry`), so every field is
/// optional and unknown keys are ignored.
struct ClaudeRegistryRecord: Equatable, Sendable {
    var sessionID: String?
    var pid: Int32?
    var pidDomain: String?
    var processStart: Date?
    var entrypoint: String?
    var cwd: String?
    var kind: String?
    var status: AgentRegistryStatus?
    var waitingFor: String?
    var statusUpdatedAt: Date?
    var version: String?
    var name: String?
    var nameSource: AgentNameSource?
    var host: String?
    var chosenName: String?
}

/// De-duplicated registry view. Duplicate session IDs collapse to the newest
/// record; duplicate PIDs remain ambiguous and are never used for identity.
struct ClaudeRegistrySnapshot: Equatable, Sendable {
    private(set) var records: [ClaudeRegistryRecord] = []
    private(set) var bySessionID: [String: ClaudeRegistryRecord] = [:]

    var isEmpty: Bool { records.isEmpty }
    var count: Int { records.count }

    func record(sessionID: String?) -> ClaudeRegistryRecord? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return bySessionID[sessionID]
    }

    func record(pid: Int32, processStart: Date?) -> ClaudeRegistryRecord? {
        let matches = records.filter { $0.pid == pid }
        guard matches.count == 1, let record = matches.first else { return nil }
        if let processStart, let recorded = record.processStart,
           abs(recorded.timeIntervalSince(processStart)) > 2 { return nil }
        return record
    }

    /// A cwd-only lookup is safe only while exactly one session claims it.
    func record(cwd: String?) -> ClaudeRegistryRecord? {
        guard let cwd = Self.normalized(cwd) else { return nil }
        let matches = records.filter { Self.normalized($0.cwd) == cwd }
        return matches.count == 1 ? matches[0] : nil
    }

    static func normalized(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    mutating func insert(_ record: ClaudeRegistryRecord) {
        guard let key = record.sessionID, !key.isEmpty else {
            records.append(record)
            return
        }
        if let index = records.firstIndex(where: { $0.sessionID == key }) {
            // A live index can rewrite a line; keep the newest claim. Ties keep
            // the later line, matching append order.
            if (record.statusUpdatedAt ?? .distantPast) >= (records[index].statusUpdatedAt ?? .distantPast) {
                records[index] = record
            }
        } else {
            records.append(record)
        }
        bySessionID[key] = records.first(where: { $0.sessionID == key })
    }
}

struct AgentProcessDescriptor: Equatable, Sendable {
    let pid: Int32
    let provider: String
    let sessionID: String?
    let cwd: String?
    let startedAt: Date?
    var parentPID: Int32? = nil
    var isLauncher = false

    /// Agents Wakely sees only as processes: they leave no transcript Wakely
    /// reads, so their task state stays unknown.
    static let processOnlyProviders: [String: String] = [
        "opencode": "OpenCode", "pi": "Pi", "cursor-agent": "Cursor Agent", "amp": "Amp",
        "cline": "Cline", "kilo": "Kilo", "kilocode": "Kilo", "aider": "Aider",
        "qwen": "Qwen Code", "dsh": "DeepSeek Harness", "hermes": "Hermes Agent",
    ]

    /// Desktop apps that run agents, by their bundle executable. Matched only
    /// on a `<Name>.app/Contents/MacOS/<Name>` path, never on a bare name, so
    /// the Codex app is not mistaken for the Codex CLI.
    static let desktopAppProviders: [String: String] = [
        "DeepSeek Harness": "DeepSeek Harness", "Claude": "Claude", "Codex": "Codex App",
        "Cursor": "Cursor", "OpenCode": "OpenCode", "Windsurf": "Windsurf", "Devin": "Devin",
        "Kiro": "Kiro", "Hermes": "Hermes Agent", "Hermes Agent": "Hermes Agent",
    ]

    static var processOnlyProviderNames: Set<String> {
        Set(processOnlyProviders.values).union(desktopAppProviders.values)
    }

    static func provider(executable: String, arguments: [String]) -> String? {
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        // npm's Claude Code package runs a native `claude.exe`; `claude` is its symlink.
        if name == "claude" || name == "claude.exe" { return "Claude Code" }
        if name == "codex" { return "Codex" }
        if let other = processOnlyProviders[name] { return other }
        // Only recognize known CLI entrypoints, never prompt text or arbitrary
        // commands containing a provider's name.
        if name == "node" || name == "nodejs" || name == "bun" {
            for argument in arguments.prefix(4) {
                if argument.hasSuffix("/@anthropic-ai/claude-code/cli.js") { return "Claude Code" }
                if argument.hasSuffix("/@openai/codex/bin/codex.js") { return "Codex" }
            }
        }
        return nil
    }

    static func explicitSessionID(arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            for option in ["--session-id", "--resume"] {
                if argument == option, index + 1 < arguments.count,
                   validSessionID(arguments[index + 1]) { return arguments[index + 1] }
                if argument.hasPrefix(option + "=") {
                    let value = String(argument.dropFirst(option.count + 1))
                    if validSessionID(value) { return value }
                }
            }
            if argument == "resume", index + 1 < arguments.count,
               validSessionID(arguments[index + 1]) { return arguments[index + 1] }
        }
        return nil
    }

    private static func validSessionID(_ value: String) -> Bool {
        // Session IDs are identifiers, not filesystem paths, prompts, or flags.
        !value.isEmpty && value.count <= 128 && value != "latest" && value != "last"
            && !value.hasPrefix("-")
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
    }
}

struct AgentSessionSnapshot: Equatable, Sendable {
    let provider: String
    var sessionID: String?
    var cwd: String?
    var state: AgentTaskState = .unknown
    var updatedAt: Date?
    /// User-visible identity from the registry or derived from provider + cwd.
    /// Never transcript text.
    var name: String?
    var nameSource: AgentNameSource?
    var host: String?
    /// Last tool call seen in the transcript, independent of the coarse state.
    var activity: AgentDisplayActivity?
}

enum AgentTaskAdapter {
    // Ignore all message content. Only explicit lifecycle metadata is consumed.
    static func snapshot(provider: String, header: Data, tail: Data, tailStartsMidLine: Bool) -> AgentSessionSnapshot {
        var result = AgentSessionSnapshot(provider: provider)
        // Activity is read only from the tail. The header exists to recover
        // session metadata; an ancient tool_use there must not look like a
        // call that is still active now. Small files are wholly in the tail,
        // so this does not lose recent activity.
        for record in records(header, startsMidLine: false) {
            apply(record, to: &result, trackActivity: false)
        }
        for record in records(tail, startsMidLine: tailStartsMidLine) {
            apply(record, to: &result, trackActivity: true)
        }
        return result
    }

    private static func apply(_ record: [String: Any], to result: inout AgentSessionSnapshot, trackActivity: Bool) {
        applyMetadata(record, to: &result)
        if trackActivity { applyActivity(record, to: &result) }
        if let state = lifecycle(record, provider: result.provider) {
            result.state = state
            result.updatedAt = AgentTimestamps.date(record["timestamp"])
        }
    }

    /// Claude Code: `assistant` content blocks of `type: "tool_use"` start a
    /// call, and a `user` `tool_result` for that exact call ID completes it.
    /// Sidechain (subagent) activity is not the top-level session's display
    /// demand, so it is ignored.
    private static func applyClaudeActivity(_ record: [String: Any], to result: inout AgentSessionSnapshot) {
        guard record["isSidechain"] as? Bool != true else { return }
        guard let type = record["type"] as? String, type == "assistant" || type == "user",
              let message = record["message"] as? [String: Any],
              let timestamp = AgentTimestamps.date(record["timestamp"]) else { return }
        if type == "assistant" {
            guard let content = message["content"] as? [[String: Any]] else { return }
            for block in content where block["type"] as? String == "tool_use" {
                guard let tool = block["name"] as? String, !tool.isEmpty else { continue }
                result.activity = AgentDisplayActivity(
                    tool: String(tool.prefix(128)),
                    startedAt: timestamp,
                    endedAt: nil,
                    callID: (block["id"] as? String).map { String($0.prefix(128)) })
            }
            return
        }
        // A user prompt (string content, or blocks without any tool_result) is
        // a new turn. A call that never got its result before that prompt is
        // no longer active, so it must not keep the display alive.
        if let text = message["content"] as? String, !text.isEmpty {
            clearActiveActivity(&result)
            return
        }
        guard let content = message["content"] as? [[String: Any]] else { return }
        if !content.contains(where: { $0["type"] as? String == "tool_result" }) {
            clearActiveActivity(&result)
            return
        }
        for block in content where block["type"] as? String == "tool_result" {
            guard var activity = result.activity, activity.isActive else { continue }
            // Only a result for the tracked call completes it. An unknown
            // or mismatched ID may belong to an untracked parallel call.
            if let resultID = block["tool_use_id"] as? String {
                guard activity.callID == resultID else { continue }
            } else if activity.callID != nil {
                continue
            }
            activity.endedAt = timestamp
            result.activity = activity
        }
    }

    /// Codex: only the explicit begin/end event pairs that are understood.
    /// Any other event shape is ignored rather than guessed at.
    private static func applyCodexActivity(_ record: [String: Any], to result: inout AgentSessionSnapshot) {
        guard record["type"] as? String == "event_msg",
              let payload = record["payload"] as? [String: Any],
              let event = payload["type"] as? String,
              let timestamp = AgentTimestamps.date(record["timestamp"]) else { return }
        switch event {
        case "exec_command_begin", "mcp_tool_call_begin", "mcp_tool_call_started":
            let tool = codexToolName(payload: payload, event: event)
            result.activity = AgentDisplayActivity(
                tool: tool,
                startedAt: timestamp,
                endedAt: nil,
                callID: codexCallID(payload))
        case "exec_command_end", "mcp_tool_call_end", "mcp_tool_call_completed":
            guard var activity = result.activity, activity.isActive else { return }
            if let id = codexCallID(payload) {
                guard activity.callID == id else { return }
            }
            activity.endedAt = timestamp
            result.activity = activity
        case "task_started", "task_complete", "turn_aborted":
            // A task boundary discards a call left active by an interrupted
            // turn. It is not a completion, so it must not create a recent
            // completion that would hold the display for the grace period.
            clearActiveActivity(&result)
        default:
            // Unknown event shapes are ignored rather than guessed at.
            return
        }
    }

    private static func clearActiveActivity(_ result: inout AgentSessionSnapshot) {
        guard result.activity?.isActive == true else { return }
        result.activity = nil
    }

    private static func applyActivity(_ record: [String: Any], to result: inout AgentSessionSnapshot) {
        switch result.provider {
        case "Claude Code": applyClaudeActivity(record, to: &result)
        case "Codex": applyCodexActivity(record, to: &result)
        default: break
        }
    }

    private static func codexToolName(payload: [String: Any], event: String) -> String {
        var parts: [String] = []
        if let server = payload["server"] as? String, !server.isEmpty { parts.append(server) }
        if let tool = payload["tool"] as? String, !tool.isEmpty { parts.append(tool) }
        else if let name = payload["name"] as? String, !name.isEmpty { parts.append(name) }
        if !parts.isEmpty { return String(parts.joined(separator: " ").prefix(128)) }
        return event.hasPrefix("exec_command") ? "exec_command" : "mcp_tool_call"
    }

    private static func codexCallID(_ payload: [String: Any]) -> String? {
        for key in ["call_id", "callId", "tool_call_id", "id"] {
            if let value = payload[key] as? String, !value.isEmpty { return String(value.prefix(128)) }
            if let value = payload[key] as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func records(_ data: Data, startsMidLine: Bool) -> [[String: Any]] {
        // Callers enforce the byte cap; don't parse a partial last JSONL record.
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if startsMidLine, !lines.isEmpty { lines.removeFirst() }
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        return lines.compactMap { line in
            guard !line.isEmpty, line.count <= 128 * 1024 else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    private static func applyMetadata(_ record: [String: Any], to result: inout AgentSessionSnapshot) {
        if result.provider == "Codex", record["type"] as? String == "session_meta",
           let payload = record["payload"] as? [String: Any] {
            result.sessionID = payload["id"] as? String ?? result.sessionID
            result.cwd = payload["cwd"] as? String ?? result.cwd
        } else if result.provider == "Claude Code" {
            result.sessionID = record["sessionId"] as? String ?? result.sessionID
            result.cwd = record["cwd"] as? String ?? result.cwd
        }
    }

    private static func lifecycle(_ record: [String: Any], provider: String) -> AgentTaskState? {
        let type = record["type"] as? String
        if provider == "Codex" {
            guard type == "event_msg", let payload = record["payload"] as? [String: Any],
                  let event = payload["type"] as? String else { return nil }
            switch event {
            case "task_started": return .working
            case "task_complete", "turn_aborted": return .idle
            // Explicit approval requests only. tool_use, commands, and text
            // mentioning approval are not evidence that the task is waiting.
            case "approval_request", "exec_approval_request", "apply_patch_approval_request": return .waiting
            default: return nil
            }
        }
        if provider == "Claude Code" {
            switch type {
            case "user": return .working
            case "assistant":
                let message = record["message"] as? [String: Any]
                return message?["stop_reason"] as? String == "end_turn" ? .idle : nil
            case "system":
                return record["subtype"] as? String == "turn_duration" ? .idle : nil
            case "approval_request": return .waiting
            default: return nil
            }
        }
        return nil
    }

}

/// Accepts the timestamp shapes seen in transcripts and registry leads: ISO
/// 8601 strings, epoch seconds, and epoch milliseconds. Anything else is
/// unknown, never a fabricated "now".
enum AgentTimestamps {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain = ISO8601DateFormatter()

    static func date(_ value: Any?) -> Date? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
            return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
        }
        guard !(value is Bool), let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        let seconds = abs(raw) > 100_000_000_000 ? raw / 1000 : raw
        guard abs(seconds) >= 1_000_000_000, abs(seconds) <= 4_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

enum AgentTaskCorrelation {
    static func state(for process: AgentProcessDescriptor, sessions: [AgentSessionSnapshot], processes: [AgentProcessDescriptor]) -> AgentTaskState {
        correlation(for: process, sessions: sessions, processes: processes).state
    }

    /// The same match used for state also supplies identity and display
    /// activity, so a thread never gets a name or tool call from a session
    /// that was not safely attributed to it. Ambiguity returns `.unknown` with
    /// no session.
    static func correlation(for process: AgentProcessDescriptor,
                            sessions: [AgentSessionSnapshot],
                            processes: [AgentProcessDescriptor]) -> (state: AgentTaskState, session: AgentSessionSnapshot?) {
        let candidates = sessions.filter { $0.provider == process.provider }
        if let id = process.sessionID {
            // A supplied ID must match, not silently fall back to some other
            // task in the same directory. Conflicting copies are ambiguous.
            let matches = candidates.filter { $0.sessionID == id }
            guard let match = uniqueLatest(matches) else { return (.unknown, nil) }
            // A resumed CLI can be idle while an old process left an unfinished
            // task_started in its transcript. Do not resurrect that old work.
            if match.state.busy {
                guard let updated = match.updatedAt, let started = process.startedAt,
                      updated >= started.addingTimeInterval(-2) else { return (.unknown, match) }
            }
            return (match.state, match)
        }
        guard let cwd = normalized(process.cwd), let started = process.startedAt else { return (.unknown, nil) }
        let peers = processes.filter { $0.provider == process.provider && normalized($0.cwd) == cwd }
        guard peers.count == 1 else { return (.unknown, nil) }
        let matches = candidates.filter {
            normalized($0.cwd) == cwd && ($0.updatedAt.map { $0 >= started.addingTimeInterval(-2) } ?? false)
        }
        // Multiple concurrent sessions in one cwd cannot be safely attributed
        // to a PID merely because one file happened to be newer.
        guard matches.count == 1 else { return (.unknown, nil) }
        return (matches[0].state, matches[0])
    }

    private static func uniqueLatest(_ snapshots: [AgentSessionSnapshot]) -> AgentSessionSnapshot? {
        guard !snapshots.isEmpty else { return nil }
        if snapshots.count == 1 { return snapshots[0] }
        let sorted = snapshots.sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
        guard let newest = sorted.first?.updatedAt, sorted.dropFirst().allSatisfy({ ($0.updatedAt ?? .distantPast) < newest }) else { return nil }
        return sorted[0]
    }

    private static func normalized(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// Bounded disk reader. Never writes a transcript or returns message text.
enum AgentSessionFiles {
    static let tailLimit = 256 * 1024
    static let headerLimit = 16 * 1024
    static let fileLimit = 96
    static let directoryLimit = 128
    static let entryLimit = 4096

    static func snapshots(home: URL, processes: [AgentProcessDescriptor]) -> [AgentSessionSnapshot] {
        var result: [AgentSessionSnapshot] = []
        if processes.contains(where: { $0.provider == "Claude Code" }) {
            result += read(root: home.appendingPathComponent(".claude/projects"), provider: "Claude Code", maxDepth: 1)
        }
        if processes.contains(where: { $0.provider == "Codex" }) {
            result += read(root: home.appendingPathComponent(".codex/sessions"), provider: "Codex", maxDepth: 3)
        }
        return result
    }

    private static func read(root: URL, provider: String, maxDepth: Int) -> [AgentSessionSnapshot] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        var queue: [(URL, Int)] = [(root, 0)]
        var directories = 0
        var entries = 0
        var files: [(URL, Date)] = []
        while !queue.isEmpty && directories < directoryLimit && entries < entryLimit {
            let (directory, depth) = queue.removeFirst()
            directories += 1
            // Refuse symlinked roots/directories: don't follow arbitrary paths.
            guard let metadata = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]), metadata.isSymbolicLink != true,
                  let enumeration = manager.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { continue }
            while entries < entryLimit, let url = enumeration.nextObject() as? URL {
                entries += 1
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
                if values.isDirectory == true, depth < maxDepth {
                    queue.append((url, depth + 1))
                } else if values.isRegularFile == true && url.pathExtension == "jsonl" {
                    files.append((url, values.contentModificationDate ?? .distantPast))
                }
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(fileLimit).compactMap { url, _ in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            do {
                let size = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
                let header = try handle.read(upToCount: headerLimit) ?? Data()
                let start = size > UInt64(tailLimit) ? size - UInt64(tailLimit) : 0
                try handle.seek(toOffset: start)
                let tail = try handle.read(upToCount: tailLimit) ?? Data()
                return AgentTaskAdapter.snapshot(provider: provider, header: header, tail: tail, tailStartsMidLine: start > 0)
            } catch { return nil }
        }
    }
}

// MARK: - Claude session registry (defensive, read-only)

/// Read-only adapter for an optional Claude Code session index.
///
/// Evidence status: observed artifacts include
/// `session_index.jsonl`, `CLAUDE_CONFIG_DIR`, `claude-code-sessions`,
/// `ClaudeRegistryRecord`, and field names such as `sessionId`/`session_id`,
/// `chosenName`, `nameSource`, `status`, `pid`, `cwd`, and
/// `statusUpdatedAt`. No registry exists on the development Mac, so the exact
/// schema and sentinel semantics are **not proven**. This adapter therefore:
///
/// - treats every field as optional and ignores unknown keys;
/// - recognizes `sessionId`/`session_id`, `name`, `chosenName`, `nameSource`,
///   `status`, `waitingFor`, `kind`, `cwd`, `pid`, `pidDomain`,
///   `processStart`, `entrypoint`, `version`, `statusUpdatedAt`,
///   `updatedAt`/`updated_at`/`timestamp`, and `host`/`hostApp`;
/// - never executes, imports, or evaluates registry content;
/// - never reads credentials or transcript text, and never logs names/paths;
/// - refuses symlinks and applies file/line/directory/depth caps.
///
/// Candidate roots, in order: an absolute `$CLAUDE_CONFIG_DIR`, `~/.claude`,
/// then `~/Library/Application Support/Claude/claude-code-sessions`. Each root
/// is searched recursively (depth 3, at most 32 `session_index.jsonl` files)
/// for the index file only; no other file is read.
///
/// Name policy: a non-empty `chosenName` (or a supplied `name` whose
/// `nameSource` is not `derived`) wins. The literal sentinel `derived` is
/// treated as absent, matching the decompiled `chosenName` getter. Otherwise a
/// name is derived from provider + cwd basename, else
/// `Provider — session <last 4 of id>`.
enum ClaudeSessionRegistry {
    static let indexFileName = "session_index.jsonl"
    static let fileByteLimit = 512 * 1024
    static let lineByteLimit = 128 * 1024
    static let lineLimit = 4096
    static let fileLimit = 32
    static let directoryLimit = 64
    static let entryLimit = 2048
    static let depthLimit = 3
    static let nameLimit = 80

    /// Candidate roots in documented order. Relative `CLAUDE_CONFIG_DIR`
    /// values are refused rather than resolved against the current directory.
    static func candidateRoots(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        var roots: [URL] = []
        func add(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard !roots.contains(where: { $0.path == standardized.path }) else { return }
            roots.append(standardized)
        }
        if let custom = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           custom.hasPrefix("/") {
            add(URL(fileURLWithPath: custom, isDirectory: true))
        }
        add(home.appendingPathComponent(".claude", isDirectory: true))
        add(home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true))
        return roots
    }

    static func load(home: URL, environment: [String: String] = ProcessInfo.processInfo.environment) -> ClaudeRegistrySnapshot {
        var snapshot = ClaudeRegistrySnapshot()
        var seen: Set<String> = []
        for root in candidateRoots(home: home, environment: environment) {
            for file in indexFiles(in: root) {
                let path = file.standardizedFileURL.path
                guard seen.insert(path).inserted else { continue }
                read(file, into: &snapshot)
            }
        }
        return snapshot
    }

    /// Registry metadata for one process. An explicit session ID must match;
    /// otherwise a unique PID with a compatible process start, then a unique
    /// cwd, may be used. Ambiguity yields no metadata.
    static func record(for process: AgentProcessDescriptor,
                       transcriptSessionID: String?,
                       registry: ClaudeRegistrySnapshot) -> ClaudeRegistryRecord? {
        guard process.provider == "Claude Code" else { return nil }
        if let id = process.sessionID ?? transcriptSessionID {
            return registry.record(sessionID: id)
        }
        if let record = registry.record(pid: process.pid, processStart: process.startedAt) {
            return record
        }
        return registry.record(cwd: process.cwd)
    }

    /// A positive registry claim is only used when the transcript has no state
    /// and the claim is not older than the process. Missing timestamps stay
    /// unknown.
    static func claimedState(for record: ClaudeRegistryRecord, process: AgentProcessDescriptor) -> AgentTaskState? {
        guard let claimed = record.status?.claimedState, let updated = record.statusUpdatedAt else { return nil }
        if let started = process.startedAt, updated < started.addingTimeInterval(-2) { return nil }
        return claimed
    }

    static func displayName(provider: String,
                            record: ClaudeRegistryRecord?,
                            sessionID: String?,
                            cwd: String?) -> (name: String?, source: AgentNameSource?) {
        if let record {
            if let chosen = sanitize(record.chosenName ?? "", limit: nameLimit), !isDerivedSentinel(chosen) {
                return (chosen, .chosen)
            }
            if let supplied = sanitize(record.name ?? "", limit: nameLimit), !isDerivedSentinel(supplied),
               record.nameSource != .derived {
                return (supplied, record.nameSource ?? .generated)
            }
        }
        return derivedDisplayName(provider: provider,
                                  cwd: cwd ?? record?.cwd,
                                  sessionID: sessionID ?? record?.sessionID)
    }

    static func derivedDisplayName(provider: String,
                                   cwd: String?,
                                   sessionID: String?) -> (name: String?, source: AgentNameSource?) {
        if let path = cwd, let base = basename(path), let clean = sanitize(base, limit: nameLimit) {
            return ("\(provider) — \(clean)", .derived)
        }
        if let id = sanitize(sessionID ?? "", limit: 128) {
            return ("\(provider) — session \(String(id.suffix(4)))", .derived)
        }
        return (nil, nil)
    }

    // MARK: Bounded file access

    private static func indexFiles(in root: URL) -> [URL] {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let rootValues = try? root.resourceValues(forKeys: Set(keys)),
              rootValues.isSymbolicLink != true, rootValues.isDirectory == true else { return [] }
        var queue: [(URL, Int)] = [(root, 0)]
        var directories = 0
        var entries = 0
        var files: [URL] = []
        while !queue.isEmpty && directories < directoryLimit && entries < entryLimit {
            let (directory, depth) = queue.removeFirst()
            directories += 1
            guard let enumeration = manager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else { continue }
            while entries < entryLimit, let url = enumeration.nextObject() as? URL {
                entries += 1
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if depth < depthLimit { queue.append((url, depth + 1)) }
                } else if values.isRegularFile == true, url.lastPathComponent == indexFileName {
                    files.append(url)
                    if files.count >= fileLimit { return files }
                }
            }
        }
        return files
    }

    private static func read(_ url: URL, into snapshot: inout ClaudeRegistrySnapshot) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            // Over-cap files are ignored entirely rather than partially parsed.
            guard size <= UInt64(fileByteLimit) else { return }
            try handle.seek(toOffset: 0)
            guard let data = try handle.read(upToCount: fileByteLimit + 1),
                  data.count <= fileByteLimit else { return }
            parse(data, into: &snapshot)
        } catch {
            return
        }
    }

    private static func parse(_ data: Data, into snapshot: inout ClaudeRegistrySnapshot) {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if lines.count > lineLimit { lines = Array(lines.suffix(lineLimit)) }
        for line in lines {
            guard line.count <= lineByteLimit,
                  let object = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let record = record(from: object) else { continue }
            snapshot.insert(record)
        }
    }

    private static func record(from object: [String: Any]) -> ClaudeRegistryRecord? {
        var record = ClaudeRegistryRecord()
        record.sessionID = text(object, ["sessionId", "session_id", "sessionID"], limit: 128)
        record.pid = int32(object["pid"])
        record.pidDomain = text(object, ["pidDomain"], limit: 64)
        record.processStart = AgentTimestamps.date(object["processStart"])
        record.entrypoint = text(object, ["entrypoint"], limit: 128)
        record.cwd = absolutePath(text(object, ["cwd", "workingDirectory"], limit: 1024))
        record.kind = text(object, ["kind"], limit: 64)
        record.status = AgentRegistryStatus(rawValue: (text(object, ["status"], limit: 32) ?? "").lowercased())
        record.waitingFor = text(object, ["waitingFor", "waiting_for"], limit: 64)
        record.statusUpdatedAt = AgentTimestamps.date(first(object, ["statusUpdatedAt", "updatedAt", "updated_at", "timestamp"]))
        record.version = text(object, ["version"], limit: 64) ?? (object["version"] as? NSNumber)?.stringValue
        record.name = text(object, ["name"], limit: 512)
        record.nameSource = AgentNameSource(rawValue: (text(object, ["nameSource", "name_source"], limit: 32) ?? "").lowercased())
        record.host = text(object, ["host", "hostApp", "hostApplication"], limit: 128)
        record.chosenName = text(object, ["chosenName", "chosen_name"], limit: 512)
        // A line without any recognized identity field cannot identify a
        // session; ignoring it keeps malformed/foreign lines harmless.
        guard record.sessionID != nil || record.pid != nil || record.cwd != nil || record.name != nil else { return nil }
        return record
    }

    private static func first(_ object: [String: Any], _ keys: [String]) -> Any? {
        for key in keys where object[key] != nil { return object[key] }
        return nil
    }

    private static func text(_ object: [String: Any], _ keys: [String], limit: Int) -> String? {
        for key in keys {
            if let value = object[key] as? String, let cleaned = sanitize(value, limit: limit) {
                return cleaned
            }
        }
        return nil
    }

    private static func int32(_ value: Any?) -> Int32? {
        guard !(value is Bool) else { return nil }
        let number: Int64?
        if let value = value as? NSNumber { number = value.int64Value }
        else if let value = value as? String { number = Int64(value) }
        else { number = nil }
        guard let number, number > 0, number <= Int64(Int32.max) else { return nil }
        return Int32(number)
    }

    private static func absolutePath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/") else { return nil }
        return value
    }

    static func sanitize(_ value: String, limit: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Bound work before filtering an arbitrarily large hostile string.
        let bounded = String(trimmed.prefix(max(limit * 4, 64)))
        let filtered = bounded.filter { character in
            guard let scalar = character.unicodeScalars.first else { return false }
            return !character.isNewline && !CharacterSet.controlCharacters.contains(scalar)
        }
        let collapsed = filtered.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(limit))
    }

    private static func isDerivedSentinel(_ value: String) -> Bool {
        value.caseInsensitiveCompare("derived") == .orderedSame
    }

    private static func basename(_ path: String) -> String? {
        guard path.hasPrefix("/"), path != "/" else { return nil }
        let base = URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent
        guard !base.isEmpty, base != "/", base != ".", base != ".." else { return nil }
        return base
    }
}
