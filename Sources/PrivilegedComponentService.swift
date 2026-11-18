// Protected settings: explicit macOS administrator authorization, never a root RPC.
// No installation, password storage, arbitrary commands, NVRAM, Touch ID or SMC access.
import Foundation

@MainActor
final class PrivilegedComponentService {
    static let shared = PrivilegedComponentService()

    struct Capability {
        let supported: Bool
        let ready: Bool
        let reason: String
    }
    enum ServiceError: LocalizedError {
        case unsupported(String), invalid(String), conflict(String), execution(String)
        var errorDescription: String? {
            switch self {
            case .unsupported(let s), .invalid(let s), .conflict(let s), .execution(let s): return s
            }
        }
    }
    enum PowerSource: String, Codable, CaseIterable {
        case battery = "-b", ac = "-c"
    }
    enum Setting: String, Codable {
        case lowpowermode, powernap, proximitywake, womp, autorestart
    }
    struct Change: Codable, Equatable {
        let source: PowerSource
        let setting: Setting
        let previous: Int
        let requested: Int
    }
    struct Lease: Codable {
        let componentID: String
        let changes: [Change]
        let wake: WakeRequest?
        let createdAt: Date

        private enum CodingKeys: String, CodingKey {
            case componentID, changes, wake, createdAt
            /// Recovery data written before the vocabulary change.
            case legacyComponentID = "moduleID"
        }

        init(componentID: String, changes: [Change], wake: WakeRequest?, createdAt: Date) {
            self.componentID = componentID
            self.changes = changes
            self.wake = wake
            self.createdAt = createdAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            componentID = try container.decodeIfPresent(String.self, forKey: .componentID)
                ?? container.decode(String.self, forKey: .legacyComponentID)
            changes = try container.decode([Change].self, forKey: .changes)
            wake = try container.decodeIfPresent(WakeRequest.self, forKey: .wake)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(componentID, forKey: .componentID)
            try container.encode(changes, forKey: .changes)
            try container.encodeIfPresent(wake, forKey: .wake)
            try container.encode(createdAt, forKey: .createdAt)
        }
    }
    struct WakeRequest: Codable {
        let dateText: String
        let owner: String
    }
    struct Snapshot {
        var values: [PowerSource: [Setting: Int]] = [:]
        func value(_ setting: Setting, _ source: PowerSource) -> Int? { values[source]?[setting] }
    }

    private let defaults: UserDefaults
    private let storageKey = "protectedComponentLeases.v1"
    private(set) var operationInProgress = false
    private(set) var lastError: String?
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Never silently discard an undecodable recovery record in the UI.
    var recoveryWarning: String? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return (try? JSONDecoder().decode([String: Lease].self, from: data)) == nil
            ? "Saved protected-setting recovery data is unreadable. Automatic changes are blocked; preserve the data and inspect settings manually."
            : nil
    }
    var pendingRestorations: [Lease] { Array(loadLeases().values).sorted { $0.componentID < $1.componentID } }
    func hasActiveLease(_ componentID: String) -> Bool { loadLeases()[componentID] != nil }

    /// A capability does not mean the change has been applied. The user must
    /// explicitly authorize apply(), which may be canceled or fail.
    func capability(for componentID: String, resetDate: Date? = nil) -> Capability {
        if let warning = recoveryWarning { return Capability(supported: true, ready: false, reason: warning) }
        switch componentID {
        case "passwordAfterClose":
            return Capability(supported: true, ready: true, reason: "The shared Wakely Helper turns Touch ID for unlock off only after the Lock Screen request succeeds, and restores it at the next unlock or teardown.")
        case "fanBoost":
            return Capability(supported: true, ready: true, reason: "The shared Wakely Helper validates SMC fan keys and applies the target only on supported models; exact RPM is read back and reported.")
        case "stayOffWhenOpened":
            return Capability(supported: true, ready: true, reason: "The shared Wakely Helper writes and restores `BootPreference`; a firmware that ignores it is not detectable.")
        case "sleepUntilReset":
            guard let date = resetDate, date > Date(), date.timeIntervalSinceNow <= 30 * 86400 else {
                return Capability(supported: true, ready: false, reason: "Needs a real account reset timestamp within 30 days. No guessed reset or repeating wake is created.")
            }
            return Capability(supported: true, ready: true, reason: "Can request an owned wake one minute after the supplied reset via an explicit administrator prompt. Agent activity and subsequent sleep remain the caller's responsibility; hardware may defer wake.")
        case "lowPowerWhileClosed":
            return Capability(supported: true, ready: true, reason: "Battery Low Power Mode can be changed with explicit administrator authorization if reported by pmset. Restoration needs authorization too; no invisible automatic helper is installed.")
        case "sleepMeansSleep":
            return Capability(supported: true, ready: true, reason: "Partial support only: explicitly authorized battery powernap/proximitywake/womp suppression where available. Does not suppress arbitrary scheduled wakes or guarantee sleep; restore requires authorization.")
        case "homeServer":
            return Capability(supported: true, ready: true, reason: "Partial support only: explicitly authorized AC autorestart if this Mac reports it. Does not configure app login launch, firmware auto-boot, or guaranteed recovery from battery loss.")
        default:
            return Capability(supported: false, ready: false, reason: "No protected operation is defined for this component.")
        }
    }

    /// Refines readiness with live, read-only setting discovery. Absent settings
    /// remain absent: no assumption that every Apple Silicon model supports them.
    func inspectCapability(for componentID: String, resetDate: Date? = nil) async -> Capability {
        let base = capability(for: componentID, resetDate: resetDate)
        guard base.ready, componentID != "sleepUntilReset" else { return base }
        do {
            let snapshot = try await Self.snapshot()
            _ = try Self.makeLease(componentID: componentID, snapshot: snapshot, resetDate: resetDate)
            return base
        } catch {
            return Capability(supported: true, ready: false, reason: error.localizedDescription)
        }
    }

    /// Call ONLY following an explicit user action authorizing this setting change.
    /// Do not call from periodic component ticks. A background tick must never spawn
    /// repeated administrator prompts.
    @discardableResult
    func apply(componentID: String, resetDate: Date? = nil) async throws -> Lease {
        guard !operationInProgress else { throw ServiceError.conflict("Another protected operation is running.") }
        let c = capability(for: componentID, resetDate: resetDate)
        guard c.ready else { throw ServiceError.unsupported(c.reason) }
        guard !hasActiveLease(componentID) else { throw ServiceError.conflict("This component already has a saved change. Restore it before applying another one.") }
        operationInProgress = true
        defer { operationInProgress = false; onChange?() }
        do {
            let snapshot = try await Self.snapshot()
            let lease = try Self.makeLease(componentID: componentID, snapshot: snapshot, resetDate: resetDate)
            let changedKeys = Set(lease.changes.map { "\($0.source.rawValue):\($0.setting.rawValue)" })
            guard !pendingRestorations.contains(where: { existing in
                existing.changes.contains { changedKeys.contains("\($0.source.rawValue):\($0.setting.rawValue)") }
            }) else { throw ServiceError.conflict("Another component owns one of these settings. Restore it first.") }
            // Save BEFORE mutation, including cancellation/failure/crash. A pending
            // lease is a recovery obligation, not proof of successful application.
            var leases = loadLeases()
            leases[componentID] = lease
            try saveLeases(leases)
            let script = try Self.script(for: lease, restoring: false)
            if !script.isEmpty { try await Self.authorize(script) }
            try await verifyApplied(lease)
            lastError = nil
            return lease
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Must also be explicitly user initiated: restoration can require a fresh
    /// macOS administrator prompt. Never claim cleanup succeeded on canceled auth.
    func restore(componentID: String) async throws {
        if let warning = recoveryWarning { throw ServiceError.invalid(warning) }
        guard !operationInProgress else { throw ServiceError.conflict("Another protected operation is running.") }
        guard let lease = loadLeases()[componentID] else { return }
        operationInProgress = true
        defer { operationInProgress = false; onChange?() }
        do {
            let current = try await Self.snapshot()
            for change in lease.changes {
                guard let value = current.value(change.setting, change.source),
                      value == change.requested || value == change.previous else {
                    throw ServiceError.conflict("\(change.setting.rawValue) changed outside Wakely. Refusing to overwrite it; saved prior value is \(change.previous).")
                }
            }
            var restoringLease = lease
            if let wake = lease.wake {
                let scheduled = try await Self.run("/usr/bin/pmset", ["-g", "sched"])
                if !scheduled.contains(wake.owner) {
                    // A fired or canceled owned event needs no cancellation. Do
                    // not turn an already-finished event into a restore failure.
                    restoringLease = Lease(componentID: lease.componentID, changes: lease.changes, wake: nil, createdAt: lease.createdAt)
                }
            }
            let script = try Self.script(for: restoringLease, restoring: true)
            if !script.isEmpty { try await Self.authorize(script) }
            let after = try await Self.snapshot()
            for change in lease.changes where after.value(change.setting, change.source) != change.previous {
                throw ServiceError.execution("Could not verify restoration of \(change.setting.rawValue). Recovery record retained.")
            }
            if let wake = lease.wake {
                let text = try await Self.run("/usr/bin/pmset", ["-g", "sched"])
                guard !text.contains(wake.owner) else { throw ServiceError.execution("Owned wake cancellation was not verified. Recovery record retained.") }
            }
            var leases = loadLeases()
            leases.removeValue(forKey: componentID)
            try saveLeases(leases)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func verifyApplied(_ lease: Lease) async throws {
        let after = try await Self.snapshot()
        for change in lease.changes where after.value(change.setting, change.source) != change.requested {
            throw ServiceError.execution("pmset did not retain \(change.setting.rawValue). Recovery record retained; the component must stay inactive.")
        }
        if let wake = lease.wake {
            let text = try await Self.run("/usr/bin/pmset", ["-g", "sched"])
            guard text.contains(wake.owner) else { throw ServiceError.execution("Wake request was not found after scheduling. Do not report the component active.") }
        }
    }

    private func loadLeases() -> [String: Lease] {
        guard let data = defaults.data(forKey: storageKey),
              let leases = try? JSONDecoder().decode([String: Lease].self, from: data) else { return [:] }
        return leases
    }
    private func saveLeases(_ leases: [String: Lease]) throws {
        defaults.set(try JSONEncoder().encode(leases), forKey: storageKey)
    }

    static func parseSnapshot(_ text: String) -> Snapshot {
        var result = Snapshot()
        var source: PowerSource?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "Battery Power:" { source = .battery; continue }
            if line == "AC Power:" { source = .ac; continue }
            if line.hasSuffix(":") { source = nil; continue }
            let columns = line.split(whereSeparator: { $0.isWhitespace })
            guard let source, columns.count == 2,
                  let setting = Setting(rawValue: String(columns[0])),
                  let value = Int(columns[1]), (0...2).contains(value) else { continue }
            result.values[source, default: [:]][setting] = value
        }
        return result
    }

    static func makeLease(componentID: String, snapshot: Snapshot, resetDate: Date?, now: Date = Date()) throws -> Lease {
        var changes: [Change] = []
        func add(_ setting: Setting, _ source: PowerSource, _ requested: Int, required: Bool) throws {
            guard let previous = snapshot.value(setting, source) else {
                if required { throw ServiceError.unsupported("This Mac does not report \(setting.rawValue) for \(source == .battery ? "battery" : "AC") power.") }
                return
            }
            guard (0...2).contains(previous), (0...1).contains(requested) else { throw ServiceError.invalid("Invalid pmset value.") }
            if previous != requested { changes.append(Change(source: source, setting: setting, previous: previous, requested: requested)) }
        }
        var wake: WakeRequest?
        switch componentID {
        case "lowPowerWhileClosed":
            try add(.lowpowermode, .battery, 1, required: true)
        case "sleepMeansSleep":
            // Suppress supported wake sources on battery only. This is not a
            // guarantee against lid/user/system wakes or third-party schedules.
            try add(.powernap, .battery, 0, required: false)
            try add(.proximitywake, .battery, 0, required: false)
            try add(.womp, .battery, 0, required: false)
            let found = [Setting.powernap, .proximitywake, .womp].contains { snapshot.value($0, .battery) != nil }
            guard found else { throw ServiceError.unsupported("No supported battery wake-source settings are reported by this Mac.") }
        case "homeServer":
            try add(.autorestart, .ac, 1, required: true)
        case "sleepUntilReset":
            guard let resetDate, resetDate > now, resetDate.timeIntervalSince(now) <= 30 * 86400 else {
                throw ServiceError.invalid("Supply a real future account reset within 30 days.")
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "MM/dd/yy HH:mm:ss"
            wake = WakeRequest(dateText: formatter.string(from: resetDate.addingTimeInterval(60)), owner: "dev.wakely.reset.\(UUID().uuidString)")
        default:
            throw ServiceError.unsupported("No protected operation is implemented for \(componentID).")
        }
        return Lease(componentID: componentID, changes: changes, wake: wake, createdAt: now)
    }

    /// Pure script generation; every setting/source is a closed enum and every
    /// numeric value is validated again, even for recovery records from disk.
    static func script(for lease: Lease, restoring: Bool) throws -> String {
        var lines = ["set -eu"]
        // Recheck AFTER the authorization dialog, not just before it. Another
        // power utility or the user may have changed a setting while it was open.
        for change in lease.changes {
            guard (0...2).contains(change.previous), (0...1).contains(change.requested) else {
                throw ServiceError.invalid("Invalid persisted power setting value; refusing administrator execution.")
            }
            let header = change.source == .battery ? "Battery Power:" : "AC Power:"
            let lookup = "$0 ~ /Power:/ { active = ($0 ~ /\(header)/); next } active && $1 == \"\(change.setting.rawValue)\" { print $2; exit }"
            lines.append("current=$(/usr/bin/pmset -g custom | /usr/bin/awk '\(lookup)')")
            if restoring {
                lines.append("[ \"$current\" = '\(change.requested)' ] || [ \"$current\" = '\(change.previous)' ] || { echo 'Power setting changed outside Wakely; restore refused.' >&2; exit 73; }")
            } else {
                lines.append("[ \"$current\" = '\(change.previous)' ] || { echo 'Power setting changed while authorization was open; apply refused.' >&2; exit 73; }")
            }
        }
        for change in lease.changes {
            let value = restoring ? change.previous : change.requested
            lines.append("/usr/bin/pmset \(change.source.rawValue) \(change.setting.rawValue) \(value)")
        }
        if let wake = lease.wake {
            guard validWake(wake) else { throw ServiceError.invalid("Invalid persisted wake event; refusing administrator execution.") }
            let operation = restoring ? "schedule cancel wake" : "schedule wake"
            lines.append("/usr/bin/pmset \(operation) '\(wake.dateText)' '\(wake.owner)'")
        }
        return lines.count == 1 ? "" : lines.joined(separator: "\n")
    }
    static func validWake(_ wake: WakeRequest) -> Bool {
        let owner = wake.owner
        guard owner.hasPrefix("dev.wakely.reset."),
              UUID(uuidString: String(owner.dropFirst("dev.wakely.reset.".count))) != nil else { return false }
        return wake.dateText.range(of: #"^\d{2}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func snapshot() async throws -> Snapshot {
        parseSnapshot(try await run("/usr/bin/pmset", ["-g", "custom"]))
    }
    private static func authorize(_ script: String) async throws {
        // There is no endpoint accepting caller commands. Only this type's pure,
        // allowlisted script generator can reach the authorization executor.
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
        _ = try await run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
    }
    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw ServiceError.execution("Protected operation failed or was canceled (\(process.terminationStatus)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return text
        }.value
    }
}
