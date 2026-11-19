// AgentMonitor — active local CLI processes correlated with explicit task
// lifecycle metadata. Process presence alone never means work is running.
import Foundation

struct AgentThread: Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let pid: Int32
    var state: AgentTaskState
    /// User-visible identity, from the optional Claude registry or derived
    /// from provider + cwd. Never transcript text; the menu falls back to
    /// `provider` when nil.
    var displayName: String?
    var host: String?
    var sessionID: String?
    /// Last display-capable tool call, if the transcript exposed one.
    var activity: AgentDisplayActivity?
    var updatedAt: Date?

    var working: Bool { state == .working }
    var waiting: Bool {
        get { state == .waiting }
        set { state = newValue ? .waiting : (state == .waiting ? .unknown : state) }
    }

    init(id: String,
         provider: String,
         pid: Int32,
         state: AgentTaskState,
         displayName: String? = nil,
         host: String? = nil,
         sessionID: String? = nil,
         activity: AgentDisplayActivity? = nil,
         updatedAt: Date? = nil) {
        self.id = id
        self.provider = provider
        self.pid = pid
        self.state = state
        self.displayName = displayName
        self.host = host
        self.sessionID = sessionID
        self.activity = activity
        self.updatedAt = updatedAt
    }

    /// Process-only agents read as working from CPU use, which dips while
    /// they wait on a model. Keep one working until it has been quiet for
    /// `hold`, so short pauses don't end Agent Screen or Finish Work.
    static func holdingRecentlyBusy(_ threads: [AgentThread], lastBusy: inout [String: Date],
                                    now: Date, hold: TimeInterval = 60) -> [AgentThread] {
        let processOnly = AgentProcessDescriptor.processOnlyProviderNames
        lastBusy = lastBusy.filter { entry in threads.contains { $0.id == entry.key } }
        // An open app or idle CLI is not a running agent, so a process-only
        // agent is listed only while it works (or within `hold` of working).
        return threads.compactMap { thread in
            guard processOnly.contains(thread.provider) else { return thread }
            if thread.state == .working { lastBusy[thread.id] = now; return thread }
            guard let last = lastBusy[thread.id], now.timeIntervalSince(last) < hold else { return nil }
            return AgentThread(id: thread.id, provider: thread.provider, pid: thread.pid, state: .working,
                               displayName: thread.displayName, host: thread.host, sessionID: thread.sessionID,
                               activity: thread.activity, updatedAt: thread.updatedAt)
        }
    }

    static func finishedTransitions(from previous: [AgentThread], to current: [AgentThread]) -> [AgentThread] {
        let old = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return current.filter { $0.state == .idle && (old[$0.id]?.state.busy ?? false) }
    }

    // Source compatibility for callers that used the original initializer.
    // A non-waiting process is unknown, NOT implicitly working.
    init(id: String, provider: String, pid: Int32, waiting: Bool) {
        self.init(id: id, provider: provider, pid: pid, state: waiting ? .waiting : .unknown)
    }
}

@MainActor
final class AgentMonitor {
    static let shared = AgentMonitor()
    /// `needsDisplay(now:)`/`displayEligibleThreads(...)` live in
    /// AgentDisplayPolicy.swift so the pure policy has one home.
    private(set) var threads: [AgentThread] = []
    /// Only explicit busy -> idle transitions, not disappearing processes or
    /// unknown records. The array is replaced with every completed scan.
    private(set) var finishedThreads: [AgentThread] = []
    /// When an agent last finished, for Agent Light's "done" tail.
    private(set) var lastFinishedAt: Date?
    var onChange: (() -> Void)?
    var onFinished: (([AgentThread]) -> Void)?
    private var timer: Timer?
    private var scanTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {}

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "agentStatusEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "agentStatusEnabled")
            newValue ? start() : stop()
        }
    }

    var workingCount: Int { threads.filter(\.working).count }
    var waitingCount: Int { threads.filter(\.waiting).count }

    func start() {
        stop()
        guard enabled else { return }
        scan()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        scanTask?.cancel()
        scanTask = nil
        let changed = !threads.isEmpty
        threads = []
        finishedThreads = []
        if changed { onChange?() }
    }

    private var lastBusy: [String: Date] = [:]

    private func scan() {
        guard scanTask == nil else { return }
        let currentGeneration = generation
        scanTask = Task { [weak self] in
            // ps, lsof, directory traversal, and transcript tails all run on a
            // detached worker, never on the main actor / menu-bar thread.
            let scanned = await Task.detached(priority: .utility) {
                AgentBackgroundScanner.scan(home: FileManager.default.homeDirectoryForCurrentUser)
            }.value
            guard let self, !Task.isCancelled, self.generation == currentGeneration else { return }
            self.scanTask = nil
            let found = AgentThread.holdingRecentlyBusy(scanned, lastBusy: &self.lastBusy, now: Date())
            self.finishedThreads = AgentThread.finishedTransitions(from: self.threads, to: found)
            if self.threads != found {
                self.threads = found
                // Log counts only. Never commands, cwd, prompts, responses,
                // transcript paths, account data, or session content.
                Diagnostics.log("agent status: \(self.workingCount) working, \(self.waitingCount) waiting, \(found.filter { $0.state == .unknown }.count) unknown")
                self.onChange?()
            }
            if !self.finishedThreads.isEmpty {
                self.lastFinishedAt = Date()
                self.onFinished?(self.finishedThreads)
            }
        }
    }
}

enum AgentBackgroundScanner {
    private static let maxProcesses = 24

    static func scan(home: URL) -> [AgentThread] {
        guard let listing = command("/bin/ps", ["-axo", "pid=,ppid=,etime=,comm=,args="], timeout: 2, maxBytes: 2 * 1024 * 1024) else { return [] }
        let discovered = parseProcesses(listing, now: Date())
        // npm Codex launches a native Codex child. Don't count that wrapper as
        // a second task (or make the real child's cwd correlation ambiguous).
        var processes = discovered.filter { candidate in
            !candidate.isLauncher || !discovered.contains { $0.parentPID == candidate.pid && $0.provider == candidate.provider }
        }
        processes = Array(processes.prefix(maxProcesses)).map { process in
            let cwd = process.sessionID == nil ? currentDirectory(pid: process.pid) : nil
            return AgentProcessDescriptor(pid: process.pid, provider: process.provider,
                                          sessionID: process.sessionID, cwd: cwd, startedAt: process.startedAt)
        }
        guard !processes.isEmpty else { return [] }
        let sessions = AgentSessionFiles.snapshots(home: home, processes: processes)
        // The Claude registry is optional and absent on many Macs. Failure to
        // find it simply leaves identity derived from the transcript. Only
        // touch it when a Claude process is present.
        let registry = processes.contains { $0.provider == "Claude Code" }
            ? ClaudeSessionRegistry.load(home: home)
            : ClaudeRegistrySnapshot()
        let processOnly = AgentProcessDescriptor.processOnlyProviderNames
        let busy: Set<Int32> = processes.contains { processOnly.contains($0.provider) }
            ? busyAgents(pids: processes.filter { processOnly.contains($0.provider) }.map(\.pid),
                         cpuListing: command("/bin/ps", ["-axo", "pid=,ppid=,%cpu="], timeout: 2, maxBytes: 2 * 1024 * 1024) ?? "")
            : []
        return processes.map { process in
            let correlation = AgentTaskCorrelation.correlation(for: process, sessions: sessions, processes: processes)
            var snapshot = correlation.session ?? AgentSessionSnapshot(provider: process.provider)
            snapshot.sessionID = snapshot.sessionID ?? process.sessionID
            snapshot.cwd = snapshot.cwd ?? process.cwd

            let record = ClaudeSessionRegistry.record(for: process,
                                                     transcriptSessionID: snapshot.sessionID,
                                                     registry: registry)
            if let record {
                snapshot.sessionID = snapshot.sessionID ?? record.sessionID
                snapshot.cwd = snapshot.cwd ?? record.cwd
                snapshot.host = snapshot.host ?? record.host
                snapshot.updatedAt = snapshot.updatedAt ?? record.statusUpdatedAt
            }
            let resolved = ClaudeSessionRegistry.displayName(provider: process.provider,
                                                             record: record,
                                                             sessionID: snapshot.sessionID,
                                                             cwd: snapshot.cwd)
            snapshot.name = resolved.name
            snapshot.nameSource = resolved.source

            // The transcript is authoritative. A registry claim is used only
            // when the transcript has no state, and only for positive
            // busy/waiting claims (never to invent a completion).
            var state = correlation.state
            if state == .unknown, let record,
               let claimed = ClaudeSessionRegistry.claimedState(for: record, process: process) {
                state = claimed
            }
            // A quiet CPU is not proof the task finished (the agent may be
            // waiting on its model), so a non-busy process-only agent is unknown.
            if processOnly.contains(process.provider) { state = busy.contains(process.pid) ? .working : .unknown }

            return AgentThread(id: "\(process.provider)-\(process.pid)", provider: process.provider, pid: process.pid,
                               state: state, displayName: snapshot.name, host: snapshot.host,
                               sessionID: snapshot.sessionID, activity: snapshot.activity,
                               updatedAt: snapshot.updatedAt)
        }.sorted { $0.id < $1.id }
    }

    /// Agents with no readable transcript count as working while they or the
    /// processes they started (shells, builds, browsers) use CPU. An open but
    /// idle CLI stays under the threshold. `cpuListing` is `ps -o pid,ppid,%cpu`.
    static func busyAgents(pids: [Int32], cpuListing: String, threshold: Double = 5) -> Set<Int32> {
        var cpu: [Int32: Double] = [:]
        var children: [Int32: [Int32]] = [:]
        for line in cpuListing.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                  let usage = Double(fields[2]) else { continue }
            cpu[pid] = usage
            children[parent, default: []].append(pid)
        }
        var result: Set<Int32> = []
        for pid in pids {
            var total = 0.0
            var queue = [pid]
            var seen: Set<Int32> = []
            while let next = queue.popLast(), seen.count < 512 {
                guard seen.insert(next).inserted else { continue }
                total += cpu[next] ?? 0
                queue += children[next] ?? []
            }
            if total >= threshold { result.insert(pid) }
        }
        return result
    }

    /// ps fields: PID [parentPID] elapsed executable arguments. Both the
    /// four-column (`pid etime comm args`) and five-column (`pid ppid etime
    /// comm args`) layouts are accepted; a parent PID is only present when the
    /// column actually parses as one. No prompt/argument text is retained in
    /// returned descriptors or sent to diagnostics.
    static func parseProcesses(_ listing: String, now: Date) -> [AgentProcessDescriptor] {
        var result: [AgentProcessDescriptor] = []
        for line in listing.split(separator: "\n") {
            let fields = line.split(maxSplits: 4, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 4, let pid = Int32(fields[0]), pid > 0 else { continue }
            // `etime` never parses as a bare integer, so a numeric second
            // column can only be a parent PID.
            var index = 1
            var parentPID: Int32?
            if fields.count == 5, let candidate = Int32(fields[1]),
               elapsed(String(fields[2])) != nil {
                parentPID = candidate
                index = 2
            }
            guard fields.count >= index + 3,
                  let seconds = elapsed(String(fields[index])) else { continue }
            let commandLine = fields[(index + 2)...].joined(separator: " ")
            let arguments = tokenize(commandLine)
            // macOS truncates `comm` to 16 characters, so a CLI started by its
            // full path (e.g. npm's native Codex binary) shows up as a prefix
            // like "/opt/homebrew/li". Recover the path from argv[0].
            var executable = String(fields[index + 1])
            if let argv0 = arguments.first, argv0.count > executable.count, argv0.hasPrefix(executable) {
                executable = argv0
            }
            let provider: String
            if let bundled = bundledExecutable(commandLine: commandLine, truncated: String(fields[index + 1])) {
                guard let app = AgentProcessDescriptor.desktopAppProviders[URL(fileURLWithPath: bundled).lastPathComponent] else { continue }
                executable = bundled
                provider = app
            } else {
                guard let cli = AgentProcessDescriptor.provider(executable: executable, arguments: arguments) else { continue }
                provider = cli
            }
            // Codex's background app-server daemon is not a task.
            if provider == "Codex", arguments.dropFirst().first == "app-server" { continue }
            var descriptor = AgentProcessDescriptor(pid: pid, provider: provider,
                                                    sessionID: AgentProcessDescriptor.explicitSessionID(arguments: arguments),
                                                    cwd: nil, startedAt: now.addingTimeInterval(-seconds))
            descriptor.parentPID = parentPID
            descriptor.isLauncher = ["node", "nodejs", "bun"].contains(URL(fileURLWithPath: executable).lastPathComponent)
            result.append(descriptor)
        }
        return result.sorted { $0.pid < $1.pid }
    }

    /// A Mac app's path can contain spaces (`/Applications/DeepSeek
    /// Harness.app/Contents/MacOS/DeepSeek Harness`), which argv tokenizing
    /// splits apart. Recover `<Name>.app/Contents/MacOS/<Name>` whole.
    static func bundledExecutable(commandLine: String, truncated: String) -> String? {
        guard commandLine.hasPrefix(truncated),
              let marker = commandLine.range(of: ".app/Contents/MacOS/") else { return nil }
        let bundlePath = commandLine[..<marker.lowerBound]
        // A bundle path inside a later argument (`node /Applications/X.app/…`)
        // is not the executable: argv0 must run straight into the bundle.
        guard !bundlePath.contains(" /"), !bundlePath.contains(" -") else { return nil }
        let bundleName = bundlePath.split(separator: "/").last.map(String.init) ?? ""
        guard !bundleName.isEmpty, commandLine[marker.upperBound...].hasPrefix(bundleName) else { return nil }
        let end = commandLine.index(marker.upperBound, offsetBy: bundleName.count)
        guard end == commandLine.endIndex || commandLine[end] == " " else { return nil }
        return String(commandLine[..<end])
    }

    private static func currentDirectory(pid: Int32) -> String? {
        guard let output = command("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"], timeout: 0.5, maxBytes: 16 * 1024) else { return nil }
        let directories = output.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
        return directories.count == 1 ? directories[0] : nil
    }

    /// Parses the `ps` elapsed-time forms `MM:SS`, `HH:MM:SS`, and
    /// `DD-HH:MM:SS` (for example `00:30`, `3:04`, `1-02:03:04`). Anything
    /// else is rejected rather than guessed at, so a bad column cannot
    /// fabricate a start time.
    private static func elapsed(_ text: String) -> TimeInterval? {
        guard !text.isEmpty else { return nil }
        let dayParts = text.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        var days: TimeInterval = 0
        let clock: Substring
        switch dayParts.count {
        case 1:
            clock = text[...]
        case 2:
            guard isNumeric(dayParts[0]), let parsed = TimeInterval(dayParts[0]) else { return nil }
            days = parsed
            clock = dayParts[1]
        default:
            return nil
        }
        let components = clock.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2 || components.count == 3 else { return nil }
        var values: [TimeInterval] = []
        for component in components {
            guard isNumeric(component), let value = TimeInterval(component) else { return nil }
            values.append(value)
        }
        // Seconds are always the trailing field; minutes are second-to-last
        // and must stay below sixty. Hours may exceed twenty-three only when
        // they are really a day prefix, so reject that ambiguity too.
        guard values[values.count - 1] < 60,
              values[values.count - 2] < 60,
              values.count == 2 || values[0] < 24 else { return nil }
        var seconds: TimeInterval = 0
        for value in values { seconds = seconds * 60 + value }
        return days * 86_400 + seconds
    }

    private static func isNumeric(_ value: Substring) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func tokenize(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        var quote: Character?, escaped = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let delimiter = quote {
                if character == delimiter { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty { result.append(current); current = "" }
            } else { current.append(character) }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval, maxBytes: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler { if process.isRunning { process.terminate() } }
        deadline.resume()
        defer { deadline.cancel() }
        var data = Data()
        while true {
            let part = pipe.fileHandleForReading.readData(ofLength: 8192)
            if part.isEmpty { break }
            if data.count + part.count <= maxBytes { data.append(part) }
            else {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
