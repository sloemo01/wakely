// Wakely privileged helper — XPC listener.
//
// This is the root daemon's front door. It publishes HelperService's mach
// service, accepts XPC connections, decodes exactly one HelperRequest per
// call, hands it to Operations (the allowlist), and encodes a HelperReply.
// There is no generic shell: the peer can only name a HelperOperation and
// supply the primitive values that operation defines.
//
// Security posture:
//  * The process refuses to run without euid 0 (exit 78), because every
//    operation writes a system setting.
//  * New connections must use an allowlisted app/watchdog identifier AND the
//    exact signing certificate of this installed helper. Self-signed development
//    builds are supported without trusting a forgeable certificate common name.
//    Ad-hoc builds have no certificate and refuse to expose this root endpoint.
//    Signing identifiers and certificate display names alone are never trusted.
//  * NSXPCConnection's per-connection setCodeSigningRequirement(_:) (macOS
//    13+) is not used in addition to the listener requirement: it would
//    duplicate the same certificate-pinned identity checks. The listener's
//    signing requirement is the enforcement boundary, not peer-supplied IDs.
//  * Requests are decoded into the closed HelperOperation enum and validated
//    again inside Operations. No peer-supplied executable, argument, path,
//    environment variable, or shell string exists anywhere in the daemon.

import Darwin
import Foundation

// MARK: - Logging

private enum HelperLog {
    private static let lock = NSLock()

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] wakely-helper[\(getpid())]: \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        FileHandle.standardError.write(data)
        lock.unlock()
    }
}

// MARK: - Exported object

private final class HelperServiceObject: NSObject, HelperXPC {
    /// Operations are synchronous and can run external tools, so they never
    /// run on the XPC message-delivery thread. Several connections may be in
    /// flight; Operations serializes mutations itself.
    private static let queue = DispatchQueue(
        label: "dev.wakely.helper.operations",
        qos: .userInitiated,
        attributes: .concurrent
    )

    func perform(_ request: Data, reply: @escaping (Data) -> Void) {
        guard let decoded = HelperCoding.decode(HelperRequest.self, from: request) else {
            let failure = HelperReply(
                id: UUID(),
                ok: false,
                message: "The helper received a request it could not decode."
            )
            reply(HelperCoding.encode(failure))
            return
        }

        Self.queue.async {
            let answer = Operations.perform(decoded)
            reply(HelperCoding.encode(answer))
        }
    }
}

// MARK: - Listener delegate

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperXPC.self)
        newConnection.exportedObject = HelperServiceObject()

        newConnection.invalidationHandler = {
            HelperLog.write("connection invalidated")
        }
        newConnection.interruptionHandler = {
            HelperLog.write("connection interrupted")
        }

        newConnection.resume()
        HelperLog.write("accepted connection from pid \(newConnection.processIdentifier)")
        return true
    }
}

// MARK: - Signals

private var signalSources: [DispatchSourceSignal] = []

private func installSignalHandlers() {
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
        source.setEventHandler {
            HelperLog.write("stopping on signal \(number)")
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

// MARK: - Main

guard geteuid() == 0 else {
    HelperLog.write("refusing to start: effective uid \(geteuid()), expected 0 (root)")
    exit(78)
}

HelperLog.write("starting \(HelperService.machServiceName)")

let listener = NSXPCListener(machServiceName: HelperService.machServiceName)

// Reject peers that are neither the app nor signed by this project's
// development identity before the delegate is even consulted. See the
// security note at the top of this file.
guard let peerRequirement = HelperPeerPolicy.requirementForRunningHelper(
    peerConfigPath: HelperPeerPolicy.peerConfigPath
) else {
    HelperLog.write("refusing to listen: no certificate or ad-hoc cdhash peer identity is installed")
    exit(78)
}
listener.setConnectionCodeSigningRequirement(peerRequirement)

// Requests that were accepted or running when the previous process died are
// neither successes nor failures. Convert them before serving any new request
// so a status query reports `interruptedUnknown` instead of a stale `running`.
HelperLog.write(Operations.recoverJournalAtStartup())

private let delegate = ServiceDelegate()
listener.delegate = delegate

installSignalHandlers()
listener.resume()
HelperLog.write(
    "listening on \(HelperService.machServiceName), version \(Operations.version), "
        + "protocol \(HelperService.protocolVersion)"
)

RunLoop.current.run()

HelperLog.write("listener stopped")
