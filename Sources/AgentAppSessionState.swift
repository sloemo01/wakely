import Foundation

/// Agent state read from desktop apps' own session stores. Cursor and Kiro are
/// VS Code forks whose terminals run the user's own servers, so when their store
/// is readable it decides; Hermes only confirms work the CPU check may miss.
enum AgentAppSessionState {
    static func read(provider: String, home: URL, since: Date?, pid: Int32 = 0, now: Date = Date()) -> AgentTaskState? {
        switch provider {
        case "DeepSeek Harness": return deepSeek(home: home, since: since, app: executable(of: pid))
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
          json_extract(value, '$.lastUpdatedAt') AS updated, substr(key, 14) AS id
        FROM cursorDiskKV WHERE key LIKE 'composerData:%' AND json_valid(value)
        ORDER BY updated DESC LIMIT 20;
        """
        guard let output = AgentBackgroundScanner.command("/usr/bin/sqlite3", ["-readonly", "-json", database.path, query],
                                                          timeout: 1, maxBytes: 256 * 1024) else { return nil }
        let rows = output.isEmpty ? [] : (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]]) ?? []
        return cursor(rows: rows, since: since, runningTools: runningTools(database: database, rows: rows, since: since))
    }

    /// Cursor marks a chat "aborted" while a tool awaits approval or runs; the
    /// tool call itself stays "loading" until it finishes.
    static func runningTools(database: URL, rows: [[String: Any]], since: Date?) -> Int {
        let start = (since ?? .distantPast).timeIntervalSince1970 * 1000
        let ids = rows.filter { ($0["updated"] as? Double ?? 0) >= start }.compactMap { $0["id"] as? String }
            .filter { !$0.isEmpty && $0.allSatisfy { $0.isHexDigit || $0 == "-" } }
        guard !ids.isEmpty else { return 0 }
        let ranges = ids.map { "(key >= 'bubbleId:\($0):' AND key < 'bubbleId:\($0);')" }.joined(separator: " OR ")
        let query = "SELECT COUNT(*) FROM cursorDiskKV WHERE (\(ranges)) AND json_valid(value) " +
            "AND json_extract(value, '$.toolFormerData.status') = 'loading';"
        let output = AgentBackgroundScanner.command("/usr/bin/sqlite3", ["-readonly", database.path, query], timeout: 1, maxBytes: 1024)
        return Int(output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    static func cursor(rows: [[String: Any]], since: Date?, runningTools: Int = 0) -> AgentTaskState {
        if runningTools > 0 { return .working }
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
        var recent: [(url: URL, modified: Date)] = []
        for workspace in workspaces where workspace.lastPathComponent != "cli" {
            for session in (try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)) ?? []
            where session.lastPathComponent.hasPrefix("sess_") {
                let messages = session.appendingPathComponent("messages.jsonl")
                guard let modified = (try? fm.attributesOfItem(atPath: messages.path))?[.modificationDate] as? Date,
                      modified >= start else { continue }
                recent.append((messages, modified))
            }
        }
        // Several chats can run at once: one waiting or working outranks one that finished.
        let states = recent.sorted { $0.modified > $1.modified }.prefix(8).compactMap { session in
            tail(of: session.url, bytes: 256 * 1024).flatMap { kiro(lines: $0.split(separator: "\n")) }
        }
        return combined(states)
    }

    static func combined(_ states: [AgentTaskState]) -> AgentTaskState {
        for state in [AgentTaskState.waiting, .working, .idle] where states.contains(state) { return state }
        return .unknown
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

    // MARK: DeepSeek Harness

    static func executable(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard pid > 0, proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func deepSeek<S: StringProtocol>(events: [S]) -> AgentTaskState? {
        var state: AgentTaskState?
        for event in events {
            switch event {
            case "turn/start", "approval/decided": state = .working
            case "approval/asked": state = .waiting
            case "turn/end": state = .idle
            default: break
            }
        }
        return state
    }

    /// Harness appends a zstd frame per write to `session.v4.jsonl.zstd`. macOS has
    /// no zstd, but the app is Electron, whose Node decodes one frame per call.
    static let zstdEvents = #"""
    const z=require("zlib"),b=require("fs").readFileSync(process.argv[process.argv.length-1]);let p=0,o=[];
    while(p+4<=b.length){const m=b.readUInt32LE(p),s=p;
    if((m&0xFFFFFFF0)===0x184D2A50){p+=8+b.readUInt32LE(p+4);continue}
    if(m!==0xFD2FB528)break;const d=b[p+4];p+=5;if(!(d&32))p++;p+=[0,1,2,4][d&3];p+=[d&32?1:0,2,4,8][d>>6];
    for(;;){if(p+3>b.length){p=b.length+1;break}const h=b[p]|b[p+1]<<8|b[p+2]<<16;p+=3+((h>>1&3)===1?1:h>>3);if(h&1)break}
    if(d&4)p+=4;if(p>b.length)break;o.push(z.zstdDecompressSync(b.subarray(s,p)))}
    for(const l of Buffer.concat(o).toString().split("\n"))try{const t=JSON.parse(l).type;if(/^(turn|approval)\//.test(t))console.log(t)}catch{}
    """#

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: (stamp: String, state: AgentTaskState?)] = [:]

    static func deepSeek(home: URL, since: Date?, app: String?) -> AgentTaskState? {
        guard let app else { return nil }
        let root = home.appendingPathComponent(".dsh/sessions")
        let fm = FileManager.default
        let start = (since ?? .distantPast).addingTimeInterval(-5)
        var recent: [(path: String, modified: Date, size: Int)] = []
        for workspace in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for session in (try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: nil)) ?? []
            where session.lastPathComponent.hasPrefix("session-") {
                let log = session.appendingPathComponent("session.v4.jsonl.zstd").path
                guard let attributes = try? fm.attributesOfItem(atPath: log),
                      let modified = attributes[.modificationDate] as? Date, modified >= start,
                      let size = attributes[.size] as? Int, size < 32 * 1024 * 1024 else { continue }
                recent.append((log, modified, size))
            }
        }
        let states = recent.sorted { $0.modified > $1.modified }.prefix(4).compactMap { log -> AgentTaskState? in
            let stamp = "\(log.modified.timeIntervalSince1970)-\(log.size)"
            cacheLock.lock()
            let hit = cache[log.path]
            cacheLock.unlock()
            if let hit, hit.stamp == stamp { return hit.state }
            guard let output = AgentBackgroundScanner.command("/usr/bin/env", ["ELECTRON_RUN_AS_NODE=1", app, "-e", zstdEvents, log.path],
                                                              timeout: 2, maxBytes: 256 * 1024) else { return nil }
            let state = deepSeek(events: output.split(separator: "\n"))
            cacheLock.lock()
            cache[log.path] = (stamp, state)
            cacheLock.unlock()
            return state
        }
        return states.isEmpty ? nil : combined(states)
    }
}

extension AgentAppSessionState {
    static func cli(provider: String, home: URL, since: Date?, pids: [Int32], runningShell: Bool) -> AgentTaskState? {
        switch provider {
        case "Cline": return cline(home: home, since: since, pids: Set(pids))
        case "Qwen Code": return qwen(home: home, since: since, runningShell: runningShell)
        default: return nil
        }
    }

    /// Cline records each session's `pid` and `status`: pending at an approval, running, idle.
    static func cline(session: [String: Any], pids: Set<Int32>) -> AgentTaskState? {
        guard let pid = session["pid"] as? Int, pids.contains(Int32(pid)) else { return nil }
        switch session["status"] as? String {
        case "pending": return .waiting
        case "running": return .working
        case "idle": return .idle
        default: return nil
        }
    }

    static func cline(home: URL, since: Date?, pids: Set<Int32>) -> AgentTaskState? {
        let fm = FileManager.default
        // The CLI keeps sessions in ~/.cline/data/sessions; CLINE_DIR setups use <dir>/sessions.
        let files = [".cline/data/sessions", ".cline/sessions"].map { home.appendingPathComponent($0) }
            .flatMap { root in ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).map { root.appendingPathComponent($0).appendingPathComponent("\($0).json") } }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                      date >= (since ?? .distantPast) else { return nil }
                return (url, date)
            }
            .sorted { $0.1 > $1.1 }.prefix(8)
        for (url, _) in files {
            if let data = try? Data(contentsOf: url),
               let session = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let state = cline(session: session, pids: pids) { return state }
        }
        return nil
    }

    static let qwenReadOnlyTools: Set<String> = ["read_file", "read_many_files", "list_directory", "glob", "search_file_content",
                                                 "grep_search", "web_fetch", "web_search", "google_web_search", "todo_write", "save_memory"]

    /// Qwen Code logs the model's tool call, and the tool result only once it is approved and has run.
    static func qwen<S: StringProtocol>(lines: [S], runningShell: Bool) -> AgentTaskState? {
        var pending = false
        for line in lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(String(line).utf8)) as? [String: Any] else { continue }
            switch record["type"] as? String {
            case "assistant":
                let parts = (record["message"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                pending = parts.contains { part in
                    guard let name = (part["functionCall"] as? [String: Any])?["name"] as? String else { return false }
                    return !qwenReadOnlyTools.contains(name)
                }
            case "tool_result", "user": pending = false
            default: break
            }
        }
        guard pending else { return nil }
        return runningShell ? .working : .waiting
    }

    static func qwen(home: URL, since: Date?, runningShell: Bool) -> AgentTaskState? {
        let root = home.appendingPathComponent(".qwen/projects")
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        var newest: (URL, Date)?
        for project in projects {
            let chats = root.appendingPathComponent(project).appendingPathComponent("chats")
            for file in (try? fm.contentsOfDirectory(atPath: chats.path)) ?? [] where file.hasSuffix(".jsonl") {
                let url = chats.appendingPathComponent(file)
                if let date = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                   date >= (since ?? .distantPast), date > (newest?.1 ?? .distantPast) { newest = (url, date) }
            }
        }
        guard let url = newest?.0, let text = tail(of: url, bytes: 256 * 1024) else { return nil }
        return qwen(lines: text.split(separator: "\n"), runningShell: runningShell)
    }
}
