// Fixture-only tests. Does not run ps/lsof, inspect real transcripts, or launch
// the user app. Compile with Sources/{AgentTaskState,AgentMonitor}.swift.
import Foundation

@MainActor
enum Diagnostics { static func log(_ message: String) {} }

@main
struct AgentTaskStateTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }
    private static func jsonl(_ rows: [[String: Any]]) -> Data {
        var data = Data()
        for row in rows { data.append(try! JSONSerialization.data(withJSONObject: row)); data.append(0x0A) }
        return data
    }
    private static func line(_ row: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: row), as: UTF8.self)
    }
    private static func fixture(_ label: String, _ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakely-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private static func registryIndex(_ root: URL) -> URL {
        root.appendingPathComponent(".claude/session_index.jsonl")
    }
    private static func loadRegistry(_ home: URL, _ environment: [String: String] = [:]) -> ClaudeRegistrySnapshot {
        ClaudeSessionRegistry.load(home: home, environment: environment)
    }
    private static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)!
    }
    private static func codex(_ events: [String]) -> AgentSessionSnapshot {
        let meta: [String: Any] = ["type": "session_meta", "payload": ["id": "test-session", "cwd": "/fixture/project"]]
        let rows: [[String: Any]] = [meta] + events.map { ["type": "event_msg", "timestamp": "2026-01-01T12:00:00Z", "payload": ["type": $0]] }
        let data = jsonl(rows)
        return AgentTaskAdapter.snapshot(provider: "Codex", header: data, tail: data, tailStartsMidLine: false)
    }
    private static func claude(_ rows: [[String: Any]]) -> AgentSessionSnapshot {
        let metadata: [String: Any] = ["type": "system", "sessionId": "claude-test", "cwd": "/fixture/claude"]
        let data = jsonl([metadata] + rows)
        return AgentTaskAdapter.snapshot(provider: "Claude Code", header: data, tail: data, tailStartsMidLine: false)
    }

    static func main() throws {
        expect(codex([]).state == .unknown, "process/session metadata alone is unknown")
        expect(codex(["task_started"]).state == .working, "Codex task started")
        expect(codex(["task_started", "task_complete"]).state == .idle, "Codex task completion")
        expect(codex(["task_started", "turn_aborted"]).state == .idle, "Codex aborted turn is idle")
        expect(codex(["task_started", "exec_approval_request"]).state == .waiting, "explicit exec approval")
        expect(codex(["apply_patch_approval_request"]).state == .waiting, "explicit patch approval")
        expect(codex(["approval_request", "task_started"]).state == .working, "next explicit start exits waiting")
        expect(codex(["agent_message", "exec_command_begin"]).state == .unknown, "tool/message events don't invent work or waiting")
        expect(codex(["task_started"]).sessionID == "test-session", "Codex metadata session ID")
        expect(codex([]).cwd == "/fixture/project", "Codex metadata cwd")

        expect(claude([["type": "user", "message": ["content": "fixture"]]]).state == .working, "Claude user starts work")
        expect(claude([["type": "user"], ["type": "assistant", "message": ["stop_reason": "end_turn"]]]).state == .idle, "Claude end_turn idles")
        expect(claude([["type": "user"], ["type": "assistant", "message": ["stop_reason": "tool_use"]]]).state == .working, "Claude tool_use not waiting")
        expect(claude([["type": "user"], ["type": "system", "subtype": "turn_duration"]]).state == .idle, "Claude turn_duration idles")
        expect(claude([["type": "approval_request"]]).state == .waiting, "Claude explicit approval")
        expect(claude([["type": "assistant", "message": ["content": "waiting for approval"]]]).state == .unknown, "message text not state")
        expect(claude([["type": "progress", "data": ["type": "approval_request"]]]).state == .unknown, "unknown nested schema ignored")
        expect(claude([]).sessionID == "claude-test", "Claude metadata session ID")
        let malformed = Data("not json\n{}\n{\"type\":\"user\"}".utf8)
        expect(AgentTaskAdapter.snapshot(provider: "Claude Code", header: Data(), tail: malformed, tailStartsMidLine: false).state == .unknown, "partial trailing line excluded")
        let partial = Data("garbage\n{\"type\":\"user\"}\n".utf8)
        expect(AgentTaskAdapter.snapshot(provider: "Claude Code", header: Data(), tail: partial, tailStartsMidLine: true).state == .working, "partial initial line excluded")
        expect(AgentTaskAdapter.snapshot(provider: "OpenCode", header: Data(), tail: jsonl([["type": "user"]]), tailStartsMidLine: false).state == .unknown, "unsupported provider never inferred working")

        expect(AgentProcessDescriptor.provider(executable: "/opt/bin/claude", arguments: ["claude", "--wait"]) == "Claude Code", "recognize executable not arbitrary arg state")
        expect(AgentProcessDescriptor.provider(executable: "/bin/echo", arguments: ["claude", "waiting"]) == nil, "prompt mentions not process")
        expect(AgentProcessDescriptor.provider(executable: "/bin/claude-helper", arguments: []) == nil, "substring executable not enough")
        expect(AgentProcessDescriptor.provider(executable: "/opt/bin/node", arguments: ["node", "/fixture/node_components/@openai/codex/bin/codex.js"]) == "Codex", "known Node Codex entrypoint")
        expect(AgentProcessDescriptor.explicitSessionID(arguments: ["codex", "resume", "abc-123"]) == "abc-123", "Codex resume ID")
        expect(AgentProcessDescriptor.explicitSessionID(arguments: ["claude", "--resume=abc-123"]) == "abc-123", "Claude resume ID")
        expect(AgentProcessDescriptor.explicitSessionID(arguments: ["claude", "--session-id", "abc-123"]) == "abc-123", "Claude session ID")
        expect(AgentProcessDescriptor.explicitSessionID(arguments: ["claude", "--resume", "--verbose"]) == nil, "resume boolean not ID")
        expect(AgentProcessDescriptor.explicitSessionID(arguments: ["codex", "resume", "latest"]) == nil, "resume latest isn't actual ID")
        let now = ISO8601DateFormatter().date(from: "2026-01-01T12:00:01Z")!
        let started = now.addingTimeInterval(-60)
        let process = AgentProcessDescriptor(pid: 123, provider: "Codex", sessionID: "test-session", cwd: nil, startedAt: started)
        expect(AgentTaskCorrelation.state(for: process, sessions: [codex(["task_started"])], processes: [process]) == .working, "exact active process session match")
        let noMatch = AgentProcessDescriptor(pid: 124, provider: "Codex", sessionID: "other", cwd: "/fixture/project", startedAt: started)
        expect(AgentTaskCorrelation.state(for: noMatch, sessions: [codex(["task_started"])], processes: [noMatch]) == .unknown, "explicit ID mismatch doesn't fall back to cwd")
        let cwd = AgentProcessDescriptor(pid: 125, provider: "Codex", sessionID: nil, cwd: "/fixture/project", startedAt: started)
        expect(AgentTaskCorrelation.state(for: cwd, sessions: [codex(["task_started"])], processes: [cwd]) == .working, "fresh unique cwd correlation")
        let peer = AgentProcessDescriptor(pid: 126, provider: "Codex", sessionID: nil, cwd: "/fixture/project", startedAt: started)
        expect(AgentTaskCorrelation.state(for: cwd, sessions: [codex(["task_started"])], processes: [cwd, peer]) == .unknown, "multiple CLI processes same cwd ambiguous")
        let staleProcess = AgentProcessDescriptor(pid: 123, provider: "Codex", sessionID: "test-session", cwd: nil, startedAt: now.addingTimeInterval(120))
        expect(AgentTaskCorrelation.state(for: staleProcess, sessions: [codex(["task_started"])], processes: [staleProcess]) == .unknown, "old unfinished task not resurrected on resume")
        let staleCwd = AgentProcessDescriptor(pid: 123, provider: "Codex", sessionID: nil, cwd: "/fixture/project", startedAt: now.addingTimeInterval(120))
        expect(AgentTaskCorrelation.state(for: staleCwd, sessions: [codex(["task_started"])], processes: [staleCwd]) == .unknown, "stale cwd session excluded")
        var another = codex(["task_started"])
        another.sessionID = "second-session"
        expect(AgentTaskCorrelation.state(for: cwd, sessions: [codex(["task_started"]), another], processes: [cwd]) == .unknown, "multiple sessions same cwd ambiguous")

        let working = AgentThread(id: "same", provider: "Codex", pid: 1, state: .working)
        let waiting = AgentThread(id: "same", provider: "Codex", pid: 1, state: .waiting)
        let idle = AgentThread(id: "same", provider: "Codex", pid: 1, state: .idle)
        let unknown = AgentThread(id: "same", provider: "Codex", pid: 1, waiting: false)
        expect(working != waiting && waiting != idle, "same PID state transitions compare different")
        expect(working.working && !waiting.working && !idle.working && !unknown.working, "only working counted working")
        expect(waiting.waiting && !working.waiting && !unknown.waiting, "only explicit waiting counted waiting")
        expect(unknown.state == .unknown, "legacy nonwaiting initializer not working")
        expect(AgentThread.finishedTransitions(from: [working], to: [idle]) == [idle], "working to explicit idle finishes")
        expect(AgentThread.finishedTransitions(from: [waiting], to: [idle]) == [idle], "waiting to explicit idle finishes")
        expect(AgentThread.finishedTransitions(from: [working], to: []).isEmpty, "process loss is not proven completion")
        expect(AgentThread.finishedTransitions(from: [working], to: [unknown]).isEmpty, "lost transcript not completion")
        expect(AgentThread.finishedTransitions(from: [unknown], to: [idle]).isEmpty, "unknown to idle not completion")
        expect(AgentThread.finishedTransitions(from: [idle], to: [idle]).isEmpty, "idle scan no duplicate finish")
        let listing = "123 00:30 /opt/bin/claude claude --resume abc-123\n124 01:00 /bin/echo echo codex waiting\n125 1-02:03:04 /bin/codex codex --wait\n"
        let parsed = AgentBackgroundScanner.parseProcesses(listing, now: now)
        expect(parsed.count == 2 && parsed[0].sessionID == "abc-123", "process parsing exact provider and session")
        expect(parsed[0].startedAt == now.addingTimeInterval(-30), "elapsed process start parsed")
        let dayElapsed: TimeInterval = 93_784
        expect(parsed[1].startedAt == now.addingTimeInterval(-dayElapsed), "day elapsed parsed")

        // macOS `comm` is cut to 16 characters; a full-path launch must still match,
        // and Codex's app-server daemon must not count as an agent.
        let truncated = """
        200 1 00:45 /opt/homebrew/li /opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex fix the tests
        201 200 00:44 /Users/dev/.cod /Users/dev/.codex/packages/app-server-daemon/releases/0.170.0/bin/codex app-server --listen unix://
        202 1 00:10 /usr/local/bin/n /usr/local/bin/nothing-codex codex
        203 1 00:05 /opt/homebrew/li /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
        """
        let others = "300 00:05 pi pi\n301 00:05 /usr/local/bin/c /usr/local/bin/cursor-agent -p fix\n302 00:05 aider aider --model x\n303 00:05 dsh dsh\n304 00:05 qwen qwen\n305 00:05 kilo kilo\n306 00:05 amp amp\n307 00:05 cline cline\n308 00:05 pip pip install\n309 00:05 hermes hermes\n"
        let otherProviders = AgentBackgroundScanner.parseProcesses(others, now: now).map(\.provider)
        expect(otherProviders == ["Pi", "Cursor Agent", "Aider", "DeepSeek Harness", "Qwen Code", "Kilo", "Amp", "Cline", "Hermes Agent"], "process-only agents recognized by name")
        let cpu = "10 1 0.4\n11 10 0.0\n20 1 0.3\n21 20 0.2\n22 21 38.5\n30 1 7.0\nbad line\n"
        expect(AgentBackgroundScanner.busyAgents(pids: [10, 20, 30, 40], cpuListing: cpu) == [20, 30], "busy from own or descendant CPU; idle CLI and missing PID are not busy")
        var lastBusy: [String: Date] = [:]
        let busyPi = AgentThread(id: "Pi-5", provider: "Pi", pid: 5, state: .working)
        let quietPi = AgentThread(id: "Pi-5", provider: "Pi", pid: 5, state: .unknown)
        _ = AgentThread.holdingRecentlyBusy([busyPi], lastBusy: &lastBusy, now: now)
        expect(AgentThread.holdingRecentlyBusy([quietPi], lastBusy: &lastBusy, now: now.addingTimeInterval(30))[0].state == .working, "short CPU pause keeps a process-only agent working")
        expect(AgentThread.holdingRecentlyBusy([quietPi], lastBusy: &lastBusy, now: now.addingTimeInterval(61)).isEmpty, "long quiet hides the agent, never claims idle")
        var neverBusy: [String: Date] = [:]
        expect(AgentThread.holdingRecentlyBusy([quietPi], lastBusy: &neverBusy, now: now).isEmpty, "an open but idle process-only agent is not listed")
        expect(AgentThread.finishedTransitions(from: [busyPi], to: [quietPi]).isEmpty, "quiet process-only agent is not a finished task")
        let desktopApp = """
        94237 1 01:10 /Applications/De /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness
        94238 94237 01:10 /Applications/De /Applications/DeepSeek Harness.app/Contents/Frameworks/DeepSeek Harness Helper.app/Contents/MacOS/DeepSeek Harness Helper --type=gpu-process
        94248 94237 01:09 /Applications/De /Applications/DeepSeek Harness.app/Contents/Frameworks/DeepSeek Harness Helper (Renderer).app/Contents/MacOS/DeepSeek Harness Helper (Renderer) --type=renderer
        29670 1 03:00 /opt/homebrew/bi /opt/homebrew/bin/node /Users/apple/dsh workspace/dsh-lan/server.js
        41000 1 00:30 /Applications/Co /Applications/Codex.app/Contents/MacOS/Codex
        41001 1 00:30 /Applications/Cl /Applications/Claude.app/Contents/MacOS/Claude
        41002 1 00:30 /Applications/Sa /Applications/Safari.app/Contents/MacOS/Safari
        """
        let app = AgentBackgroundScanner.parseProcesses(desktopApp, now: now)
        expect(app.map(\.pid) == [41000, 41001, 94237] && app.map(\.provider) == ["Codex App", "Claude", "DeepSeek Harness"], "DeepSeek Harness desktop app matched by its spaced bundle path; helpers and dsh-named folders ignored")
        let full = AgentBackgroundScanner.parseProcesses(truncated, now: now)
        expect(full.count == 2 && full[0].pid == 200 && full[0].provider == "Codex" && full[1].pid == 203 && full[1].provider == "Claude Code", "truncated comm recovered from argv0; claude.exe matched; app-server skipped")

        // Claude registry adapter: absent, malformed, unknown keys, duplicates.
        try fixture("registry-absent") { root in
            let snapshot = loadRegistry(root)
            expect(snapshot.isEmpty, "absent registry root is empty")
            expect(snapshot.record(sessionID: "anything") == nil, "absent registry has no session")
        }

        try fixture("registry-malformed") { root in
            let text = [
                "not json",
                "[]",
                "{\"sessionId\":\"s-mal\",\"unknownKey\":{\"nested\":true}}",
                "{\"sessionId\":42}",
                line(["sessionId": "s-ok", "status": "busy", "cwd": "/fixture/project",
                      "statusUpdatedAt": 1_700_000_000]),
            ].joined(separator: "\n") + "\n"
            try write(text, to: registryIndex(root))
            let snapshot = loadRegistry(root)
            expect(snapshot.count == 2, "malformed and non-object lines ignored")
            expect(snapshot.record(sessionID: "s-ok")?.status == .busy, "registry status recognized")
            expect(snapshot.record(sessionID: "s-ok")?.statusUpdatedAt
                   == Date(timeIntervalSince1970: 1_700_000_000), "epoch seconds parsed")
            expect(snapshot.record(sessionID: "s-mal") != nil, "unknown keys tolerated")
        }

        try fixture("registry-duplicate") { root in
            let text = [
                line(["sessionId": "dup", "chosenName": "Old", "statusUpdatedAt": 1_700_000_000]),
                line(["sessionId": "dup", "chosenName": "New", "statusUpdatedAt": 1_700_000_100]),
            ].joined(separator: "\n") + "\n"
            try write(text, to: registryIndex(root))
            let snapshot = loadRegistry(root)
            expect(snapshot.count == 1, "duplicate session IDs collapse")
            expect(snapshot.record(sessionID: "dup")?.chosenName == "New", "newest duplicate record wins")
        }

        try fixture("registry-names") { root in
            let text = [
                line(["sessionId": "s-derived", "chosenName": "derived", "nameSource": "derived",
                      "cwd": "/fixture/My Project", "statusUpdatedAt": 1_700_000_000]),
                line(["sessionId": "s-chosen", "chosenName": "  Fix login  ", "cwd": "/fixture/one"]),
                line(["sessionId": "s-generated", "name": "Generated title", "nameSource": "generated"]),
                line(["sessionId": "abcdef123456"]),
            ].joined(separator: "\n") + "\n"
            try write(text, to: registryIndex(root))
            let snapshot = loadRegistry(root)
            let derived = ClaudeSessionRegistry.displayName(
                provider: "Claude Code",
                record: snapshot.record(sessionID: "s-derived"),
                sessionID: "s-derived", cwd: "/fixture/My Project")
            expect(derived.name == "Claude Code — My Project", "derived sentinel falls back to cwd basename")
            expect(derived.source == .derived, "derived name source recorded")
            let chosen = ClaudeSessionRegistry.displayName(
                provider: "Claude Code",
                record: snapshot.record(sessionID: "s-chosen"),
                sessionID: "s-chosen", cwd: "/fixture/one")
            expect(chosen.name == "Fix login", "chosen name trimmed and preferred")
            expect(chosen.source == .chosen, "chosen name source recorded")
            let generated = ClaudeSessionRegistry.displayName(
                provider: "Claude Code",
                record: snapshot.record(sessionID: "s-generated"),
                sessionID: "s-generated", cwd: nil)
            expect(generated.name == "Generated title", "provided non-derived name used")
            expect(generated.source == .generated, "generated name source recorded")
            let suffix = ClaudeSessionRegistry.derivedDisplayName(
                provider: "Claude Code", cwd: nil, sessionID: "abcdef123456")
            expect(suffix.name == "Claude Code — session 3456", "session suffix fallback")
        }

        try fixture("registry-truncated") { root in
            let text = line(["sessionId": "s-complete", "chosenName": "Complete"]) + "\n"
                + "{\"sessionId\":\"s-partial\",\"chosenName\":\"Par"
            try write(text, to: registryIndex(root))
            let snapshot = loadRegistry(root)
            expect(snapshot.record(sessionID: "s-complete") != nil, "complete registry line parsed")
            expect(snapshot.record(sessionID: "s-partial") == nil, "truncated registry line ignored")
        }

        var sameCwd = ClaudeRegistrySnapshot()
        var firstCwd = ClaudeRegistryRecord()
        firstCwd.sessionID = "cwd-a"; firstCwd.cwd = "/fixture/shared"
        var secondCwd = ClaudeRegistryRecord()
        secondCwd.sessionID = "cwd-b"; secondCwd.cwd = "/fixture/shared"
        sameCwd.insert(firstCwd); sameCwd.insert(secondCwd)
        expect(sameCwd.record(cwd: "/fixture/shared") == nil, "duplicate cwd ambiguous")
        expect(sameCwd.record(cwd: "/fixture/unique") == nil, "unknown cwd has no record")

        try fixture("registry-huge") { root in
            let data = Data(repeating: 0x41, count: ClaudeSessionRegistry.fileByteLimit + 1024)
            try FileManager.default.createDirectory(at: registryIndex(root).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: registryIndex(root))
            expect(loadRegistry(root).isEmpty, "over-cap registry file ignored")
        }

        try fixture("registry-long-line") { root in
            let huge = String(repeating: "A", count: ClaudeSessionRegistry.lineByteLimit + 1024)
            let text = "{\"sessionId\":\"s-big\",\"name\":\"\(huge)\"}\n"
                + line(["sessionId": "s-small", "chosenName": "Small"]) + "\n"
            try write(text, to: registryIndex(root))
            let snapshot = loadRegistry(root)
            expect(snapshot.record(sessionID: "s-big") == nil, "over-cap registry line ignored")
            expect(snapshot.record(sessionID: "s-small")?.chosenName == "Small", "following normal line parsed")
        }

        try fixture("registry-symlink-root") { root in
            let target = root.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try write(line(["sessionId": "s-hidden", "chosenName": "Hidden"]) + "\n",
                      to: target.appendingPathComponent("session_index.jsonl"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".claude"),
                                                       withDestinationURL: target)
            expect(loadRegistry(root).isEmpty, "symlinked candidate root refused")
        }

        try fixture("registry-symlink-file") { root in
            let target = root.appendingPathComponent("outside.jsonl")
            try write(line(["sessionId": "s-hidden", "chosenName": "Hidden"]) + "\n", to: target)
            let link = registryIndex(root)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            expect(loadRegistry(root).isEmpty, "symlinked registry file refused")
        }

        try fixture("registry-env-symlink") { root in
            let target = root.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try write(line(["sessionId": "s-hidden", "chosenName": "Hidden"]) + "\n",
                      to: target.appendingPathComponent("session_index.jsonl"))
            let link = root.appendingPathComponent("custom")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            expect(loadRegistry(root, ["CLAUDE_CONFIG_DIR": link.path]).isEmpty,
                   "symlinked CLAUDE_CONFIG_DIR refused")
        }

        try fixture("registry-env-order") { root in
            let custom = root.appendingPathComponent("custom-config", isDirectory: true)
            try write(line(["sessionId": "s-custom", "chosenName": "Custom"]) + "\n",
                      to: custom.appendingPathComponent("session_index.jsonl"))
            try write(line(["sessionId": "s-home", "chosenName": "Home"]) + "\n", to: registryIndex(root))
            let snapshot = loadRegistry(root, ["CLAUDE_CONFIG_DIR": custom.path])
            expect(snapshot.count == 2, "both candidate roots read")
            expect(snapshot.records.first?.sessionID == "s-custom", "CLAUDE_CONFIG_DIR is first")
        }

        var busyClaim = ClaudeRegistryRecord()
        busyClaim.status = .busy
        busyClaim.statusUpdatedAt = now
        let claudeProcess = AgentProcessDescriptor(pid: 42, provider: "Claude Code", sessionID: nil,
                                                   cwd: nil, startedAt: now.addingTimeInterval(-10))
        expect(ClaudeSessionRegistry.claimedState(for: busyClaim, process: claudeProcess) == .working,
               "fresh registry busy claim")
        busyClaim.statusUpdatedAt = now.addingTimeInterval(-100)
        expect(ClaudeSessionRegistry.claimedState(for: busyClaim, process: claudeProcess) == nil,
               "stale registry claim ignored")
        busyClaim.status = .idle
        busyClaim.statusUpdatedAt = now
        expect(ClaudeSessionRegistry.claimedState(for: busyClaim, process: claudeProcess) == nil,
               "registry idle never invents completion")

        var samePID = ClaudeRegistrySnapshot()
        var firstPID = ClaudeRegistryRecord()
        firstPID.sessionID = "a"; firstPID.pid = 42
        var secondPID = ClaudeRegistryRecord()
        secondPID.sessionID = "b"; secondPID.pid = 42
        samePID.insert(firstPID); samePID.insert(secondPID)
        expect(samePID.record(pid: 42, processStart: nil) == nil, "duplicate PID ambiguous")
        var uniquePID = ClaudeRegistrySnapshot()
        var onlyPID = ClaudeRegistryRecord()
        onlyPID.sessionID = "c"; onlyPID.pid = 43
        onlyPID.processStart = Date(timeIntervalSince1970: 1_700_000_000)
        uniquePID.insert(onlyPID)
        expect(uniquePID.record(pid: 43, processStart: Date(timeIntervalSince1970: 1_700_000_010)) == nil,
               "PID reuse rejected by process start")
        expect(uniquePID.record(pid: 43, processStart: Date(timeIntervalSince1970: 1_700_000_001)) != nil,
               "matching process start accepted")

        // Transcript-derived display activity. Fixtures only; no real files.
        let completedScreenshot = claude([
            ["type": "assistant", "timestamp": "2026-01-01T12:00:00Z",
             "message": ["content": [["type": "tool_use", "id": "tool-1",
                                      "name": "mcp__computer__screenshot"]]]],
            ["type": "user", "timestamp": "2026-01-01T12:00:05Z",
             "message": ["content": [["type": "tool_result", "tool_use_id": "tool-1"]]]],
        ])
        expect(completedScreenshot.activity?.tool == "mcp__computer__screenshot", "Claude tool name tracked")
        expect(completedScreenshot.activity?.isActive == false, "matching tool_result completes the call")
        expect(completedScreenshot.activity?.endedAt == date("2026-01-01T12:00:05Z"),
               "completion timestamp retained")
        let activeTool = claude([
            ["type": "assistant", "timestamp": "2026-01-01T12:00:00Z",
             "message": ["content": [["type": "tool_use", "id": "tool-2", "name": "browser_navigate"]]]],
        ])
        expect(activeTool.activity?.isActive == true, "unmatched tool_use stays active")
        expect(activeTool.activity?.tool == "browser_navigate", "browser tool name tracked")
        let mismatchedResult = claude([
            ["type": "assistant", "timestamp": "2026-01-01T12:00:00Z",
             "message": ["content": [["type": "tool_use", "id": "tool-3", "name": "computer_click"]]]],
            ["type": "user", "timestamp": "2026-01-01T12:00:05Z",
             "message": ["content": [["type": "tool_result", "tool_use_id": "other-call"]]]],
        ])
        expect(mismatchedResult.activity?.isActive == true, "mismatched result does not end tracked call")
        let sidechain = claude([
            ["type": "assistant", "isSidechain": true, "timestamp": "2026-01-01T12:00:00Z",
             "message": ["content": [["type": "tool_use", "id": "tool-4", "name": "computer_click"]]]],
        ])
        expect(sidechain.activity == nil, "sidechain activity ignored")
        let interrupted = claude([
            ["type": "assistant", "timestamp": "2026-01-01T12:00:00Z",
             "message": ["content": [["type": "tool_use", "id": "tool-5", "name": "computer_click"]]]],
            ["type": "user", "timestamp": "2026-01-01T12:00:30Z",
             "message": ["content": "a new prompt"]],
        ])
        expect(interrupted.activity == nil, "new prompt discards an interrupted call")

        let codexMeta: [String: Any] = ["type": "session_meta",
                                        "payload": ["id": "codex-activity", "cwd": "/fixture/codex"]]
        let codexData = jsonl([
            codexMeta,
            ["type": "event_msg", "timestamp": "2026-01-01T12:00:00Z",
             "payload": ["type": "exec_command_begin", "call_id": "c1"]],
            ["type": "event_msg", "timestamp": "2026-01-01T12:00:02Z",
             "payload": ["type": "exec_command_end", "call_id": "c1"]],
        ])
        let codexActivity = AgentTaskAdapter.snapshot(provider: "Codex", header: codexData,
                                                      tail: codexData, tailStartsMidLine: false)
        expect(codexActivity.activity?.tool == "exec_command", "Codex tool name tracked")
        expect(codexActivity.activity?.isActive == false, "exec end completes the call")
        let mcpData = jsonl([
            codexMeta,
            ["type": "event_msg", "timestamp": "2026-01-01T12:00:00Z",
             "payload": ["type": "mcp_tool_call_begin", "call_id": "m1",
                          "server": "chrome", "tool": "browser_navigate"]],
            ["type": "event_msg", "timestamp": "2026-01-01T12:00:01Z",
             "payload": ["type": "mcp_tool_call_completed", "call_id": "m1"]],
        ])
        let mcpActivity = AgentTaskAdapter.snapshot(provider: "Codex", header: mcpData,
                                                     tail: mcpData, tailStartsMidLine: false)
        expect(mcpActivity.activity?.tool == "chrome browser_navigate", "MCP server/tool tracked")
        expect(mcpActivity.activity?.isActive == false, "MCP completion ends the call")
        let interruptedCodex = jsonl([
            codexMeta,
            ["type": "event_msg", "timestamp": "2026-01-01T12:00:00Z",
             "payload": ["type": "exec_command_begin", "call_id": "c2"]],
            ["type": "event_msg", "timestamp": "2026-01-01T12:00:05Z",
             "payload": ["type": "turn_aborted"]],
        ])
        let interruptedCodexSnapshot = AgentTaskAdapter.snapshot(
            provider: "Codex", header: interruptedCodex, tail: interruptedCodex, tailStartsMidLine: false)
        expect(interruptedCodexSnapshot.activity == nil,
               "Codex task boundary discards an interrupted call")
        let unknownCodex = jsonl([
            codexMeta,
            ["type": "event_msg", "timestamp": "2026-01-01T12:00:00Z",
             "payload": ["type": "mcp_tool_call_progress", "call_id": "x"]],
        ])
        expect(AgentTaskAdapter.snapshot(provider: "Codex", header: unknownCodex,
                                         tail: unknownCodex, tailStartsMidLine: false).activity == nil,
               "unknown Codex event shape ignored")

        let namedThread = AgentThread(id: "same", provider: "Codex", pid: 1, state: .working,
                                      displayName: "Named")
        let renamedThread = AgentThread(id: "same", provider: "Codex", pid: 1, state: .working,
                                        displayName: "Other")
        expect(namedThread != renamedThread, "identity change detected by Equatable")
        var timestampedThread = working
        timestampedThread.updatedAt = now
        expect(timestampedThread != working, "metadata change detected by Equatable")

        // File traversal is exercised only against our temporary fixture tree.
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("wakely-agent-fixtures-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent(".codex/sessions/2026/01/01"), withIntermediateDirectories: true)
        let path = fixture.appendingPathComponent(".codex/sessions/2026/01/01/fixture.jsonl")
        try jsonl([["type": "session_meta", "payload": ["id": "fixture", "cwd": "/fixture/project"]], ["type": "event_msg", "payload": ["type": "task_complete"]]]).write(to: path)
        let fixtureStates = AgentSessionFiles.snapshots(home: fixture, processes: [process])
        expect(fixtureStates.count == 1 && fixtureStates[0].state == .idle, "bounded fixture directory scan")
        // Remove only the explicit UUID fixture root created above.
        try FileManager.default.removeItem(at: fixture)
        print("PASS: \(checks) fixture-only agent task-state checks")
    }
}
