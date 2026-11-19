// HelperClient — the app-side client for the privileged helper.
//
// The app itself never runs as root. This file owns exactly three things:
//   1. Helper installation: SMAppService for Developer ID builds, or a
//      one-time administrator LaunchDaemon install for ad-hoc builds.
//   2. A narrow, timed XPC surface (JSON in, JSON out) for HelperProtocol.
//   3. Removal of either installation, including the root helper and peer pin.
//
// Nothing here registers, installs, opens a connection, or prompts until a
// caller explicitly asks for it. Tests compile only the pure policy block at
// the bottom of this file; they never reach AppKit, ServiceManagement or XPC.

import AppKit
import Foundation
import Security
import ServiceManagement

enum HelperClientError: LocalizedError {
    case approvalRequired(String)
    case installation(String)
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .approvalRequired(let message), .installation(let message): return message
        case .notInstalled: return HelperInstallPolicy.notInstalledMessage
        }
    }
}

@MainActor
final class HelperClient {
    static let shared = HelperClient()

    /// `HelperClient.InstallState` is the public spelling; the storage and
    /// mapping live in the pure block so they can be tested without the app.
    typealias InstallState = HelperInstallState

    /// Legacy compatibility flag, always false. The administrator install
    /// fallback is disabled, so neither a signature failure nor any other
    /// registration error may offer it.
    private(set) var requiresAdminFallback = false

    private(set) var installState: InstallState

    private let daemonService: SMAppService
    private var openedApprovalSettings = false

    init(daemonPlistName: String = HelperService.daemonPlistName) {
        let service = SMAppService.daemon(plistName: daemonPlistName)
        self.daemonService = service
        self.installState = HelperInstallPolicy.state(for: Self.registrationStatus(service.status))
    }

    // MARK: - Registration state

    /// Re-read the live status. A daemon installed by the administrator
    /// fallback is a legacy plist in /Library/LaunchDaemons, which
    /// SMAppService.daemon(plistName:) does not report as registered, so
    /// consult the legacy status as well before declaring it not installed.
    func refreshInstallState() {
        let status = Self.registrationStatus(daemonService.status)
        if (status == .notRegistered || status == .notFound), legacyDaemonInstalled() {
            installState = .installed
            return
        }
        installState = HelperInstallPolicy.state(for: status)
    }

    /// Register through SMAppService and re-read the status. Approval is a
    /// separate user action: the system settings page is opened at most once
    /// per client lifetime and the call still reports failure until approved.
    func install() async -> Result<Void, Error> {
        refreshInstallState()
        if case .installed = installState {
            // A registered daemon from an earlier signature may be installed but
            // unreachable. Re-register it instead of reporting a false success.
            if await isReachable() {
                requiresAdminFallback = false
                return .success(())
            }
            if daemonService.status == .enabled {
                try? await daemonService.unregister()
                refreshInstallState()
            }
        }
        if !HelperCodeIdentity.hasTeamIdentifier() {
            return await installWithAdministratorPrompt()
        }

        do {
            try daemonService.register()
        } catch {
            let nsError = error as NSError
            refreshInstallState()
            switch installState {
            case .installed:
                requiresAdminFallback = false
                return .success(())
            case .requiresApproval:
                requiresAdminFallback = false
                openApprovalSettingsIfNeeded()
                return .failure(HelperClientError.approvalRequired(HelperInstallPolicy.approvalMessage))
            case .notInstalled, .failed:
                let signatureFailure = HelperInstallPolicy.isSignatureOrRegistrationFailure(
                    domain: nsError.domain,
                    code: nsError.code,
                    description: nsError.localizedDescription
                )
                requiresAdminFallback = HelperInstallPolicy.requiresAdministratorFallback(
                    after: installState,
                    signatureFailure: signatureFailure
                )
                let message = signatureFailure
                    ? HelperInstallPolicy.signatureFallbackMessage
                    : "The privileged helper could not be registered: \(nsError.localizedDescription)"
                installState = .failed(message)
                return .failure(HelperClientError.installation(message))
            }
        }

        refreshInstallState()
        switch installState {
        case .installed:
            requiresAdminFallback = false
            return .success(())
        case .requiresApproval:
            requiresAdminFallback = false
            openApprovalSettingsIfNeeded()
            return .failure(HelperClientError.approvalRequired(HelperInstallPolicy.approvalMessage))
        case .notInstalled:
            let message = "The privileged helper is still not registered after registration."
            installState = .failed(message)
            return .failure(HelperClientError.installation(message))
        case .failed(let message):
            return .failure(HelperClientError.installation(message))
        }
    }

    /// Unregister through SMAppService. An administrator-installed legacy
    /// daemon is not removed here; `uninstallWithAdministratorPrompt()` owns
    /// that path and the status must not be reported as gone until it is.
    func uninstall() async {
        // Only ask SMAppService to unregister a service it owns. A daemon
        // installed by the administrator fallback is not registered with
        // SMAppService, so `uninstallWithAdministratorPrompt()` must own it;
        // claiming failure (or success) here would be wrong.
        let status = Self.registrationStatus(daemonService.status)
        guard status == .enabled || status == .requiresApproval else {
            refreshInstallState()
            return
        }
        do {
            try await daemonService.unregister()
        } catch {
            installState = .failed("The privileged helper could not be unregistered: \(error.localizedDescription)")
            return
        }
        refreshInstallState()
    }

    private func openApprovalSettingsIfNeeded() {
        guard !openedApprovalSettings else { return }
        openedApprovalSettings = true
        guard let url = URL(string: HelperInstallPolicy.approvalSettingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Administrator-authorized fallback

    /// Disabled. The legacy fallback copied a launch daemon plist that uses
    /// `BundleProgram` into /Library/LaunchDaemons and never copied a
    /// root-owned helper executable, so launchd had no valid program path to
    /// run. It must not be offered or executed: this entry point fails closed
    /// with an actionable explanation without running osascript, copying a
    /// file, or claiming an install. The supported path is SMAppService
    /// approval (or a future signed installer).
    func installWithAdministratorPrompt() async -> Result<Void, Error> {
        let helperPath = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/WakelyHelper").path
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            let message = "This build does not contain its helper executable; reinstall Wakely."
            installState = .failed(message)
            return .failure(HelperClientError.installation(message))
        }
        guard let appHash = HelperCodeIdentity.cdhash(for: Bundle.main.executableURL ?? Bundle.main.bundleURL) else {
            let message = "This build has no code-directory hash to pin; reinstalling Wakely is required."
            installState = .failed(message)
            return .failure(HelperClientError.installation(message))
        }
        let watchdogURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WakelyWatchdog")
        let watchdogHash = HelperCodeIdentity.cdhash(for: watchdogURL)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakely-helper-\(UUID().uuidString)", isDirectory: true)
        let plistURL = directory.appendingPathComponent(HelperService.daemonPlistName)
        let peerURL = directory.appendingPathComponent("dev.wakely.helper.peer")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>\(HelperService.daemonLabel)</string>
        <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/\(HelperService.daemonLabel)</string></array>
        <key>MachServices</key><dict><key>\(HelperService.machServiceName)</key><true/></dict>
        <key>RunAtLoad</key><false/>
        <key>KeepAlive</key><false/>
        <key>ProcessType</key><string>Interactive</string>
        </dict></plist>
        """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(plist.utf8).write(to: plistURL, options: .atomic)
            var peer = "app=\(appHash)\n"
            if let watchdogHash { peer += "watchdog=\(watchdogHash)\n" }
            try Data(peer.utf8).write(to: peerURL, options: .atomic)
        } catch {
            return .failure(HelperClientError.installation("Could not prepare the helper installer: \(error.localizedDescription)"))
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let plan = HelperInstallCommandBuilder.administratorInstallPlan(
            helperSourcePath: helperPath,
            generatedPlistPath: plistURL.path,
            peerConfigPath: peerURL.path,
            daemonPlistName: HelperService.daemonPlistName,
            daemonLabel: HelperService.daemonLabel
        ) else {
            return .failure(HelperClientError.installation("The helper installer paths failed validation; nothing was installed."))
        }
        do {
            try await Self.runAdministratorCommand(plan.appleScriptArgument)
        } catch {
            installState = .failed(error.localizedDescription)
            return .failure(error)
        }
        // The daemon may take a moment to begin answering XPC.
        for _ in 0..<10 {
            if await isReachable() {
                requiresAdminFallback = false
                installState = .installed
                return .success(())
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let message = "The helper was installed but did not answer XPC. Check Console for WakelyHelper."
        installState = .failed(message)
        return .failure(HelperClientError.installation(message))
    }

    /// Remove an administrator-installed launch daemon, its root helper and
    /// the ad-hoc peer pin. Cancellation is failure, never success.
    func uninstallWithAdministratorPrompt(removeData: Bool = false) async -> Result<Void, Error> {
        guard let plan = HelperInstallCommandBuilder.uninstallPlan(
            daemonPlistName: HelperService.daemonPlistName,
            daemonLabel: HelperService.daemonLabel,
            removeData: removeData
        ) else {
            let message = "The privileged helper names failed validation; nothing was removed."
            installState = .failed(message)
            return .failure(HelperClientError.installation(message))
        }

        do {
            try await Self.runAdministratorCommand(plan.appleScriptArgument)
        } catch {
            installState = .failed(error.localizedDescription)
            return .failure(error)
        }

        requiresAdminFallback = false
        installState = .notInstalled
        return .success(())
    }

    /// Exactly one `osascript -e 'do shell script "..." with administrator
    /// privileges'` invocation. Cancellation is failure, never success.
    private static func runAdministratorCommand(_ appleScriptArgument: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: HelperInstallCommandBuilder.osascriptPath)
            process.arguments = ["-e", appleScriptArgument]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let details = String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HelperClientError.installation(
                    "Administrator authorization failed or was canceled (\(process.terminationStatus)): \(details)"
                )
            }
        }.value
    }

    // MARK: - XPC

    /// One XPC round trip with a timeout. The reply is only accepted when it
    /// carries the id of this request; anything else is reported as a failure
    /// instead of being confused with the answer to another call.
    func perform(_ request: HelperRequest) async -> HelperReply {
        await perform(request, timeout: HelperRequestPolicy.defaultTimeout)
    }

    /// Same round trip with an explicit deadline, used by ping and status.
    func perform(_ request: HelperRequest, timeout: Double) async -> HelperReply {
        if let reason = HelperRequestPolicy.invalidReason(
            operation: request.operation.rawValue,
            componentID: request.componentID,
            boolValue: request.boolValue,
            intValue: request.intValue,
            dateValue: request.dateValue
        ) {
            return .failure(request.id, reason)
        }
        let reply = await send(request, timeout: timeout)
        // A daemon from before the vocabulary change cannot decode the new
        // restore spelling. Restoring is idempotent, so one retry is safe.
        if !reply.ok, request.operation == .restoreComponent {
            var legacy = request
            legacy.id = UUID()
            legacy.operation = .restoreComponentLegacy
            return await send(legacy, timeout: timeout)
        }
        return reply
    }

    /// A ping with a short timeout. False covers not installed, not running,
    /// not approved, and a daemon that does not answer in time.
    func isReachable() async -> Bool {
        let reply = await perform(
            HelperRequest(operation: .ping),
            timeout: HelperRequestPolicy.pingTimeout
        )
        return reply.ok
    }

    /// Capability is a live `status` round trip, not a stored guess. When the
    /// helper is not installed or not approved there is nothing to ask.
    /// Quiet first-run setup: register the daemon through ServiceManagement with
    /// no prompts and no scripts. Failure is logged and ignored — assertions keep
    /// working and arming must never depend on this.
    func registerSilentlyIfNeeded() async {
        refreshInstallState()
        guard case .notInstalled = installState else {
            Diagnostics.log("privileged helper: \(installState.logDescription)")
            return
        }
        guard HelperCodeIdentity.hasTeamIdentifier() else {
            Diagnostics.log("privileged helper: local signing uses the explicit one-time administrator setup; skipping SMAppService registration")
            return
        }
        do {
            try SMAppService.daemon(plistName: HelperService.daemonPlistName).register()
            refreshInstallState()
            Diagnostics.log("privileged helper: registered (\(installState.logDescription))")
        } catch {
            Diagnostics.log("privileged helper: automatic registration unavailable (\(error.localizedDescription)); arming still works")
        }
    }

    func capability(_ operation: HelperOperation) async -> (supported: Bool, reason: String) {
        refreshInstallState()
        if let reason = HelperInstallPolicy.capabilityReason(for: installState) {
            return (false, reason)
        }
        let reply = await perform(
            HelperRequest(operation: .status),
            timeout: HelperRequestPolicy.statusTimeout
        )
        return HelperStatusPolicy.capability(
            operation: operation.rawValue,
            replyOK: reply.ok,
            message: reply.message,
            details: reply.details
        )
    }

    // MARK: - Authoritative request outcome (protocol 2)

    /// One live `status` round trip. The version is nil when the helper
    /// answered without a readable protocol version, which callers must treat
    /// as legacy/unknown rather than authoritative.
    func helperStatus() async -> (protocolVersion: Int?, details: [String: String], ok: Bool) {
        let reply = await perform(
            HelperRequest(operation: .status),
            timeout: HelperRequestPolicy.statusTimeout
        )
        return (
            protocolVersion: HelperStatusPolicy.protocolVersion(details: reply.details),
            details: reply.details,
            ok: reply.ok
        )
    }

    /// True only when a live status reply reports protocol 2 or newer. A
    /// missing, unreadable or older version is not authoritative support.
    func supportsAuthoritativeRequests() async -> Bool {
        let status = await helperStatus()
        return HelperStatusPolicy.supportsAuthoritativeRequests(
            replyOK: status.ok,
            details: status.details
        )
    }

    /// True when the helper answers but does not advertise protocol 2+.
    /// Callers must then reconcile an uncertain mutation through the
    /// status-lease report instead of treating `requestOutcome` as
    /// authoritative. False with no live answer means "unknown", not "modern".
    func isLegacyHelper() async -> Bool {
        let status = await helperStatus()
        return HelperStatusPolicy.isLegacyHelper(replyOK: status.ok, details: status.details)
    }

    /// Ask the helper's request journal what happened to `id`. The request is a
    /// protocol-2 `requestStatus` lookup carrying both the client protocol
    /// version and the original request UUID.
    ///
    /// A helper older than protocol 2 has no journal and answers `.unknown`
    /// (or refuses the operation); that result is never treated as success.
    /// Transport failures keep the `transportUncertain=yes` tag on the reply
    /// and map to `.unknown`; a daemon refusal stays untagged and also maps to
    /// `.unknown` unless it carries a complete, recognized journal entry.
    func requestOutcome(_ id: UUID) async -> HelperRequestOutcome {
        var request = HelperRequest(operation: .requestStatus)
        request.requestID = id
        request.protocolVersion = Int(HelperService.protocolVersion)
        let reply = await perform(request, timeout: HelperRequestPolicy.statusTimeout)
        return HelperRequestOutcome.parse(details: reply.details, requestID: id)
    }

    private func send(_ request: HelperRequest, timeout: Double) async -> HelperReply {
        // A transport failure does not cancel a mutation already queued by root.
        let requestID = request.id
        let transportFailure: @Sendable (String) -> HelperReply = { message in
            HelperReply(id: requestID, ok: false, message: message,
                        details: ["transportUncertain": "yes"])
        }
        let state = HelperXPCReply()
        return await withCheckedContinuation { (continuation: CheckedContinuation<HelperReply, Never>) in
            state.attach(continuation)
            let connection = NSXPCConnection(
                machServiceName: HelperService.machServiceName,
                options: .privileged
            )
            state.attach(connection)
            connection.remoteObjectInterface = NSXPCInterface(with: HelperXPC.self)
            connection.invalidationHandler = {
                state.finish(transportFailure("The privileged helper connection was invalidated before it answered."))
            }
            connection.interruptionHandler = {
                state.finish(transportFailure("The privileged helper connection was interrupted before it answered."))
            }
            connection.resume()

            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                state.finish(transportFailure("The privileged helper is unavailable: \(error.localizedDescription)"))
            }) as? HelperXPC else {
                state.finish(transportFailure("The privileged helper does not expose the expected XPC interface."))
                return
            }

            proxy.perform(HelperCoding.encode(request)) { data in
                guard let reply = HelperCoding.decode(HelperReply.self, from: data) else {
                    state.finish(transportFailure("The privileged helper returned an unreadable reply."))
                    return
                }
                guard reply.id == request.id else {
                    state.finish(transportFailure("The privileged helper replied to a different request; the reply was discarded."))
                    return
                }
                state.finish(reply)
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                state.finish(transportFailure("The privileged helper did not answer within \(Int(timeout.rounded())) seconds."))
            }
        }
    }

    // MARK: - Status mapping (ServiceManagement -> pure policy)

    private static func registrationStatus(_ status: SMAppService.Status) -> HelperRegistrationStatus {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    private func legacyDaemonInstalled() -> Bool {
        let url = URL(fileURLWithPath: HelperInstallCommandBuilder.launchDaemonsDirectory)
            .appendingPathComponent(HelperService.daemonPlistName)
        return Self.registrationStatus(SMAppService.statusForLegacyPlist(at: url)) == .enabled
    }
}

/// One component mutation and the UUID the helper journals for it. Callers need
/// the id even when the reply is a transport failure: protocol-2 `requestStatus`
/// is the only authoritative way to learn whether the queued write happened.
struct HelperRequestReceipt {
    let requestID: UUID
    let reply: HelperReply
}

/// The outcome of one read-only `wakeSchedules` query. `ok` false means the
/// helper could not read its ownership record or `pmset -g sched`; `wakes` is
/// still whatever could be parsed, but a caller must not treat that as the
/// complete owned set.
struct HelperWakeScheduleSnapshot {
    let ok: Bool
    let message: String
    let wakes: [OwnedWake]
}

/// The narrow layer component code is allowed to touch. Every method is one
/// validated HelperRequest; no component can express an arbitrary operation.
@MainActor
struct HelperComponentAPI {
    let client: HelperClient

    init(client: HelperClient) {
        self.client = client
    }

    init() {
        self.client = HelperClient.shared
    }

    func setLowPowerMode(_ on: Bool) async -> HelperRequestReceipt {
        await perform(HelperRequest(operation: .lowPowerMode, boolValue: on))
    }

    /// Suppress the supported battery wake sources and retain their previous
    /// values in the helper's lease store. The bool is always true here; undo
    /// goes through `restore(component:)`.
    func suppressWakeSources() async -> HelperRequestReceipt {
        await perform(HelperRequest(
            operation: .suppressWakeSources,
            componentID: "sleepMeansSleep",
            boolValue: true
        ))
    }

    /// 0 restores automatic fan control; 1...100 is a forced percentage.
    /// `requestID` is supplied by the caller when it must register the request
    /// before the call can suspend (fan in-flight tracking); otherwise a fresh
    /// id is used.
    func setFanPercent(_ percent: Int, requestID: UUID = UUID()) async -> HelperRequestReceipt {
        var request = HelperRequest(operation: .fanPercent, intValue: percent)
        request.id = requestID
        return await perform(request)
    }

    func setTouchIDUnlock(_ enabled: Bool) async -> HelperRequestReceipt {
        await perform(HelperRequest(operation: .touchIDUnlock, boolValue: enabled))
    }

    func setBootOnLidOpen(_ allowed: Bool) async -> HelperRequestReceipt {
        await perform(HelperRequest(operation: .bootOnLidOpen, boolValue: allowed))
    }

    func setAutoRestart(_ on: Bool) async -> HelperRequestReceipt {
        await perform(HelperRequest(operation: .autoRestartAfterPowerLoss, boolValue: on))
    }

    func restore(component: String) async -> HelperRequestReceipt {
        await perform(HelperRequest(operation: .restoreComponent, componentID: component))
    }

    /// One session-scoped sweep. Protocol 2 restores only leases owned by the
    /// session; persistent settings are deliberately untouched.
    func restoreSession() async -> HelperRequestReceipt {
        await perform(HelperRequest(operation: .restoreSession))
    }

    // MARK: - Helper-owned one-off wakes (protocol 3)

    /// Create one wake at `date` and record this component as its owner. The
    /// helper validates the instant (finite, at least 30 s ahead, within 30
    /// days), persists the ownership record, runs pmset and verifies the
    /// event's presence before reporting success. A `componentID` is optional and
    /// only labels the ownership record; `sleepUntilReset` is the documented
    /// caller.
    func scheduleWake(at date: Date, componentID: String = "sleepUntilReset") async -> HelperRequestReceipt {
        await perform(HelperRequest(
            operation: .scheduleWake,
            componentID: componentID,
            dateValue: date.timeIntervalSince1970
        ))
    }

    /// Cancel the one helper-owned wake matching `date` (within one second).
    /// The helper refuses an instant it does not own; nothing is canceled by
    /// date alone and `cancelall` is never used.
    func cancelWake(at date: Date) async -> HelperRequestReceipt {
        await perform(HelperRequest(
            operation: .cancelWake,
            dateValue: date.timeIntervalSince1970
        ))
    }

    /// Read-only list of helper-owned wakes, parsed from the reply details.
    /// An unreadable or failed reply yields an empty array: callers that need
    /// to distinguish "none owned" from "unknown" must use
    /// `wakeScheduleSnapshot()`.
    func wakeSchedules() async -> [OwnedWake] {
        await wakeScheduleSnapshot().wakes
    }

    /// Same read, with the reply outcome retained. Reconciliation must not
    /// schedule a duplicate event when the helper could not report what it
    /// already owns, so the controller checks `ok` before changing anything.
    func wakeScheduleSnapshot() async -> HelperWakeScheduleSnapshot {
        let receipt = await perform(HelperRequest(operation: .wakeSchedules))
        let wakes = HelperWakeSchedulePolicy.parse(details: receipt.reply.details)
        // The daemon also reports how many entries it believes it owns. A
        // mismatch means an entry did not survive parsing (schema drift or a
        // malformed record); treating the set as incomplete keeps a reconcile
        // from scheduling a second event for a wake the helper already owns.
        let declared = receipt.reply.details["count"].flatMap { raw -> Int? in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let count = Int(trimmed), count >= 0 else { return nil }
            return count
        }
        let complete = declared == nil || declared == wakes.count
        return HelperWakeScheduleSnapshot(
            ok: receipt.reply.ok && complete,
            message: complete
                ? receipt.reply.message
                : "the helper reported \(declared ?? -1) owned wakes but \(wakes.count) were readable",
            wakes: wakes
        )
    }

    private func perform(_ request: HelperRequest) async -> HelperRequestReceipt {
        let reply = await client.perform(request)
        return HelperRequestReceipt(requestID: request.id, reply: reply)
    }
}

/// Resumes an XPC continuation exactly once from any queue: XPC can answer,
/// fail, be invalidated and time out in any order. Without the gate a late
/// reply after the timeout would trap a checked continuation.
private final class HelperXPCReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HelperReply, Never>?
    private var connection: NSXPCConnection?

    func attach(_ continuation: CheckedContinuation<HelperReply, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ connection: NSXPCConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func finish(_ reply: HelperReply) {
        lock.lock()
        let pending = continuation
        continuation = nil
        let connection = self.connection
        self.connection = nil
        lock.unlock()

        guard let pending else { return }
        pending.resume(returning: reply)
        connection?.invalidate()
    }
}

// BEGIN TESTABLE HELPER POLICY
//
// Pure policy: no AppKit, no ServiceManagement, no XPC, no file system, no
// clock. Tests compile this block on its own (see Tests/HelperClientPolicy.swift
// and Tests/test_helper_client_policy.py) and never register or install.

/// Mirrors the SMAppService status values without importing ServiceManagement,
/// so status mapping and every user-facing string can be tested with no system
/// access.
enum HelperRegistrationStatus: Int, CaseIterable {
    case notRegistered = 0
    case enabled = 1
    case requiresApproval = 2
    case notFound = 3
    case unknown = -1

    init(rawCode: Int) {
        self = HelperRegistrationStatus(rawValue: rawCode) ?? .unknown
    }
}

enum HelperInstallState: Equatable {
    case notInstalled
    case requiresApproval
    case installed
    case failed(String)
}

extension HelperInstallState {
    /// One-line state for the diagnostics log; never shown as a verdict.
    var logDescription: String {
        switch self {
        case .notInstalled: return "not installed"
        case .requiresApproval: return "waiting for approval in Login Items"
        case .installed: return "installed"
        case .failed(let reason): return "unavailable: \(reason)"
        }
    }
}

enum HelperInstallPolicy {
    /// Login Items & Extensions is where a daemon waiting for approval lives.
    static let approvalSettingsURL = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"

    static let notInstalledReason = "the privileged helper is not installed"
    static let approvalReason = "the privileged helper requires approval in System Settings > General > Login Items & Extensions"
    static let notInstalledMessage = "The privileged helper is not installed."
    static let installedMessage = "The privileged helper is installed."
    static let approvalMessage = "The privileged helper is registered but not approved yet. Approve Wakely in System Settings > General > Login Items & Extensions, then return and try again."
    static let signatureFallbackMessage = "SMAppService refused this build's code signature. You can either sign with an Apple Developer ID, or use Install with Administrator to place the helper as a root LaunchDaemon once."
    static let unknownStatusMessage = "The privileged helper reported an unrecognized registration status."

    static func state(for status: HelperRegistrationStatus) -> HelperInstallState {
        switch status {
        case .enabled: return .installed
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .notInstalled
        case .unknown: return .failed(unknownStatusMessage)
        }
    }

    static func message(for state: HelperInstallState) -> String {
        switch state {
        case .notInstalled: return notInstalledMessage
        case .requiresApproval: return approvalMessage
        case .installed: return installedMessage
        case .failed(let message): return message
        }
    }

    /// `nil` means a status round trip is worth attempting.
    static func capabilityReason(for state: HelperInstallState) -> String? {
        switch state {
        case .notInstalled: return notInstalledReason
        case .requiresApproval: return approvalReason
        case .installed, .failed: return nil
        }
    }

    /// A registration error that means "this build cannot use SMAppService"
    /// rather than "the user has not approved yet". Cancellation is not a
    /// reason to escalate to an administrator prompt.
    static func isSignatureOrRegistrationFailure(domain: String, code: Int, description: String) -> Bool {
        let text = description.lowercased()
        if code == -128 || code == -60006 { return false }
        if text.contains("cancel") { return false }
        if domain == "SMAppServiceErrorDomain" { return true }
        let keywords = [
            "signature", "code sign", "codesign", "not signed", "unsigned",
            "registration", "register", "operation not permitted",
            "not authorized", "not permitted",
        ]
        return keywords.contains { text.contains($0) }
    }

    /// Always false. The administrator install fallback is disabled because it
    /// could not produce a launchd job with a valid executable path, so no
    /// signature or registration failure may offer it. Retained for callers
    /// that still consult the property and to document the rejected path.
    static func requiresAdministratorFallback(after state: HelperInstallState, signatureFailure: Bool) -> Bool {
        guard signatureFailure else { return false }
        switch state {
        case .notInstalled, .failed: return true
        case .requiresApproval, .installed: return false
        }
    }
}

enum HelperRequestPolicy {
    static let pingTimeout: Double = 2
    static let statusTimeout: Double = 5
    static let defaultTimeout: Double = 5
    static let fanPercentRange = 30...100
    static let maximumComponentIDLength = 128
    /// Same calendar bound the helper's wake store enforces, kept here so an
    /// impossible instant is refused before any XPC connection exists.
    static let maximumWakeEpoch: Double = 4_102_444_800  // 2100-01-01

    static func timeout(for operation: String) -> Double {
        operation == "ping" ? pingTimeout : defaultTimeout
    }

    /// `nil` means the request may be sent. Every rule is closed: unknown
    /// operations, stray values, and missing identifiers are rejected before
    /// any XPC connection exists.
    ///
    /// `dateValue` is defaulted so every pre-protocol-3 call site and test keeps
    /// compiling; an operation that does not own a date rejects a stray one.
    static func invalidReason(operation: String, componentID: String, boolValue: Bool?, intValue: Int?, dateValue: Double? = nil) -> String? {
        switch operation {
        case "ping", "status", "requestStatus", "restoreSession", "restoreAll":
            if boolValue != nil { return "\(operation) does not take a boolean value." }
            if intValue != nil { return "\(operation) does not take an integer value." }
            if dateValue != nil { return "\(operation) does not take a date value." }
            if !componentID.isEmpty { return "\(operation) does not take a component identifier." }

        case "lowPowerMode", "touchIDUnlock", "bootOnLidOpen", "autoRestartAfterPowerLoss":
            if boolValue == nil { return "\(operation) requires a boolean value." }
            if intValue != nil { return "\(operation) does not take an integer value." }
            if dateValue != nil { return "\(operation) does not take a date value." }
            if !componentID.isEmpty { return "\(operation) does not take a component identifier." }

        case "suppressWakeSources":
            guard boolValue == true else {
                return "suppressWakeSources requires a true boolean value."
            }
            if intValue != nil { return "suppressWakeSources does not take an integer value." }
            if dateValue != nil { return "suppressWakeSources does not take a date value." }
            if componentID != "sleepMeansSleep" {
                return "suppressWakeSources is owned by sleepMeansSleep."
            }

        case "fanPercent":
            guard let intValue else { return "fanPercent requires a percentage." }
            guard intValue == 0 || fanPercentRange.contains(intValue) else {
                return "fanPercent must be 30...100 (0 restores automatic control)."
            }
            if boolValue != nil { return "fanPercent does not take a boolean value." }
            if dateValue != nil { return "fanPercent does not take a date value." }
            if !componentID.isEmpty { return "fanPercent does not take a component identifier." }

        case "restoreComponent", "restoreModule": // legacy wire spelling
            if boolValue != nil || intValue != nil || dateValue != nil {
                return "restoreComponent takes only a component identifier."
            }
            let trimmed = componentID.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "restoreComponent requires a component identifier." }
            if trimmed != componentID {
                return "restoreComponent requires a component identifier without surrounding whitespace."
            }
            if componentID.count > maximumComponentIDLength {
                return "restoreComponent component identifier is too long."
            }
            if componentID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
                return "restoreComponent component identifier contains control characters."
            }

        case "scheduleWake", "cancelWake":
            // Both take exactly one instant. The helper additionally enforces
            // "30 s ahead, 30 days out, representable in pmset's local format";
            // this layer only refuses an obviously unusable value.
            if boolValue != nil { return "\(operation) does not take a boolean value." }
            if intValue != nil { return "\(operation) does not take an integer value." }
            guard let dateValue else {
                return "\(operation) requires a wake time as Unix epoch seconds."
            }
            guard dateValue.isFinite else {
                return "\(operation) requires a finite wake time."
            }
            guard dateValue >= 0, dateValue < maximumWakeEpoch else {
                return "\(operation) wake time is outside the supported calendar range."
            }
            // An empty componentID is allowed: the helper labels the ownership
            // record with the component that owns wake events. A supplied one must
            // be the same validated shape every other component identifier has.
            if !componentID.isEmpty {
                let trimmed = componentID.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || trimmed != componentID {
                    return "\(operation) component identifier has surrounding whitespace."
                }
                if componentID.count > maximumComponentIDLength {
                    return "\(operation) component identifier is too long."
                }
                if componentID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
                    return "\(operation) component identifier contains control characters."
                }
            }

        case "wakeSchedules":
            if boolValue != nil { return "wakeSchedules does not take a boolean value." }
            if intValue != nil { return "wakeSchedules does not take an integer value." }
            if dateValue != nil { return "wakeSchedules does not take a date value." }
            if !componentID.isEmpty { return "wakeSchedules does not take a component identifier." }

        default:
            return "Unknown privileged operation."
        }
        return nil
    }

    static func isValid(operation: String, componentID: String, boolValue: Bool?, intValue: Int?, dateValue: Double? = nil) -> Bool {
        invalidReason(operation: operation, componentID: componentID, boolValue: boolValue,
                      intValue: intValue, dateValue: dateValue) == nil
    }
}

/// One helper-owned wake event as reported by `wakeSchedules`.
///
/// The daemon's details are keyed `wake.<uuid>.epoch|kind|createdBy|present`.
/// Only a finite epoch inside the supported calendar is accepted: without the
/// instant there is nothing a cancel could safely match. `present` is nil when
/// the helper could not read `pmset -g sched`, never a guess.
struct OwnedWake: Equatable, Sendable {
    let id: UUID
    let at: Date
    let kind: String
    let createdBy: String?
    let present: Bool?
}

enum HelperWakeSchedulePolicy {
    /// Parse the `wakeSchedules` reply details. Unrelated keys, entries without
    /// a usable UUID or epoch, conflicting duplicates and any kind other than
    /// `wake` are dropped rather than guessed at. Results are ordered by time.
    static func parse(details: [String: String]) -> [OwnedWake] {
        var epochs: [UUID: Double] = [:]
        var kinds: [UUID: String] = [:]
        var owners: [UUID: String] = [:]
        var presence: [UUID: Bool] = [:]
        var rejected: Set<UUID> = []

        let prefix = "wake."
        for (key, rawValue) in details {
            guard key.hasPrefix(prefix) else { continue }
            let remainder = key.dropFirst(prefix.count)
            guard let separator = remainder.firstIndex(of: ".") else { continue }
            let rawID = String(remainder[..<separator])
            guard let id = UUID(uuidString: rawID) else { continue }
            let field = remainder[remainder.index(after: separator)...].lowercased()
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

            switch field {
            case "epoch":
                guard let epoch = Double(value), epoch.isFinite,
                      epoch >= 0, epoch < HelperRequestPolicy.maximumWakeEpoch else {
                    rejected.insert(id)
                    continue
                }
                if let existing = epochs[id], abs(existing - epoch) > 0.0001 {
                    // Two different instants for one identity make ownership
                    // ambiguous; neither is safe to cancel.
                    rejected.insert(id)
                    continue
                }
                epochs[id] = epoch
            case "kind":
                let kind = value.lowercased()
                if kind == "wake" {
                    kinds[id] = kind
                } else {
                    rejected.insert(id)
                }
            case "createdby":
                if !value.isEmpty { owners[id] = value }
            case "present":
                switch value.lowercased() {
                case "yes", "true", "1": presence[id] = true
                case "no", "false", "0": presence[id] = false
                default: presence[id] = nil
                }
            default:
                continue
            }
        }

        return epochs
            .filter { !rejected.contains($0.key) }
            .map { id, epoch in
                OwnedWake(
                    id: id,
                    at: Date(timeIntervalSince1970: epoch),
                    kind: kinds[id] ?? "wake",
                    createdBy: owners[id],
                    present: presence[id]
                )
            }
            .sorted { $0.at < $1.at }
    }
}

enum HelperStatusPolicy {
    /// Daemon capability convention: `details[operation]` is a boolean-ish
    /// word ("supported"/"unsupported", "1"/"0", "true"/"false") and the
    /// optional `details["<operation>.reason"]` explains a refusal. An
    /// answering helper that does not enumerate an operation is treated as
    /// supporting it; only an explicit negative or a failed reply refuses.
    static func capability(operation: String, replyOK: Bool, message: String, details: [String: String]) -> (supported: Bool, reason: String) {
        let reportedReason = details["\(operation).reason"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackReason = message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard replyOK else {
            return (false, fallbackReason.isEmpty ? "the privileged helper could not report its capabilities" : fallbackReason)
        }

        let raw = details[operation]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch raw {
        case "1", "true", "yes", "supported", "enabled", "available":
            if let reportedReason, !reportedReason.isEmpty {
                return (true, reportedReason)
            }
            return (true, fallbackReason.isEmpty ? "reported as supported by the privileged helper" : fallbackReason)
        case "0", "false", "no", "unsupported", "disabled", "unavailable":
            let reason = reportedReason ?? (fallbackReason.isEmpty ? "the privileged helper reports \(operation) is unsupported" : fallbackReason)
            return (false, reason)
        default:
            let reason = reportedReason
                ?? "the privileged helper did not report support for \(operation); reinstall the current helper"
            return (false, reason)
        }
    }

    /// Protocol 2 adds the request journal and `requestStatus`, and is the
    /// minimum version for treating a reported outcome as authoritative.
    static let minimumAuthoritativeProtocolVersion = 2

    /// `details["protocol"]` is the daemon's advertised protocol; the
    /// `protocolVersion` and `protocol.version` spellings are accepted too. A
    /// present but unreadable version is nil, never a guess.
    static func protocolVersion(details: [String: String]) -> Int? {
        for key in ["protocol", "protocolVersion", "protocol.version"] {
            guard let raw = details[key] else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let version = Int(trimmed), version >= 0 else { return nil }
            return version
        }
        return nil
    }

    /// True only for a successful live status reply advertising protocol 2+.
    /// A missing or unreadable version is not authoritative support.
    static func supportsAuthoritativeRequests(replyOK: Bool, details: [String: String]) -> Bool {
        guard replyOK, let version = protocolVersion(details: details) else { return false }
        return version >= minimumAuthoritativeProtocolVersion
    }

    /// True when the helper answered but did not advertise protocol 2+.
    /// A failed or absent status reply is unknown capability, not legacy.
    static func isLegacyHelper(replyOK: Bool, details: [String: String]) -> Bool {
        guard replyOK else { return false }
        return !supportsAuthoritativeRequests(replyOK: true, details: details)
    }
}

/// Authoritative outcome of one privileged mutation, as reported by the
/// protocol-2 request journal. `.unknown` is the only safe answer for a
/// missing, unreadable, inconsistent or transport-uncertain entry; a parse
/// failure must never be reported as success.
enum HelperRequestOutcome: Equatable {
    case succeeded(leaseComponent: String?)
    case failedBeforeMutation
    case failedWithRecoveryLease(leaseComponent: String?)
    case interruptedUnknown
    case accepted
    case running
    case unknown

    /// Parses only this request's keys (`request.<uuid>.*`) and ignores any
    /// other UUID. The state comes from `request.<uuid>.state` or
    /// `request.<uuid>.outcome`; a conflicting or empty value is unknown. The
    /// optional component lease comes from `request.<uuid>.leaseComponent` or
    /// `request.<uuid>.lease`. Anything unrecognized maps to `.unknown`.
    static func parse(details: [String: String], requestID: UUID) -> HelperRequestOutcome {
        let transport = details["transportUncertain"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if transport == "yes" || transport == "true" || transport == "1" {
            return .unknown
        }

        let prefix = "request."
        var stateValues: [String] = []
        var leaseValues: [String] = []
        for (key, rawValue) in details {
            let loweredKey = key.lowercased()
            guard loweredKey.hasPrefix(prefix) else { continue }
            let remainder = loweredKey.dropFirst(prefix.count)
            guard let separator = remainder.firstIndex(of: ".") else { continue }
            let rawID = String(remainder[..<separator])
            guard let candidate = UUID(uuidString: rawID), candidate == requestID else { continue }
            let field = String(remainder[remainder.index(after: separator)...])
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch field {
            case "state", "outcome":
                stateValues.append(value.lowercased())
            case "leasecomponent", "lease":
                if !value.isEmpty { leaseValues.append(value) }
            default:
                break
            }
        }

        let distinctStates = Set(stateValues)
        guard distinctStates.count == 1, let state = distinctStates.first, !state.isEmpty else {
            return .unknown
        }

        var lease: String? = nil
        if !leaseValues.isEmpty {
            let distinctLeases = Set(leaseValues)
            guard distinctLeases.count == 1, let onlyLease = distinctLeases.first, !onlyLease.isEmpty else {
                return .unknown
            }
            lease = onlyLease
        }

        switch state {
        case "succeeded": return .succeeded(leaseComponent: lease)
        case "failedbeforemutation": return .failedBeforeMutation
        case "failedwithrecoverylease": return .failedWithRecoveryLease(leaseComponent: lease)
        case "interruptedunknown": return .interruptedUnknown
        case "accepted": return .accepted
        case "running": return .running
        default: return .unknown
        }
    }
}

struct HelperInstallPlan: Equatable {
    let sourcePlistPath: String
    let installedPlistPath: String
    let installedHelperPath: String
    let daemonLabel: String
    let shellScript: String
    let appleScriptArgument: String
}

/// Builds the exact administrator command. Pure string construction only: the
/// caller supplies paths that it has already resolved inside Bundle.main, and
/// every component is validated here again. Nothing user-entered is accepted.
///
/// REVIEWED AND REJECTED: `installPlan` documents the abandoned legacy install
/// and is retained only for its validation tests. It must never be wired to an
/// install action: the copied plist uses `BundleProgram`, so the launchd job
/// has no standalone executable path, and no root-owned helper binary is
/// staged. Use SMAppService (or a future signed installer) instead.
/// `uninstallPlan` remains in use for removing a previously installed job.
enum HelperCodeIdentity {
    /// Code-directory hash of a Mach-O, used to pin ad-hoc peers.
    static func cdhash(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let unique = fields[kSecCodeInfoUnique as String] as? Data,
              !unique.isEmpty else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }

    /// SMAppService requires a Team ID. Ad-hoc and self-signed builds do not
    /// have one, so they use the administrator LaunchDaemon instead.
    static func hasTeamIdentifier() -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let team = fields[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return false }
        return true
    }
}

enum HelperInstallCommandBuilder {
    static let launchDaemonsDirectory = "/Library/LaunchDaemons"
    static let osascriptPath = "/usr/bin/osascript"

    static func installPlan(sourcePlistPath: String, daemonPlistName: String, daemonLabel: String) -> HelperInstallPlan? {
        guard isSafePlistName(daemonPlistName),
              isSafeLabel(daemonLabel),
              isSafeBundledPlistPath(sourcePlistPath, daemonPlistName: daemonPlistName) else {
            return nil
        }
        let installed = launchDaemonsDirectory + "/" + daemonPlistName
        let domain = "system/" + daemonLabel
        let shell = "set -eu; "
            + "/usr/bin/install -o root -g wheel -m 0644 \(quote(sourcePlistPath)) \(quote(installed)); "
            + "/bin/launchctl bootout \(quote(domain)) 2>/dev/null || /usr/bin/true; "
            + "/bin/launchctl bootstrap system \(quote(installed)); "
            + "/bin/launchctl print \(quote(domain)) >/dev/null"
        return HelperInstallPlan(
            sourcePlistPath: sourcePlistPath,
            installedPlistPath: installed,
            installedHelperPath: "",
            daemonLabel: daemonLabel,
            shellScript: shell,
            appleScriptArgument: appleScript(shellScript: shell)
        )
    }

    /// One-time administrator install for builds without an Apple Developer ID.
    /// It copies a signed helper and a generated launchd plist as root, then
    /// bootstraps the job. No SMAppService, Team ID, or Apple ID is involved.
    static func administratorInstallPlan(helperSourcePath: String, generatedPlistPath: String,
                                         peerConfigPath: String,
                                         daemonPlistName: String, daemonLabel: String) -> HelperInstallPlan? {
        guard isSafePlistName(daemonPlistName), isSafeLabel(daemonLabel),
              isSafeHelperPath(helperSourcePath),
              isSafeGeneratedPlistPath(generatedPlistPath),
              isSafePeerConfigPath(peerConfigPath) else { return nil }
        let installedHelper = "/Library/PrivilegedHelperTools/" + daemonLabel
        let installedPlist = launchDaemonsDirectory + "/" + daemonPlistName
        let domain = "system/" + daemonLabel
        let shell = "set -eu; "
            + "/usr/bin/install -d -o root -g wheel -m 0755 '/Library/PrivilegedHelperTools'; "
            + "/usr/bin/install -o root -g wheel -m 0755 \(quote(helperSourcePath)) \(quote(installedHelper)); "
            + "/usr/bin/install -o root -g wheel -m 0644 \(quote(generatedPlistPath)) \(quote(installedPlist)); "
            + "/usr/bin/install -o root -g wheel -m 0644 \(quote(peerConfigPath)) '/Library/PrivilegedHelperTools/dev.wakely.helper.peer'; "
            + "/bin/launchctl bootout \(quote(domain)) 2>/dev/null || /usr/bin/true; "
            + "/bin/launchctl bootstrap system \(quote(installedPlist)); "
            + "/bin/launchctl enable \(quote(domain)); "
            + "/bin/launchctl print \(quote(domain)) >/dev/null"
        return HelperInstallPlan(
            sourcePlistPath: generatedPlistPath,
            installedPlistPath: installedPlist,
            installedHelperPath: installedHelper,
            daemonLabel: daemonLabel,
            shellScript: shell,
            appleScriptArgument: appleScript(shellScript: shell)
        )
    }

    private static func isSafeHelperPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.contains("/Contents/MacOS/") && path.hasSuffix("/WakelyHelper")
            && !path.contains("..") && !path.contains("//") && path.count <= 4096
            && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || $0 == "'" || $0 == "\\" }
    }

    private static func isSafeGeneratedPlistPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".plist")
            && !path.contains("..") && !path.contains("//") && path.count <= 4096
            && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || $0 == "'" || $0 == "\\" }
    }

    private static func isSafePeerConfigPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.hasSuffix(".peer")
            && !path.contains("..") && !path.contains("//") && path.count <= 4096
            && !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 || $0 == "'" || $0 == "\\" }
    }

    /// `removeData` also deletes the helper's root-owned backups and journals;
    /// only a full Delete Wakely wants that, after every setting was restored.
    static func uninstallPlan(daemonPlistName: String, daemonLabel: String,
                              removeData: Bool = false) -> HelperInstallPlan? {
        guard isSafePlistName(daemonPlistName), isSafeLabel(daemonLabel) else { return nil }
        let installed = launchDaemonsDirectory + "/" + daemonPlistName
        let domain = "system/" + daemonLabel
        let shell = "set -eu; "
            + "/bin/launchctl bootout \(quote(domain)) 2>/dev/null || /usr/bin/true; "
            + "/bin/rm -f \(quote(installed)) '/Library/PrivilegedHelperTools/dev.wakely.helper' '/Library/PrivilegedHelperTools/dev.wakely.helper.peer'; "
            + (removeData ? "/bin/rm -rf '/Library/Application Support/dev.wakely.helper'; " : "")
            + "[ ! -e \(quote(installed)) ]"
        return HelperInstallPlan(
            sourcePlistPath: "",
            installedPlistPath: installed,
            installedHelperPath: "",
            daemonLabel: daemonLabel,
            shellScript: shell,
            appleScriptArgument: appleScript(shellScript: shell)
        )
    }

    /// One AppleScript `do shell script` argument. Backslashes and quotes are
    /// escaped; the shell script itself is a single line so no newline needs
    /// to survive AppleScript string parsing.
    static func appleScript(shellScript: String) -> String {
        let escaped = shellScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    private static func quote(_ value: String) -> String {
        "'\(value)'"
    }

    private static func isSafePlistName(_ value: String) -> Bool {
        value.hasSuffix(".plist")
            && !value.hasPrefix(".")
            && isSafeName(value)
            && value.count <= 200
    }

    private static func isSafeLabel(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, let first = value.unicodeScalars.first,
              isAlphanumeric(first) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            isAlphanumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    private static func isSafeName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            isAlphanumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_"
        }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 48 && scalar.value <= 57)
            || (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
    }

    private static func isSafeBundledPlistPath(_ path: String, daemonPlistName: String) -> Bool {
        guard path.hasPrefix("/"),
              !path.contains(".."),
              !path.contains("//"),
              path.contains("/Contents/Library/LaunchDaemons/"),
              path.hasSuffix("/" + daemonPlistName),
              path.count <= 4096 else {
            return false
        }
        // Single quoting is the only shell protection used; a single quote or
        // a control character would break out of it.
        return !path.unicodeScalars.contains { scalar in
            scalar.value < 32 || scalar.value == 127 || scalar == "'" || scalar == "\\"
        }
    }
}
// END TESTABLE HELPER POLICY
