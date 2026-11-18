// AppLiveness — the app's crash-recovery record and the login-agent handle.
//
// The per-user watchdog agent needs one thing the app cannot say after it dies:
// "this exact process was armed for this session". This file publishes that
// fact and nothing else. The record is deliberately tiny and contains no user
// data: a schema version, PID plus kernel process start time (so PID reuse can
// be rejected), the armed flag, an optional arm time, a generation that
// changes every launch, and an update stamp.
//
// Storage posture: one 0600 file in
// ~/Library/Application Support/Wakely/liveness.json, written as a sibling
// temporary file plus atomic rename. An existing symlink (or any
// non-regular file) at the destination is refused, never followed.
//
// Only AppDelegate drives this: beginIdle() at launch, sync(armed:armedAt:)
// from PowerEngine.onStateChange, clear() at the end of a clean termination.

import Darwin
import Foundation
import ServiceManagement

/// The on-disk liveness record. Field names are the wire format the watchdog
/// reads (Watchdog/Policy.swift mirrors them; the test suite checks agreement).
struct LivenessRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var pid: Int32
    /// Seconds since the epoch from `KERN_PROC_PID.p_starttime`. Never zero for
    /// a record this app writes.
    var processStartTime: TimeInterval
    var armed: Bool
    var armedAt: TimeInterval?
    /// Increments once per app launch; the watchdog uses it to notice that a
    /// relaunch replaced the instance it was observing.
    var generation: UInt64
    var updatedAt: TimeInterval

    init(schemaVersion: Int = LivenessRecord.currentSchemaVersion,
         pid: Int32,
         processStartTime: TimeInterval,
         armed: Bool,
         armedAt: TimeInterval? = nil,
         generation: UInt64 = 0,
         updatedAt: TimeInterval = 0) {
        self.schemaVersion = schemaVersion
        self.pid = pid
        self.processStartTime = processStartTime
        self.armed = armed
        self.armedAt = armedAt
        self.generation = generation
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pid, processStartTime, armed, armedAt, generation, updatedAt
    }

    /// Tolerant of a record written by an older build: a missing version is
    /// version 1, and an absent generation/stamp is zero. The PID and start
    /// time remain mandatory because they carry the identity.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? LivenessRecord.currentSchemaVersion
        self.pid = try container.decode(Int32.self, forKey: .pid)
        self.processStartTime = try container.decode(TimeInterval.self, forKey: .processStartTime)
        self.armed = try container.decode(Bool.self, forKey: .armed)
        self.armedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .armedAt)
        self.generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
        self.updatedAt = try container.decodeIfPresent(TimeInterval.self, forKey: .updatedAt) ?? 0
    }
}

enum AppLiveness {
    static let fileName = "liveness.json"
    /// Written by the watchdog, reset here: a new app instance starts a new
    /// crash episode, so the previous episode's restore budget must not poison
    /// it. The name is mirrored in Watchdog/main.swift.
    static let watchdogRetryFileName = "watchdog-retries.json"

    private static let maximumRecordBytes = 64 * 1024
    private static let lock = NSLock()
    private static var current: LivenessRecord?
    /// Set by beginTermination()/clear(): a late onStateChange during shutdown
    /// must not republish a record after the clean-quit clear.
    private static var terminating = false

    // MARK: - Locations

    /// Resolved through SupportPaths so the watchdog always reads the location
    /// the app actually migrated to.
    static var supportDirectory: URL { SupportPaths.baseDirectory }

    static var recordURL: URL {
        supportDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Lifecycle

    /// Start a new app instance. Publishes an unarmed record immediately: even
    /// an app that arms and then crashes before its first state change has a
    /// generation and identity the watchdog can use.
    @discardableResult
    static func beginIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        terminating = false
        // A launch starts a fresh crash-recovery budget. Without this reset, a
        // previous episode that exhausted the watchdog's attempts would keep
        // suppressing recovery for every later crash until someone removed the
        // counter by hand.
        resetWatchdogRetryCounterLocked()
        let pid = getpid()
        guard let start = processStartTime(pid: pid) else {
            current = nil
            Diagnostics.log("liveness: cannot read this process's start time; no record published")
            return false
        }
        let record = LivenessRecord(
            pid: pid,
            processStartTime: start,
            armed: false,
            armedAt: nil,
            generation: nextGenerationLocked(),
            updatedAt: Date().timeIntervalSince1970
        )
        current = record
        return writeLocked(record)
    }

    /// Publish the engine's armed state. Called from every engine state change;
    /// only an actual change is written, so the record's `updatedAt` marks the
    /// last state transition rather than every unrelated event.
    @discardableResult
    static func sync(armed: Bool, armedAt: Date?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !terminating else { return false }
        let pid = getpid()
        guard let start = processStartTime(pid: pid) else {
            Diagnostics.log("liveness: cannot read this process's start time; state not published")
            return false
        }

        var record: LivenessRecord
        if let cached = current, cached.pid == pid, cached.processStartTime == start {
            record = cached
        } else if let onDisk = readExistingLocked(),
                  onDisk.pid == pid, onDisk.processStartTime == start {
            record = onDisk
        } else {
            record = LivenessRecord(
                pid: pid,
                processStartTime: start,
                armed: false,
                armedAt: nil,
                generation: nextGenerationLocked(),
                updatedAt: Date().timeIntervalSince1970
            )
        }

        let resolvedArmedAt = armed ? (armedAt ?? record.armedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()) : nil
        let resolvedArmedAtSeconds = resolvedArmedAt?.timeIntervalSince1970
        if record.armed == armed, record.armedAt == resolvedArmedAtSeconds {
            current = record
            return true
        }

        record.armed = armed
        record.armedAt = resolvedArmedAtSeconds
        record.updatedAt = Date().timeIntervalSince1970
        current = record
        return writeLocked(record)
    }

    /// The app is about to run its termination drains. Freeze the record at the
    /// last armed state: if the process dies during the drain, the session is
    /// still correctly reported as interrupted. On a completed drain, clear()
    /// removes the record.
    static func beginTermination() {
        lock.lock()
        terminating = true
        lock.unlock()
    }

    /// Clean exit: remove the record. Removal unlinks the destination (a
    /// symlink is removed as a link, never followed) and makes any later
    /// state-change sync a no-op.
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        terminating = true
        current = nil
        // Only this process may retract its own record: if another instance
        // published while this one was draining, leave that record alone.
        if let onDisk = readExistingLocked(), onDisk.pid != getpid() {
            Diagnostics.log("liveness: refusing to remove another process's record")
            return
        }
        let url = recordURL
        if unlink(url.path) != 0, errno != ENOENT {
            Diagnostics.log("liveness: could not remove the record (errno \(errno))")
        }
    }

    // MARK: - Process identity

    /// `KERN_PROC_PID` start time in seconds since the epoch, or nil when the
    /// process does not exist (or the kernel will not report it). Comparing
    /// this against the recorded value is what rejects PID reuse.
    static func processStartTime(pid: Int32) -> TimeInterval? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return sysctl(base, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0,
              size >= MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0 else { return nil }
        return TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
    }

    // MARK: - Writing

    private static func resetWatchdogRetryCounterLocked() {
        let url = supportDirectory.appendingPathComponent(watchdogRetryFileName, isDirectory: false)
        // Unlink removes the link itself; never follow a symlink here either.
        if unlink(url.path) != 0, errno != ENOENT {
            Diagnostics.log("liveness: could not reset the watchdog retry counter (errno \(errno))")
        }
    }

    private static func nextGenerationLocked() -> UInt64 {
        let previous = current?.generation ?? readExistingLocked()?.generation ?? 0
        return previous == UInt64.max ? 1 : previous + 1
    }

    private static func readExistingLocked() -> LivenessRecord? {
        let url = recordURL
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size > 0,
              info.st_size <= Int64(maximumRecordBytes) else { return nil }
        guard let data = try? Data(contentsOf: url),
              data.count <= maximumRecordBytes else { return nil }
        return try? JSONDecoder().decode(LivenessRecord.self, from: data)
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isRegularFileOrMissing(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    private static func writeLocked(_ record: LivenessRecord) -> Bool {
        let directory = supportDirectory
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            Diagnostics.log("liveness: cannot create the support directory: \(error.localizedDescription)")
            return false
        }

        let destination = recordURL
        guard !isSymbolicLink(directory) else {
            Diagnostics.log("liveness: refusing a symlinked support directory")
            return false
        }
        guard !isSymbolicLink(destination) else {
            Diagnostics.log("liveness: refusing to write through a symlinked record")
            return false
        }
        guard isRegularFileOrMissing(destination) else {
            Diagnostics.log("liveness: refusing to replace a non-regular record")
            return false
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(record) else {
            Diagnostics.log("liveness: could not encode the record")
            return false
        }

        let temporary = directory.appendingPathComponent(
            ".liveness-\(getpid())-\(UUID().uuidString).tmp"
        )
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else {
            Diagnostics.log("liveness: could not create the temporary record (errno \(errno))")
            return false
        }

        let wrote = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
        _ = fsync(descriptor)
        let closed = close(descriptor) == 0
        guard wrote, closed else {
            unlink(temporary.path)
            Diagnostics.log("liveness: could not write the temporary record")
            return false
        }
        guard rename(temporary.path, destination.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            Diagnostics.log("liveness: could not publish the record (errno \(code))")
            return false
        }
        return true
    }
}

// MARK: - Login agent

/// The real SMAppService state of the per-user watchdog agent, with the
/// user-facing meaning kept out of the registration call.
enum AgentServiceState: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case failed(String)

    var logDescription: String {
        switch self {
        case .enabled: return "enabled"
        case .requiresApproval: return "registered, waiting for approval in Login Items"
        case .notRegistered: return "not registered"
        case .notFound: return "agent plist not found in the app bundle"
        case .failed(let message): return "unavailable: \(message)"
        }
    }

    static func from(status: SMAppService.Status) -> AgentServiceState {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .failed("unrecognized SMAppService agent status")
        }
    }

    /// Only an enabled agent can be started: `requiresApproval` means the user
    /// has not allowed it in Login Items, and a kickstart would fail (or, worse,
    /// look like it succeeded).
    var isEnabled: Bool { self == .enabled }
}

extension AppLiveness {
    /// Register the per-user watchdog agent if the system has not seen it yet.
    ///
    /// Never prompts, never opens System Settings, never blocks launch: the
    /// return value is the status to log. Registration is skipped entirely
    /// while the privileged helper is not installed, because an agent that
    /// cannot ask the daemon for a restore would only report failures.
    static func registerAgentIfNeeded(helperInstalled: Bool) -> AgentServiceState {
        guard helperInstalled else {
            Diagnostics.log("login agent: skipped (the privileged helper is not installed)")
            return .notRegistered
        }
        if !HelperCodeIdentity.hasTeamIdentifier() {
            let loaded = ManualAgentInstaller.installIfNeeded()
            Diagnostics.log("login agent: ad-hoc build uses a user LaunchAgent (\(loaded ? "loaded" : "failed"))")
            return loaded ? .enabled : .failed("the user LaunchAgent could not be loaded")
        }

        let service = SMAppService.agent(plistName: HelperService.agentPlistName)
        var status = service.status

        if AgentServiceState.from(status: status) == .notRegistered {
            do {
                try service.register()
            } catch {
                let current = AgentServiceState.from(status: service.status)
                Diagnostics.log("login agent registration failed: \(error.localizedDescription)")
                return current == .notRegistered ? .failed(error.localizedDescription) : current
            }
            // Report what the system says *after* registering, never the
            // hopeful result of the call: a successful `register()` still
            // leaves the agent disabled until the user approves it.
            status = service.status
        }

        let state = AgentServiceState.from(status: status)
        switch state {
        case .enabled:
            Diagnostics.log("login agent: enabled")
        case .requiresApproval:
            Diagnostics.log("login agent: registered but not enabled; the user must allow it in System Settings > General > Login Items before it can watch for crashes")
        default:
            Diagnostics.log("login agent: \(state.logDescription)")
        }
        return state
    }

    /// Start a fresh watchdog instance for this login session.
    ///
    /// The agent normally runs from login until the app clears its record. A
    /// *clean* agent exit (0) is deliberately not restarted by the job's
    /// `KeepAlive = { SuccessfulExit: false }`, and the app's next launch in the
    /// same login would then be unwatched. `launchctl kickstart` closes that
    /// gap.
    ///
    /// Deliberately no `-k`: `kickstart` without it asks launchd to start the
    /// job only when it is not already running, so a watcher that is observing
    /// the app is never killed and restarted. launchctl exits non-zero for
    /// "already running" and for a job the user disabled; both are benign here
    /// and are only logged. The command runs off the main thread with a short
    /// timeout so launch can never block on launchd.
    static func kickstartAgentIfNeeded() {
        if !HelperCodeIdentity.hasTeamIdentifier() {
            Task.detached(priority: .utility) {
                ManualAgentInstaller.kickstart()
            }
            return
        }
        let service = SMAppService.agent(plistName: HelperService.agentPlistName)
        let state = AgentServiceState.from(status: service.status)
        guard state.isEnabled else {
            Diagnostics.log("login agent kickstart: skipped (agent \(state.logDescription))")
            return
        }

        let target = "gui/\(getuid())/\(HelperService.agentLabel)"
        Task.detached(priority: .utility) {
            let outcome = AppLiveness.runLaunchctlKickstart(target: target)
            if outcome.timedOut {
                Diagnostics.log("login agent kickstart: launchctl did not answer within \(Int(kickstartTimeout))s; gave up (an already-running agent is unaffected)")
                return
            }
            guard outcome.status >= 0 else {
                Diagnostics.log("login agent kickstart: \(outcome.output)")
                return
            }
            let detail = outcome.output.isEmpty ? "" : " (\(outcome.output))"
            if outcome.status == 0 {
                Diagnostics.log("login agent kickstart: launchd accepted a start request for \(target)\(detail)")
            } else {
                // "Already running", or the user's approval was withdrawn since
                // the status check. Neither is a launch failure.
                Diagnostics.log("login agent kickstart: launchctl exited \(outcome.status) for \(target)\(detail); treated as benign")
            }
        }
    }

    private struct KickstartOutcome {
        /// launchctl's exit status, or -1 when it could not be run or was timed out.
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    /// The blocking half of `kickstartAgentIfNeeded()`. Kept synchronous on
    /// purpose: a detached task calls it, but the semaphore wait must not be a
    /// direct async-context call, and the whole round trip is bounded so a
    /// wedged launchd cannot pin the task or its pipe.
    private static func runLaunchctlKickstart(target: String) -> KickstartOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        // No `-k`: never kill a watcher that is already running.
        process.arguments = ["kickstart", target]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return KickstartOutcome(
                status: -1,
                output: "could not run launchctl: \(error.localizedDescription)",
                timedOut: false
            )
        }

        guard exited.wait(timeout: .now() + kickstartTimeout) == .success else {
            // launchctl is ours to stop; `terminate()` only ends the CLI
            // request, never the agent launchd already started.
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return KickstartOutcome(status: -1, output: "", timedOut: true)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return KickstartOutcome(status: process.terminationStatus,
                                output: message,
                                timedOut: false)
    }

    /// Bound on the launchctl round trip. It exists so a wedged launchd cannot
    /// hold a detached task (or the pipe) forever; it is not a retry cadence.
    private static let kickstartTimeout: TimeInterval = 3
}
