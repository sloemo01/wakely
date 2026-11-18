// WakelyWatchdog — per-user login agent.
//
// The original ships one of these next to its privileged helper. Its job is the
// crash case: if the app dies while session-scoped settings are applied,
// something has to put them back. It performs no privileged work itself — it
// asks the daemon to restore session leases and then exits.
//
// Ownership model: the app publishes a liveness record (pid + kernel start
// time + armed flag + generation). This agent observes that record while the
// recorded process runs; only when that exact process is gone does it recover.
// Recovery is `restoreSession` (low power mode / fan / Touch ID only) — never
// `restoreAll`, which would also reapply persistent auto-restart and
// boot-on-lid-open settings that outlive a session.
//
// launchd behaviour: the job is a per-user agent with RunAtLoad and
// KeepAlive = { SuccessfulExit: false }. Because the agent stays alive while
// the app runs, it is already watching when a crash happens. A clean exit
// (0) is not restarted; a failed restore (1) is retried after the job's
// ThrottleInterval (10 s — the real cadence). The exponential value in
// Policy.swift is only a cap hint for a future in-process retry loop, never the
// delay launchd uses. After a bounded number of failures the agent exits 0 and
// leaves the record for the next launch.
//
// Relaunch gap: a clean exit also means the rest of this login has no agent, so
// the app calls `launchctl kickstart` on launch (Sources/AppLiveness.swift).

import Darwin
import Foundation

private let markerFileName = "liveness.json"
private let retryFileName = "watchdog-retries.json"
private let logFileName = "watchdog.log"
private let maximumMarkerBytes = 64 * 1024

private enum MarkerFileRead {
    case absent
    case data(Data)
    case unusable(String)
}

// MARK: - Support directory and log

/// Where the liveness record, retry counter and this log live.
///
/// Production path is identical to the app writer's
/// (Sources/AppLiveness.swift): ~/Library/Application Support/Wakely. The app
/// migrates the pre-rename directory there on first use, so this path always
/// names the migrated location.
///
/// `WAKELY_SUPPORT_DIR` is a **test-only** seam, used by
/// Tests/crash_recovery_live.sh so a real crash-recovery run can happen in a
/// throwaway directory instead of the user's Application Support data. Only an
/// absolute path is accepted; a relative or empty value is ignored and the
/// production path is used. The app deliberately does not honour this
/// variable, so an installed build can never be redirected by the environment.
private func supportDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["WAKELY_SUPPORT_DIR"],
       override.hasPrefix("/") {
        return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Wakely", isDirectory: true)
}

private func logLine(_ text: String) {
    let directory = supportDirectory()
    try? FileManager.default.createDirectory(at: directory,
                                             withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let file = directory.appendingPathComponent(logFileName)
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "[\(stamp)] \(text)\n"
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? data(line).write(to: file, options: .atomic)
    }
}

private func data(_ text: String) -> Data { Data(text.utf8) }

// MARK: - Liveness record

/// Read the record without following a symlink, without accepting a special
/// file, and without reading an unbounded amount of data. The record is
/// written by the app as one atomic rename, so a partial JSON document means
/// external interference and is treated as unusable.
private func readMarkerFile(_ url: URL) -> MarkerFileRead {
    var info = stat()
    if lstat(url.path, &info) != 0 {
        return errno == ENOENT ? .absent : .unusable("lstat failed (errno \(errno))")
    }
    let kind = info.st_mode & S_IFMT
    if kind == S_IFLNK { return .unusable("refusing a symlinked record") }
    guard kind == S_IFREG else { return .unusable("not a regular file") }
    guard info.st_size > 0, info.st_size <= Int64(maximumMarkerBytes) else {
        return .unusable("unexpected size \(info.st_size) bytes")
    }
    guard let contents = try? Data(contentsOf: url) else {
        return .unusable("the file could not be read")
    }
    guard contents.count <= maximumMarkerBytes else {
        return .unusable("the file grew while being read")
    }
    return .data(contents)
}

private func removeMarker(at url: URL) {
    // unlink removes the link itself, never a target it points at.
    if unlink(url.path) != 0, errno != ENOENT {
        logLine("could not remove the liveness record (errno \(errno))")
    }
}

/// Remove the record only if it still describes the instance this agent was
/// recovering. The app can relaunch while the helper is answering; deleting a
/// newer instance's record would blind the next crash. A record that became
/// unreadable is still ours to clean up, since a complete record is published
/// atomically and cannot be a half-written relaunch.
private func removeMarkerIfUnchanged(at url: URL, observed: LivenessMarker?) {
    switch readMarkerFile(url) {
    case .absent:
        return
    case .unusable:
        removeMarker(at: url)
    case .data(let contents):
        switch WatchdogPolicy.readMarker(contents) {
        case .absent:
            return
        case .corrupt:
            removeMarker(at: url)
        case .record(let current):
            if let observed,
               current.pid == observed.pid,
               current.generation == observed.generation,
               current.processStartTime == observed.processStartTime {
                removeMarker(at: url)
            } else {
                logLine("a newer app instance published a liveness record; leaving it in place")
            }
        }
    }
}

// MARK: - Retry counter

private func loadRetryState() -> WatchdogRetryState {
    let url = supportDirectory().appendingPathComponent(retryFileName)
    var info = stat()
    guard lstat(url.path, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFREG,
          info.st_size > 0,
          info.st_size <= 16 * 1024,
          let contents = try? Data(contentsOf: url),
          let state = try? JSONDecoder().decode(WatchdogRetryState.self, from: contents) else {
        // A missing or damaged counter only loses pacing information; it must
        // not block a recovery attempt.
        return WatchdogRetryState()
    }
    return state
}

private func saveRetryState(_ state: WatchdogRetryState) {
    let directory = supportDirectory()
    try? FileManager.default.createDirectory(at: directory,
                                             withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let destination = directory.appendingPathComponent(retryFileName)

    var info = stat()
    if lstat(destination.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
        logLine("refusing to replace a non-regular retry counter")
        return
    }

    guard let contents = try? JSONEncoder().encode(state) else { return }
    let temporary = directory.appendingPathComponent(
        ".watchdog-retries-\(getpid())-\(UUID().uuidString).tmp"
    )
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard descriptor >= 0 else {
        logLine("could not create the temporary retry counter (errno \(errno))")
        return
    }

    let wrote = contents.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return contents.isEmpty }
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
    guard wrote, closed, rename(temporary.path, destination.path) == 0 else {
        unlink(temporary.path)
        logLine("could not publish the retry counter")
        return
    }
}

private func resetRetryState() {
    let url = supportDirectory().appendingPathComponent(retryFileName)
    if unlink(url.path) != 0, errno != ENOENT {
        logLine("could not reset the retry counter (errno \(errno))")
    }
}

// MARK: - Process identity

/// Same kernel query the app uses: `KERN_PROC_PID` -> `p_starttime`. A missing
/// process (or an unreadable start time) is nil; the policy layer decides what
/// that means rather than guessing here.
private func processStartTime(pid: Int32) -> TimeInterval? {
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

/// Aliveness independent of the start-time query. `kill(pid, 0)` reports
/// existence without delivering a signal; EPERM still means the process
/// exists. `processStartTime` alone is ambiguous because a failed sysctl also
/// returns nil, and that must not be mistaken for "the app is gone".
private func processExists(pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

private func instanceStillAlive(_ marker: LivenessMarker) -> Bool {
    let liveStart = processStartTime(pid: marker.pid)
    let exists = liveStart != nil || processExists(pid: marker.pid)
    return WatchdogPolicy.appInstanceAlive(
        markerPID: marker.pid,
        markerStart: marker.processStartTime,
        livePID: exists ? marker.pid : nil,
        liveStart: liveStart
    )
}

// MARK: - Privileged restore

/// Signals exactly once: the helper can reply, fail, be invalidated and time
/// out in any order, and a late reply must not overwrite a real one.
private final class RestoreReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false
    private var outcome: (ok: Bool, message: String) = (false, "no reply")

    func finish(ok: Bool, message: String) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        outcome = (ok, message)
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> (ok: Bool, message: String)? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

/// Ask the daemon for a session-scoped restore over a privileged connection.
/// The request carries the protocol revision so a version-1 daemon refuses it
/// instead of doing something else. There is deliberately no `restoreAll`
/// fallback: persistent settings must not be touched by crash recovery.
private func requestSessionRestore() -> (ok: Bool, message: String) {
    let gate = RestoreReplyGate()
    let connection = NSXPCConnection(
        machServiceName: HelperService.machServiceName,
        options: .privileged
    )
    connection.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
    connection.invalidationHandler = {
        gate.finish(ok: false, message: "the privileged helper connection was invalidated before it answered")
    }
    connection.interruptionHandler = {
        gate.finish(ok: false, message: "the privileged helper connection was interrupted before it answered")
    }
    connection.resume()
    defer { connection.invalidate() }

    var request = HelperRequest(operation: .restoreSession)
    request.protocolVersion = Int(HelperService.protocolVersion)

    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
        gate.finish(ok: false, message: "the privileged helper is unavailable: \(error.localizedDescription)")
    }) as? HelperXPC else {
        return (false, "the privileged helper does not expose the expected XPC interface")
    }

    proxy.perform(HelperCoding.encode(request)) { data in
        guard let reply = HelperCoding.decode(HelperReply.self, from: data) else {
            gate.finish(ok: false, message: "the privileged helper returned an unreadable reply")
            return
        }
        guard reply.id == request.id else {
            gate.finish(ok: false, message: "the privileged helper replied to a different request; the reply was discarded")
            return
        }
        gate.finish(ok: reply.ok, message: reply.message)
    }

    guard let outcome = gate.wait(timeout: WatchdogPolicy.restoreTimeout) else {
        return (false, "the privileged helper did not answer within \(Int(WatchdogPolicy.restoreTimeout.rounded())) seconds")
    }
    return outcome
}

// MARK: - Decisions in the real world

/// Restore session leases once, then either clean up the marker or leave it
/// for the next attempt. `shouldGiveUp` caps the launchd retry loop; giving up
/// exits 0 *with the marker still present*, so the next launch or the app's
/// journal reconciliation still sees the interrupted session.
private func recoverSession(markerURL url: URL, observed: LivenessMarker?) -> Int32 {
    let state = loadRetryState()
    if WatchdogPolicy.shouldGiveUp(failures: state.failures) {
        logLine("giving up after \(state.failures) failed restore attempts; leaving the liveness record for the next launch")
        return 0
    }

    let outcome = requestSessionRestore()
    guard outcome.ok else {
        let failures = state.failures + 1
        saveRetryState(WatchdogRetryState(failures: failures,
                                          updatedAt: Date().timeIntervalSince1970))
        if WatchdogPolicy.shouldGiveUp(failures: failures) {
            logLine("session restore failed: \(outcome.message); attempt \(failures)/\(WatchdogPolicy.maximumRestoreFailures), giving up and leaving the liveness record for the next launch")
            return 0
        }
        let hint = Int(WatchdogPolicy.nextRetryDelay(failures: failures).rounded())
        logLine("session restore failed: \(outcome.message); attempt \(failures)/\(WatchdogPolicy.maximumRestoreFailures); exiting 1 so launchd restarts the agent after its ThrottleInterval (\(Int(WatchdogPolicy.launchdThrottleInterval))s). The \(hint)s exponential backoff value is only a cap hint for a future in-process retry loop, never the delay launchd uses")
        return 1   // launchd restarts the failed job after ThrottleInterval
    }

    logLine("session-scoped settings restored: \(outcome.message); clearing this instance's liveness record")
    removeMarkerIfUnchanged(at: url, observed: observed)
    resetRetryState()
    return 0
}

private func finish(marker: LivenessMarker, markerURL url: URL) -> Int32 {
    switch WatchdogPolicy.decide(hasMarker: true, appAlive: false, armed: marker.armed) {
    case .restoreSession:
        logLine("app pid \(marker.pid) is gone with an armed session (generation \(marker.generation)); restoring session-scoped settings")
        return recoverSession(markerURL: url, observed: marker)
    case .cleanExit:
        logLine("app pid \(marker.pid) is gone and the session was not armed; clearing the stale record")
        removeMarkerIfUnchanged(at: url, observed: marker)
        resetRetryState()
        return 0
    case .noMarker, .wait:
        return 0
    }
}

/// Observe the recorded instance. The agent stays alive while it runs, so a
/// crash is noticed by a process that was already there; launchd only has to
/// start one agent per login. The record is re-read every second, so a clean
/// clear and a relaunch with a new generation are both noticed.
private func observe(marker initial: LivenessMarker, markerURL url: URL) -> Int32 {
    var marker = initial
    var announcedWait = false

    while true {
        if instanceStillAlive(marker) {
            if !announcedWait {
                logLine("watching app pid \(marker.pid) generation \(marker.generation); the agent stays up while it runs")
                announcedWait = true
            }
            Thread.sleep(forTimeInterval: WatchdogPolicy.pollInterval)

            switch readMarkerFile(url) {
            case .absent:
                logLine("liveness record cleared (pid \(marker.pid)); clean exit")
                resetRetryState()
                return 0
            case .unusable(let reason):
                if instanceStillAlive(marker) {
                    logLine("liveness record became unusable (\(reason)) while the app is alive; continuing to wait")
                    continue
                }
                logLine("liveness record became unusable (\(reason)) and the app is gone; treating the session as interrupted")
                return recoverSession(markerURL: url, observed: marker)
            case .data(let contents):
                switch WatchdogPolicy.readMarker(contents) {
                case .absent:
                    logLine("liveness record cleared (pid \(marker.pid)); clean exit")
                    resetRetryState()
                    return 0
                case .corrupt:
                    if instanceStillAlive(marker) {
                        logLine("liveness record became corrupt while the app is alive; continuing to wait")
                        continue
                    }
                    logLine("liveness record became corrupt and the app is gone; treating the session as interrupted")
                    return recoverSession(markerURL: url, observed: marker)
                case .record(let newer):
                    // A rewrite (arm/disarm or a new launch) always restarts
                    // the evaluation with the newest identity.
                    marker = newer
                    continue
                }
            }
        }

        // The recorded instance is gone. Re-read once before deciding: a clean
        // quit clears the record, and a relaunch rewrites it.
        switch readMarkerFile(url) {
        case .absent:
            logLine("liveness record cleared (pid \(marker.pid)); clean exit")
            resetRetryState()
            return 0
        case .unusable(let reason):
            logLine("liveness record unusable after the app exited (\(reason)); treating the session as interrupted")
            return recoverSession(markerURL: url, observed: marker)
        case .data(let contents):
            switch WatchdogPolicy.readMarker(contents) {
            case .absent:
                logLine("liveness record cleared (pid \(marker.pid)); clean exit")
                resetRetryState()
                return 0
            case .corrupt:
                logLine("liveness record corrupt after the app exited; treating the session as interrupted")
                return recoverSession(markerURL: url, observed: marker)
            case .record(let newer):
                marker = newer
                if instanceStillAlive(newer) { continue }
                return finish(marker: newer, markerURL: url)
            }
        }
    }
}

private func runWatchdog() -> Int32 {
    let directory = supportDirectory()
    try? FileManager.default.createDirectory(at: directory,
                                             withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent(markerFileName)

    switch readMarkerFile(url) {
    case .absent:
        logLine("no liveness record; nothing to restore")
        resetRetryState()
        return 0
    case .unusable(let reason):
        // No PID, no start time: the record cannot prove a clean exit. Recover
        // the session scope once; never `restoreAll`.
        logLine("liveness record is unusable (\(reason)); treating the session as interrupted")
        return recoverSession(markerURL: url, observed: nil)
    case .data(let contents):
        switch WatchdogPolicy.readMarker(contents) {
        case .absent:
            logLine("no liveness record; nothing to restore")
            resetRetryState()
            return 0
        case .corrupt:
            logLine("liveness record is corrupt; treating the session as interrupted")
            return recoverSession(markerURL: url, observed: nil)
        case .record(let marker):
            return observe(marker: marker, markerURL: url)
        }
    }
}

exit(runWatchdog())
