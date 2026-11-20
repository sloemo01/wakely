import Foundation

/// Agent state read from desktop apps' own session stores. Cursor and Kiro are
/// VS Code forks whose terminals run the user's own servers, so when their store
/// is readable it decides; Hermes only confirms work the CPU check may miss.
enum AgentAppSessionState {
    static func read(provider: String, home: URL, since: Date?, now: Date = Date()) -> AgentTaskState? {
        switch provider {
        case "Cursor": return cursor(home: home, since: since)
        case "Kiro": return kiro(home: home, since: since, now: now)
        case "Hermes Agent": return hermes(home: home, since: since, now: now)
        default: return nil
        }
    }

    // MARK: Cursor

    /// Cursor's own test for a chat that is still running (`workbench.desktop.main.js`).
    static func cursor(status: String?, generating: Int, continuing: Bool) -> Bool {
        status == "generating" || continuing || (status != "aborted" && generating > 0)
    }

    static func cursor(home: URL, since: Date?) -> AgentTaskState? {
        let database = home.appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        let query = """
        SELECT json_extract(value, '$.status') AS status,
          json_array_length(json_extract(value, '$.generatingBubbleIds')) AS generating,
          json_extract(value, '$.isContinuationInProgress') AS continuing,
          json_extract(value, '$.lastUpdatedAt') AS updated
        FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(value)
        ORDER BY updated DESC LIMIT 20;
        """
        guard let output = AgentBackgroundScanner.command("/usr/bin/sqlite3", ["-readonly", "-json", database.path, query],
                                                          timeout: 1, maxBytes: 256 * 1024) else { return nil }
        let rows = output.isEmpty ? [] : (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]) ?? []
        return cursor(rows: rows, since: since)
    }

    static func cursor(rows: [[String: Any]], since: Date?) -> AgentTaskState {
        if rows.contains(where: {
            cursor(status: $0["status"] as? String, generating: ($0["generating"] as? Int) ?? 0,
                   continuing: ($0["continuing"] as? Int ?? 0) != 0)
        }) {
            return .working
        }
        let start = (since ?? .distantPast).timeIntervalSince1970 * 1000
        return rows.contains { ($0["updated"] as? Double ?? 0) >= start } ? .idle : .unknown
    }

    // MARK: Kiro

    /// Kiro's `messages.jsonl`: an unanswered approval or question waits on
    /// you, an open turn is working, an ended turn is idle.
    static func kiro<S: StringProtocol>(lines: [S]) -> AgentTaskState? {
        var pending = Set<String>()
        var state: AgentTaskState?
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = record["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            let call = payload["toolCallId"] as? String ?? ""
            switch type {
            case "turn_start": state = .working
            case "turn_end": state = .idle; pending.removeAll()
            case "pending_interaction": pending.insert(call)
            case "interaction_resolved": pending.remove(call)
            case "tool_call", "tool_result", "assistant": if state == nil { state = .working }
            default: break
            }
        }
        return pending.isEmpty ? state : .waiting
    }

    static func kiro(home: URL, since: Date?, now: Date) -> AgentTaskState? {
        let root = home.appendingPathComponent(".kiro/sessions")
        let fm = FileManager.default
        guard let workspaces = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        let start = (since ?? .distantPast).addingTimeInterval(-5)
        var newest: (url: URL, modified: Date)?
        for workspace in workspaces where workspace.lastPathComponent != "cli" {
            for session in (try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)) ?? []
            where session.lastPathComponent.hasPrefix("sess_") {
                let messages = session.appendingPathComponent("messages.jsonl")
                guard let modified = (try? fm.attributesOfItem(atPath: messages.path))?[.modificationDate] as? Date,
                      modified >= start, modified > (newest?.modified ?? .distantPast) else { continue }
                newest = (messages, modified)
            }
        }
        guard let newest else { return .unknown }
        guard let tail = tail(of: newest.url, bytes: 256 * 1024) else { return .unknown }
        return kiro(lines: tail.split(separator: "\n")) ?? .unknown
    }

    static func tail(of url: URL, bytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.readToEnd() else { return nil }
        // Cut the partial first line as bytes: the offset may split a UTF-8 character.
        if offset > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[data.index(after: newline)...] }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Hermes

    /// Hermes holds a turn lease in `state.db` while a conversation's turn
    /// runs; with no lease, a message since the app started means it finished.
    static func hermes(leases: Int, lastMessage: Double?, since: Date?) -> AgentTaskState? {
        if leases > 0 { return .working }
        guard let lastMessage, lastMessage >= (since ?? .distantPast).timeIntervalSince1970 else { return nil }
        return .idle
    }

    static func hermes(home: URL, since: Date?, now: Date) -> AgentTaskState? {
        let database = home.appendingPathComponent(".hermes/state.db")
        let query = "SELECT (SELECT COUNT(*) FROM session_turn_leases WHERE expires_at > \(now.timeIntervalSince1970)) AS leases, " +
            "(SELECT MAX(timestamp) FROM messages) AS last;"
        guard FileManager.default.fileExists(atPath: database.path),
              let output = AgentBackgroundScanner.command("/usr/bin/sqlite3", ["-readonly", "-json", database.path, query],
                                                          timeout: 1, maxBytes: 4096),
              let row = (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]])?.first
        else { return nil }
        return hermes(leases: row["leases"] as? Int ?? 0, lastMessage: row["last"] as? Double, since: since)
    }
}
