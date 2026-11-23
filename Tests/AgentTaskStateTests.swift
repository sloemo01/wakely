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

    private static func claudeDesktopSidebar() {
        let waiting = ClaudeDesktopSidebar.row(texts: ["Swift compilation", "Awaiting input", "Cloud"])
        expect(waiting == ClaudeDesktopSidebar.Row(title: "Swift compilation", state: .waiting, cloud: true),
               "a cloud session awaiting input is waiting")
        expect(ClaudeDesktopSidebar.row(texts: ["Fix tests", "Running", "Cloud"])?.state == .working, "a running session is working")
        expect(ClaudeDesktopSidebar.row(texts: ["Fix tests", "Needs approval", "Cloud"])?.state == .waiting, "an approval prompt is waiting")
        expect(ClaudeDesktopSidebar.row(texts: ["Attribution toggle", "Cloud"]) == nil, "a session without a status is not shown")
        expect(ClaudeDesktopSidebar.row(texts: ["New"]) == nil, "navigation buttons are ignored")
        expect(ClaudeDesktopSidebar.row(texts: ["Fix tests", "Archived", "Cloud"]) == nil, "an unknown status stays unshown")
        expect(ClaudeDesktopSidebar.row(texts: ["", "Running"]) == nil, "an untitled row is ignored")
        expect(ClaudeDesktopSidebar.row(texts: ["Waiting", "Swift compilation", "Asked a question"]) == nil,
               "the open session's banner is not a second row")
        expect(ClaudeDesktopSidebar.row(texts: ["Thinking", "Awaiting input", "Cloud"])?.state == .waiting,
               "a cloud session titled with a status word is still read")
        let local = ClaudeDesktopSidebar.row(texts: ["Sleep test", "Running"])
        expect(local?.cloud == false, "a local session is not a cloud session")
        var covered = AgentThread(id: "claude-1", provider: "Claude", pid: 9, state: .idle, displayName: "Sleep test")
        covered.isApp = true
        let cli = AgentThread(id: "cc-1", provider: "Claude Code", pid: 11, state: .idle, displayName: "Swift compilation")
        let merged = ClaudeDesktopSidebar.merge([waiting!, local!, ClaudeDesktopSidebar.Row(title: "Swift compilation", state: .working, cloud: true)],
                                               into: [covered, cli], pid: 7)
        expect(merged.count == 4, "each sidebar session is listed once")
        expect(merged.first { $0.id == "claude-1" }?.state == .working, "a local session the registry calls idle takes the sidebar's Running")
        expect(merged.first { $0.id == "cc-1" }?.state == .idle, "a terminal Claude Code session is left alone")
        let cloud = merged.first { $0.id == "claude-desktop-Swift compilation" }
        expect(cloud?.state == .waiting && cloud?.isApp == true && cloud?.provider == "Claude" && cloud?.pid == 7,
               "a cloud session becomes its own Claude app row")
        let twins = ClaudeDesktopSidebar.merge([waiting!, waiting!, local!], into: [covered], pid: 7)
        expect(twins.count == 3 && Set(twins.map(\.id)).count == 3, "sessions sharing a title each keep a row")
    }

    static func main() throws {
        try claudeLiveSessions()
        claudeDesktopSidebar()
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
        41003 1 00:30 /opt/homebrew/bi /opt/homebrew/bin/codex --cd /Applications/Claude.app/Contents/MacOS/Claude
        41004 1 00:30 /Users/a/My - Ap /Users/a/My - Apps/Cursor.app/Contents/MacOS/Cursor
        41005 1 00:30 /usr/bin/rsync /usr/bin/rsync --exclude=/Applications/Cursor.app/Contents/MacOS/Cursor
        """
        let installed: Set<String> = ["/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness",
                                      "/Applications/Codex.app/Contents/MacOS/Codex", "/Applications/Claude.app/Contents/MacOS/Claude",
                                      "/Applications/Safari.app/Contents/MacOS/Safari", "/Users/a/My - Apps/Cursor.app/Contents/MacOS/Cursor",
                                      "/Applications/Cursor.app/Contents/MacOS/Cursor"]
        let app = AgentBackgroundScanner.parseProcesses(desktopApp, now: now, isExecutable: installed.contains)
        expect(app.map(\.pid) == [41000, 41001, 41003, 41004, 94237] && app.map(\.provider) == ["Codex App", "Claude", "Codex", "Cursor", "DeepSeek Harness"], "DeepSeek Harness desktop app matched by its spaced bundle path; helpers and dsh-named folders ignored")
        let host = "94237 1 01:10 /Applications/De /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness\n" +
            "94300 94237 01:09 /Applications/De /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness --expose-internals /Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js"
        expect(AgentBackgroundScanner.distinct(AgentBackgroundScanner.parseProcesses(host, now: now, isExecutable: installed.contains)).map(\.pid) == [94237],
               "an app re-running its own executable as a Node host is one row")
        let scripts = """
        51000 1 00:30 node node /opt/homebrew/bin/qwen
        51001 1 00:30 node node /opt/homebrew/bin/pi --mode text
        51002 1 00:30 node node /opt/homebrew/bin/cline
        51003 1 00:30 python3.12 /Users/a/.venv/bin/python3.12 /Users/a/.venv/bin/aider --model x
        51004 1 00:30 node node /tmp/build.js qwen
        """
        let clis = AgentBackgroundScanner.parseProcesses(scripts, now: now, isExecutable: { _ in false })
        expect(clis.map(\.provider) == ["Qwen Code", "Pi", "Cline", "Aider"] && !clis.contains(where: \.isApp),
               "node and python CLIs are matched by their script path, never by a bare argument")
        let dsh = "94237 1 01:10 /Applications/De /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness\n" +
            "95000 900 00:20 /Applications/De /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness --expose-internals /Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/cli.js\n" +
            "95001 95000 00:19 /Applications/De /Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness --expose-internals /Applications/DeepSeek Harness.app/Contents/Resources/app.asar/dsh/node_modules/@deepseek-ai/dsh-desktop-host/lib/index.js"
        let dshRows = AgentBackgroundScanner.distinct(AgentBackgroundScanner.parseProcesses(dsh, now: now, isExecutable: installed.contains))
        expect(dshRows.map(\.pid) == [94237, 95000] && dshRows.map(\.isApp) == [true, false],
               "the dsh CLI bundled in DeepSeek Harness is a CLI row, and its Node host is not another app row")
        let aider = "52000 1 00:30 /opt/homebrew/Ce /opt/homebrew/Cellar/python@3.12/3.12.15/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python /Users/a/.venv/bin/aider --model x"
        let aiderRows = AgentBackgroundScanner.parseProcesses(aider, now: now, isExecutable: { $0.hasSuffix("/MacOS/Python") })
        expect(aiderRows.map(\.provider) == ["Aider"] && aiderRows.map(\.isApp) == [false], "aider under Homebrew's Python.app is the Aider CLI, not an app")
        expect(AgentAppSessionState.cline(session: ["pid": 7, "status": "pending"], pids: [7]) == .waiting, "a Cline approval prompt is waiting")
        expect(AgentAppSessionState.cline(session: ["pid": 7, "status": "running"], pids: [7]) == .working, "a running Cline session is working")
        expect(AgentAppSessionState.cline(session: ["pid": 8, "status": "pending"], pids: [7]) == nil, "another Cline's session is ignored")
        let qwenCall = #"{"type":"assistant","message":{"parts":[{"text":"x"},{"functionCall":{"name":"run_shell_command"}}]}}"#
        let qwenRead = #"{"type":"assistant","message":{"parts":[{"functionCall":{"name":"read_file"}}]}}"#
        expect(AgentAppSessionState.qwen(lines: [qwenCall], runningShell: false) == .waiting, "a Qwen tool call with no result and no shell awaits approval")
        expect(AgentAppSessionState.qwen(lines: [qwenCall], runningShell: true) == .working, "a Qwen tool call with its shell running is working")
        expect(AgentAppSessionState.qwen(lines: [qwenCall, #"{"type":"tool_result"}"#], runningShell: false) == nil, "an answered Qwen tool call is not waiting")
        expect(AgentAppSessionState.qwen(lines: [qwenRead], runningShell: false) == nil, "a read-only Qwen tool never needs approval")
        let start = now.timeIntervalSince1970 * 1000
        let open = #"{"role":"assistant","time":{"created":1}}"#
        let pending = #"{"type":"tool","tool":"bash","state":{"status":"running","time":{"start":\#(start - 10000)}}}"#
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.row(message: open, tool: pending)!, hasChild: false, now: now) == .waiting, "OpenCode running tool with no child is waiting on a permission prompt")
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.row(message: open, tool: pending)!, hasChild: true, now: now) == .working, "OpenCode running tool with a child process is working")
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.row(message: open, tool: nil)!, hasChild: false, now: now) == .working, "OpenCode open assistant turn is working")
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.row(message: #"{"role":"assistant","time":{"created":1,"completed":2},"finish":"stop"}"#, tool: pending)!, hasChild: false, now: now) == .idle, "OpenCode completed turn is idle")
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.row(message: #"{"role":"assistant","time":{"created":1,"completed":2},"finish":"tool-calls"}"#, tool: nil)!, hasChild: false, now: now) == .working, "OpenCode tool-call handoff is still working")
        let fetching = #"{"type":"tool","tool":"webfetch","state":{"status":"running","time":{"start":\#(start - 10000)}}}"#
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.row(message: open, tool: fetching)!, hasChild: false, now: now) == .working, "a long in-process OpenCode tool is working, not waiting")
        let v2Running: [String: Any] = ["role": "assistant", "updated": start - 10000, "busy": start - 11000, "idle": start - 60000,
            "message": #"{"time":{"created":1},"content":[{"type":"tool","name":"shell","state":{"status":"running"}}]}"#]
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.rowV2(v2Running)!, hasChild: false, now: now) == .waiting, "OpenCode 2.x shell tool stalled with no child is waiting")
        var v2Done = v2Running; v2Done["idle"] = start - 1000
        expect(OpenCodeSessionState.state(row: OpenCodeSessionState.rowV2(v2Done)!, hasChild: false, now: now) == .idle, "OpenCode 2.x session idle after busy is idle")
        expect(AgentBackgroundScanner.codexSubcommand(["codex", "-c", "x=1", "app-server", "--listen"]) == "app-server", "Codex app-server behind -c options is skipped")
        expect(AgentBackgroundScanner.codexSubcommand(["codex", "fix", "the", "app-server", "bug"]) == "fix", "a Codex prompt mentioning app-server is a task")
        let launcherDaemon = AgentBackgroundScanner.parseProcesses("42001 1 00:30 /opt/homebrew/bi /opt/homebrew/bin/node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js app-server --listen", now: now)
        expect(launcherDaemon.isEmpty, "a node-launched Codex app-server is not an agent")
        let appHelpers = AgentBackgroundScanner.parseProcesses("""
        76021 1 02:34 /Applications/Ch /Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/157/Helpers/browser_crashpad_handler --monitor-self
        76109 76018 02:29 /Users/devin/.co /Users/devin/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
        """, now: now)
        expect(appHelpers.isEmpty, "Codex app helpers under spaced paths are not Codex CLIs")
        let electron = """
        500 1 30.0 /Applications/Cu
        501 500 20.0 /Applications/Cu
        600 1 1.0 /Applications/Wi
        601 600 0.5 /Applications/Wi
        602 601 40.0 /bin/zsh
        """
        expect(AgentBackgroundScanner.busyAgents(pids: [500, 600], cpuListing: electron, apps: [500: "Cursor", 600: "Windsurf"]) == [600], "an app counts as working only from work outside its bundle")
        let retitled = "700 1 0.5 /Applications/Cu\n701 700 30.0 Cursor Helper (Plugin): extension-host Agents Window [1-1]\n702 700 9.0 Cursor: shared-process"
        let fullComm = "800 1 0.8 /Applications/Cursor.app/Contents/MacOS/Cursor\n801 800 19.8 /Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"
        expect(AgentBackgroundScanner.busyAgents(pids: [800], cpuListing: fullComm, apps: [800: "Cursor"]).isEmpty, "helpers under the app's full bundle path are part of the app")
        func kiroLine(_ type: String, _ extra: String = "") -> String { "{\"id\":\"x\",\"payload\":{\"type\":\"\(type)\"\(extra)}}" }
        expect(AgentAppSessionState.kiro(lines: [kiroLine("turn_start")]) == .working, "an open Kiro turn is working")
        expect(AgentAppSessionState.kiro(lines: [kiroLine("turn_start"), kiroLine("pending_interaction", ",\"interactionType\":\"tool_approval\",\"toolCallId\":\"t1\"")]) == .waiting,
               "an unanswered Kiro approval waits on you")
        expect(AgentAppSessionState.kiro(lines: [kiroLine("turn_start"), kiroLine("pending_interaction", ",\"toolCallId\":\"t1\""),
                                                 kiroLine("interaction_resolved", ",\"toolCallId\":\"t1\"")]) == .working, "an answered approval resumes work")
        expect(AgentAppSessionState.kiro(lines: [kiroLine("turn_start"), kiroLine("turn_end", ",\"stopReason\":\"end_turn\"")]) == .idle, "an ended Kiro turn is idle")
        expect(AgentAppSessionState.kiro(lines: [kiroLine("session_event")]) == nil, "no turn records, no Kiro state")
        expect(AgentAppSessionState.combined([.idle, .working]) == .working, "a finished Kiro chat doesn't hide a running one")
        expect(AgentAppSessionState.combined([.working, .waiting, .idle]) == .waiting, "a waiting Kiro chat wins")
        expect(AgentAppSessionState.combined([]) == .unknown, "no fresh Kiro chats, no state")
        expect(AgentAppSessionState.deepSeek(events: ["approval/policy", "turn/start"]) == .working, "a Harness turn is working")
        expect(AgentAppSessionState.deepSeek(events: ["turn/start", "approval/asked"]) == .waiting, "a Harness approval prompt is waiting")
        expect(AgentAppSessionState.deepSeek(events: ["turn/start", "approval/asked", "approval/decided"]) == .working, "an answered Harness prompt resumes")
        expect(AgentAppSessionState.deepSeek(events: ["turn/start", "turn/end"]) == .idle, "a finished Harness turn is idle")
        expect(AgentAppSessionState.deepSeek(events: ["approval/policy"]) == nil, "no Harness turn, no state")
        let appStart = Date(timeIntervalSince1970: 1_000)
        expect(AgentAppSessionState.cursor(rows: [["status": "aborted", "updated": 2_000_000.0]], since: appStart, runningTools: 1) == .working,
               "a Cursor chat marked aborted with a tool call still loading is working")
        expect(AgentAppSessionState.hermes(leases: 1, lastMessage: 5, since: appStart) == .working, "a Hermes turn lease is working")
        expect(AgentAppSessionState.hermes(leases: 0, lastMessage: 2_000, since: appStart) == .idle, "a finished Hermes turn is idle at once")
        expect(AgentAppSessionState.hermes(leases: 0, lastMessage: 5, since: appStart) == nil, "no Hermes work since launch, no state")
        expect(AgentAppSessionState.cursor(rows: [["status": "none", "generating": 0, "updated": 2_000_000.0],
                                                   ["status": "generating", "generating": 1, "updated": 1.0]], since: appStart) == .working,
               "any generating Cursor chat is working")
        expect(AgentAppSessionState.cursor(rows: [["status": "aborted", "generating": 2, "updated": 2_000_000.0]], since: appStart) == .idle,
               "a stopped Cursor chat with stale generating ids is idle")
        expect(AgentAppSessionState.cursor(rows: [["status": "completed", "generating": 0, "updated": 10.0]], since: appStart) == .unknown,
               "a Cursor chat from before the app started is not shown")
        expect(AgentBackgroundScanner.busyAgents(pids: [700], cpuListing: retitled, apps: [700: "Cursor"]).isEmpty, "retitled Electron helpers are part of the app")
        let promptBundle = AgentBackgroundScanner.parseProcesses("42002 1 00:30 /usr/local/bin/co /usr/local/bin/codex exec fix Foo.app/Contents/Info.plist", now: now, isExecutable: { $0 == "/usr/local/bin/codex" })
        expect(promptBundle.map(\.provider) == ["Codex"], "a prompt mentioning a bundle path is still a Codex task")
        let promptScript = AgentBackgroundScanner.parseProcesses("42003 1 00:30 /usr/local/bin/co /usr/local/bin/codex exec Review /tmp/codex.js app-server integration", now: now)
        expect(promptScript.map(\.provider) == ["Codex"], "a prompt naming codex.js is still a Codex task")
        var heldWaiting: [String: Date] = [:]
        let waitingOC = AgentThread(id: "OpenCode-9", provider: "OpenCode", pid: 9, state: .waiting)
        expect(AgentThread.holdingRecentlyBusy([waitingOC], lastBusy: &heldWaiting, now: now) == [waitingOC], "session-read waiting state is listed as is")
        var codexNew = AgentSessionSnapshot(provider: "Codex"); codexNew.state = .waiting; codexNew.updatedAt = now.addingTimeInterval(-5)
        var codexOld = AgentSessionSnapshot(provider: "Codex"); codexOld.state = .working; codexOld.updatedAt = now.addingTimeInterval(-3600)
        expect(AgentSessionState.newest([codexOld, codexNew], provider: "Codex", since: now.addingTimeInterval(-60), now: now)?.state == .waiting, "Codex app takes the newest fresh transcript since it started")
        expect(AgentSessionState.newest([codexOld], provider: "Codex", since: nil, now: now) == nil, "a stale transcript is not the app's")
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

    private static func claudeLiveSessions() throws {
        try fixture("claude-live") { home in
            let started = date("2026-01-01T12:00:00Z")
            let now = started.addingTimeInterval(60)
            let cwd = "/fixture/shared"
            func process(_ pid: Int32, id: String? = nil) -> AgentProcessDescriptor {
                AgentProcessDescriptor(pid: pid, provider: "Claude Code", sessionID: id, cwd: cwd, startedAt: started)
            }
            func record(_ pid: Int32, _ id: String, _ entrypoint: String, _ status: String,
                        start: String = "Thu Jan  1 12:00:00 2026") throws {
                let fields: [String: Any] = ["pid": pid, "sessionId": id, "pidDomain": "darwin", "procStart": start,
                    "startedAt": Int64(started.addingTimeInterval(23).timeIntervalSince1970 * 1000),
                    "statusUpdatedAt": Int64(now.timeIntervalSince1970 * 1000), "entrypoint": entrypoint,
                    "status": status, "cwd": cwd]
                try write(line(fields), to: home.appendingPathComponent(".claude/sessions/\(pid).json"))
            }
            var cliTranscript = AgentSessionSnapshot(provider: "Claude Code", sessionID: "cli", cwd: cwd,
                state: .working, updatedAt: now,
                activity: AgentDisplayActivity(tool: "Bash", startedAt: now, endedAt: nil))
            let desktopTranscript = AgentSessionSnapshot(provider: "Claude Code", sessionID: "desktop", cwd: cwd,
                state: .working, updatedAt: now.addingTimeInterval(-5),
                activity: AgentDisplayActivity(tool: "mcp__computer__screenshot", startedAt: now.addingTimeInterval(-5), endedAt: nil))
            func rows(_ processes: [AgentProcessDescriptor]) -> [AgentThread] {
                AgentBackgroundScanner.claudeThreads(processes: processes, desktopPIDs: [40], parents: [43: 41, 44: 41, 41: 40],
                    sessions: [cliTranscript, desktopTranscript], home: home, now: now, environment: [:])
            }
            try record(42, "cli", "cli", "waiting")
            try write(line(["sessionId": "cli", "chosenName": "Saved task"]) + "\n", to: registryIndex(home))
            let cliOnly = rows([process(42), process(44)])
            expect(cliOnly.count == 1 && cliOnly.first?.state == .waiting && cliOnly.first?.isApp == false,
                   "CLI permission prompt supersedes transcript; idle desktop and helper get no task row")
            expect(cliOnly.first?.displayName == "Saved task", "name from matching index survives a live record without a name")
            try record(43, "desktop", "claude-desktop", "waiting")
            let concurrent = rows([process(42), process(43), process(44)])
            let desktop = concurrent.first(where: \.isApp)
            expect(concurrent.count == 2 && desktop?.state == .waiting && desktop?.pid == 43,
                   "desktop permission prompt is attributed to the worker, not to the newest transcript")
            expect(desktop?.activity == desktopTranscript.activity, "desktop uses its own tool metadata")
            expect(concurrent.first(where: { !$0.isApp })?.activity == cliTranscript.activity, "CLI uses its own tool metadata")
            try record(42, "cli", "cli", "shell")
            try record(43, "desktop", "claude-desktop", "idle")
            let completing = rows([process(42), process(43)])
            expect(completing.first(where: { !$0.isApp })?.state == .working, "approved shell work becomes working")
            expect(AgentThread.finishedTransitions(from: concurrent, to: completing).map(\.sessionID) == ["desktop"],
                   "owned desktop completion goes idle without completing the CLI")
            let mirrored = rows([process(42, id: "desktop"), process(43), process(45, id: "desktop")])
            expect(mirrored.count == 2 && mirrored.filter(\.isApp).count == 1,
                   "live ownership beats original argv; an argv-only mirror adds no duplicate row")
            try record(45, "desktop", "cli", "busy")
            let ambiguous = rows([process(43), process(45)])
            expect(ambiguous.count == 1 && ambiguous.first?.state == .unknown && ambiguous.first?.activity == nil,
                   "two verified owners are not counted twice or treated as working")
            try record(42, "cli", "cli", "waiting", start: "Wed Dec 31 12:00:00 2025")
            let reused = rows([process(42)])
            expect(reused.first?.state == .unknown && reused.first?.sessionID == nil,
                   "reused PID and same cwd cannot claim any transcript or approval")
            cliTranscript.updatedAt = started.addingTimeInterval(-60)
            cliTranscript.activity = AgentDisplayActivity(tool: "computer_click", startedAt: started.addingTimeInterval(-60), endedAt: nil)
            let resumed = rows([process(42, id: "cli")])
            expect(resumed.first?.state == .unknown && resumed.first?.activity == nil,
                   "old work and its display activity cannot survive a process restart")
        }
    }
}
