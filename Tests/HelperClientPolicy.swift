// HelperClientPolicyTests — pure policy tests for Sources/HelperClient.swift.
//
// This file is self-contained so `swiftc Tests/HelperClientPolicy.swift` works
// on its own. The generated section below must stay byte-identical to the
// `// BEGIN TESTABLE HELPER POLICY` block in Sources/HelperClient.swift;
// Tests/test_helper_client_policy.py re-extracts that block, compares it, then
// compiles and runs this file. No AppKit, ServiceManagement, registration,
// install prompt, file write, or XPC call is reachable from here.

import Foundation

// BEGIN GENERATED HELPER POLICY
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
// END GENERATED HELPER POLICY

        var helperPolicyChecks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            helperPolicyChecks += 1
        }

        // MARK: Registration status -> install state

        check(HelperRegistrationStatus(rawCode: 0) == .notRegistered, "0 maps to notRegistered")
        check(HelperRegistrationStatus(rawCode: 1) == .enabled, "1 maps to enabled")
        check(HelperRegistrationStatus(rawCode: 2) == .requiresApproval, "2 maps to requiresApproval")
        check(HelperRegistrationStatus(rawCode: 3) == .notFound, "3 maps to notFound")
        check(HelperRegistrationStatus(rawCode: 99) == .unknown, "unrecognized code maps to unknown")
        check(HelperRegistrationStatus(rawCode: -1) == .unknown, "negative code maps to unknown")

        check(HelperInstallPolicy.state(for: .notRegistered) == .notInstalled, "notRegistered is notInstalled")
        check(HelperInstallPolicy.state(for: .notFound) == .notInstalled, "notFound is notInstalled")
        check(HelperInstallPolicy.state(for: .enabled) == .installed, "enabled is installed")
        check(HelperInstallPolicy.state(for: .requiresApproval) == .requiresApproval, "requiresApproval preserved")
        if case .failed(let unknownMessage) = HelperInstallPolicy.state(for: .unknown) {
            check(unknownMessage == HelperInstallPolicy.unknownStatusMessage, "unknown status fails closed with a message")
        } else {
            check(false, "unknown status must fail closed")
        }

        // MARK: User-facing text and capability reasons

        check(HelperInstallPolicy.message(for: .notInstalled) == "The privileged helper is not installed.", "not-installed text")
        check(HelperInstallPolicy.message(for: .installed) == "The privileged helper is installed.", "installed text")
        check(HelperInstallPolicy.message(for: .failed("boom")) == "boom", "failure text is preserved verbatim")
        check(HelperInstallPolicy.message(for: .requiresApproval).contains("System Settings"), "approval text points at System Settings")
        check(HelperInstallPolicy.approvalSettingsURL == "x-apple.systempreferences:com.apple.LoginItems-Settings.extension", "approval opens the Login Items pane")
        check(HelperInstallPolicy.capabilityReason(for: .notInstalled) == "the privileged helper is not installed", "capability reason for a missing helper")
        check(HelperInstallPolicy.capabilityReason(for: .requiresApproval) == HelperInstallPolicy.approvalReason, "capability reason for approval")
        check(HelperInstallPolicy.capabilityReason(for: .installed) == nil, "installed has no short-circuit reason")
        check(HelperInstallPolicy.capabilityReason(for: .failed("x")) == nil, "failed still allows a status attempt")

        // MARK: Signature / registration failure detection

        check(HelperInstallPolicy.isSignatureOrRegistrationFailure(domain: "SMAppServiceErrorDomain", code: 1, description: "Operation not permitted"), "SMAppService errors need the fallback")
        check(HelperInstallPolicy.isSignatureOrRegistrationFailure(domain: "NSCocoaErrorDomain", code: 4, description: "Failed to register because the code signature is invalid"), "signature text is recognized")
        check(!HelperInstallPolicy.isSignatureOrRegistrationFailure(domain: "SMAppServiceErrorDomain", code: -128, description: "The operation was canceled by the user."), "user cancellation is not a signature failure")
        check(!HelperInstallPolicy.isSignatureOrRegistrationFailure(domain: "SMAppServiceErrorDomain", code: -60006, description: "Authorization was canceled."), "authorization cancellation is not a signature failure")
        check(!HelperInstallPolicy.isSignatureOrRegistrationFailure(domain: "NSCocoaErrorDomain", code: 4, description: "The file does not exist."), "unrelated errors do not escalate")

        // MARK: Disabled administrator install (M3)

        check(HelperInstallPolicy.requiresAdministratorFallback(after: .failed("x"), signatureFailure: true), "failed + signature error offers the administrator install")
        check(HelperInstallPolicy.requiresAdministratorFallback(after: .notInstalled, signatureFailure: true), "not installed + signature error offers the administrator install")
        check(!HelperInstallPolicy.requiresAdministratorFallback(after: .requiresApproval, signatureFailure: true), "approval is not a fallback reason")
        check(!HelperInstallPolicy.requiresAdministratorFallback(after: .installed, signatureFailure: true), "installed never offers fallback")
        check(!HelperInstallPolicy.requiresAdministratorFallback(after: .failed("x"), signatureFailure: false), "non-signature failure does not offer fallback")
        check(HelperInstallPolicy.signatureFallbackMessage.contains("Install with Administrator"), "signature text points at the administrator install")
        check(HelperInstallPolicy.signatureFallbackMessage.contains("Developer ID"), "signature text names the signing alternative")

        // MARK: Request validation

        check(HelperRequestPolicy.isValid(operation: "ping", componentID: "", boolValue: nil, intValue: nil), "ping is valid")
        check(HelperRequestPolicy.isValid(operation: "status", componentID: "", boolValue: nil, intValue: nil), "status is valid")
        check(HelperRequestPolicy.isValid(operation: "restoreAll", componentID: "", boolValue: nil, intValue: nil), "restoreAll is valid")
        check(HelperRequestPolicy.isValid(operation: "requestStatus", componentID: "", boolValue: nil, intValue: nil), "requestStatus is valid")
        check(!HelperRequestPolicy.isValid(operation: "requestStatus", componentID: "fanBoost", boolValue: nil, intValue: nil), "requestStatus rejects a component id")
        check(!HelperRequestPolicy.isValid(operation: "requestStatus", componentID: "", boolValue: false, intValue: nil), "requestStatus rejects a boolean")
        check(!HelperRequestPolicy.isValid(operation: "requestStatus", componentID: "", boolValue: nil, intValue: 1), "requestStatus rejects an integer")
        check(HelperRequestPolicy.isValid(operation: "restoreSession", componentID: "", boolValue: nil, intValue: nil), "restoreSession is valid")
        check(!HelperRequestPolicy.isValid(operation: "restoreSession", componentID: "fanBoost", boolValue: nil, intValue: nil), "restoreSession rejects a component id")
        check(!HelperRequestPolicy.isValid(operation: "restoreSession", componentID: "", boolValue: true, intValue: nil), "restoreSession rejects a boolean")
        check(HelperRequestPolicy.isValid(operation: "lowPowerMode", componentID: "", boolValue: true, intValue: nil), "lowPowerMode true valid")
        check(HelperRequestPolicy.isValid(operation: "touchIDUnlock", componentID: "", boolValue: false, intValue: nil), "touchIDUnlock false valid")
        check(HelperRequestPolicy.isValid(operation: "bootOnLidOpen", componentID: "", boolValue: true, intValue: nil), "bootOnLidOpen valid")
        check(HelperRequestPolicy.isValid(operation: "autoRestartAfterPowerLoss", componentID: "", boolValue: false, intValue: nil), "autoRestart valid")
        check(HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: 0), "fan 0 restores automatic")
        check(HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: 100), "fan 100 valid")
        for percent in 1...29 {
            check(!HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: percent), "below-original-range fan request rejected")
        }
        check(HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: 30), "fan 30 valid")
        check(!HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: -1), "fan below 0 rejected")
        check(!HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: 101), "fan above 100 rejected")
        check(!HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: nil), "fan requires a value")
        check(!HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: true, intValue: 50), "fan rejects a boolean")
        check(!HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "fanBoost", boolValue: nil, intValue: 50), "fan rejects a component id")
        check(!HelperRequestPolicy.isValid(operation: "lowPowerMode", componentID: "", boolValue: nil, intValue: nil), "bool operation requires a boolean")
        check(!HelperRequestPolicy.isValid(operation: "lowPowerMode", componentID: "", boolValue: nil, intValue: 1), "bool operation rejects an integer")
        check(!HelperRequestPolicy.isValid(operation: "lowPowerMode", componentID: "", boolValue: true, intValue: 1), "bool operation rejects mixed values")
        check(!HelperRequestPolicy.isValid(operation: "lowPowerMode", componentID: "lowPowerWhileClosed", boolValue: true, intValue: nil), "global operation rejects a component id")
        check(HelperRequestPolicy.isValid(operation: "suppressWakeSources", componentID: "sleepMeansSleep", boolValue: true, intValue: nil), "wake-source suppression is owned by Sleep Means Sleep")
        check(!HelperRequestPolicy.isValid(operation: "suppressWakeSources", componentID: "", boolValue: true, intValue: nil), "wake-source suppression requires its owner")
        check(!HelperRequestPolicy.isValid(operation: "suppressWakeSources", componentID: "sleepMeansSleep", boolValue: false, intValue: nil), "wake-source suppression only applies true")
        check(!HelperRequestPolicy.isValid(operation: "suppressWakeSources", componentID: "sleepMeansSleep", boolValue: nil, intValue: nil), "wake-source suppression requires a boolean")
        check(!HelperRequestPolicy.isValid(operation: "suppressWakeSources", componentID: "fanBoost", boolValue: true, intValue: nil), "another component cannot own wake-source suppression")
        check(HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "fanBoost", boolValue: nil, intValue: nil), "restore with a component id valid")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "", boolValue: nil, intValue: nil), "restore requires a component id")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "   ", boolValue: nil, intValue: nil), "whitespace component id rejected")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "\n", boolValue: nil, intValue: nil), "control component id rejected")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "fan\nBoost", boolValue: nil, intValue: nil), "embedded newline component id rejected")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: String(repeating: "a", count: 129), boolValue: nil, intValue: nil), "oversized component id rejected")
        check(HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: String(repeating: "a", count: 128), boolValue: nil, intValue: nil), "128-character component id allowed")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "fanBoost", boolValue: true, intValue: nil), "restore rejects a boolean")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "fanBoost", boolValue: nil, intValue: 1), "restore rejects an integer")
        check(!HelperRequestPolicy.isValid(operation: "shell", componentID: "", boolValue: nil, intValue: nil), "unknown operation rejected")
        check(!HelperRequestPolicy.isValid(operation: "ping", componentID: "", boolValue: false, intValue: nil), "ping rejects a boolean")
        check(!HelperRequestPolicy.isValid(operation: "status", componentID: "x", boolValue: nil, intValue: nil), "status rejects a component id")
        check(!HelperRequestPolicy.isValid(operation: "restoreAll", componentID: "fanBoost", boolValue: nil, intValue: nil), "restoreAll rejects a component id")
        if let reason = HelperRequestPolicy.invalidReason(operation: "fanPercent", componentID: "", boolValue: nil, intValue: 101) {
            check(!reason.isEmpty, "invalid reason is presentable")
        } else {
            check(false, "invalid fan percent must produce a reason")
        }
        check(HelperRequestPolicy.fanPercentRange == 30...100, "forced fan range matches original 30...100")
        check(HelperRequestPolicy.timeout(for: "ping") == 2, "ping timeout is 2 s")
        check(HelperRequestPolicy.timeout(for: "fanPercent") == 5, "other operations use 5 s")
        check(HelperRequestPolicy.timeout(for: "unknown") == 5, "unknown operations still time out")

        // MARK: Owned wake requests (protocol 3)

        let wakeTime: Double = 1_781_000_000
        check(HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "", boolValue: nil, intValue: nil, dateValue: wakeTime), "scheduleWake takes a finite date")
        check(HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "sleepUntilReset", boolValue: nil, intValue: nil, dateValue: wakeTime), "scheduleWake accepts a valid owner")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "sleepUntilReset", boolValue: nil, intValue: nil, dateValue: nil), "scheduleWake requires a date")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "", boolValue: nil, intValue: nil, dateValue: .nan), "scheduleWake rejects a NaN date")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "", boolValue: nil, intValue: nil, dateValue: .infinity), "scheduleWake rejects an infinite date")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "", boolValue: nil, intValue: nil, dateValue: -1), "scheduleWake rejects a negative date")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "", boolValue: nil, intValue: nil, dateValue: HelperRequestPolicy.maximumWakeEpoch), "scheduleWake rejects an out-of-calendar date")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "", boolValue: true, intValue: nil, dateValue: wakeTime), "scheduleWake rejects a boolean")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "", boolValue: nil, intValue: 1, dateValue: wakeTime), "scheduleWake rejects an integer")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: " sleepUntilReset", boolValue: nil, intValue: nil, dateValue: wakeTime), "scheduleWake rejects a padded owner")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: String(repeating: "a", count: 129), boolValue: nil, intValue: nil, dateValue: wakeTime), "scheduleWake rejects an oversized owner")
        check(!HelperRequestPolicy.isValid(operation: "scheduleWake", componentID: "sleep\nUntilReset", boolValue: nil, intValue: nil, dateValue: wakeTime), "scheduleWake rejects control characters in the owner")

        check(HelperRequestPolicy.isValid(operation: "cancelWake", componentID: "", boolValue: nil, intValue: nil, dateValue: wakeTime), "cancelWake takes a finite date")
        check(HelperRequestPolicy.isValid(operation: "cancelWake", componentID: "sleepUntilReset", boolValue: nil, intValue: nil, dateValue: wakeTime), "cancelWake accepts a valid owner")
        check(!HelperRequestPolicy.isValid(operation: "cancelWake", componentID: "", boolValue: nil, intValue: nil, dateValue: nil), "cancelWake requires a date")
        check(!HelperRequestPolicy.isValid(operation: "cancelWake", componentID: "", boolValue: nil, intValue: nil, dateValue: .nan), "cancelWake rejects a NaN date")
        check(!HelperRequestPolicy.isValid(operation: "cancelWake", componentID: "", boolValue: false, intValue: nil, dateValue: wakeTime), "cancelWake rejects a boolean")
        check(!HelperRequestPolicy.isValid(operation: "cancelWake", componentID: "", boolValue: nil, intValue: 2, dateValue: wakeTime), "cancelWake rejects an integer")

        check(HelperRequestPolicy.isValid(operation: "wakeSchedules", componentID: "", boolValue: nil, intValue: nil), "wakeSchedules is valid bare")
        check(!HelperRequestPolicy.isValid(operation: "wakeSchedules", componentID: "", boolValue: nil, intValue: nil, dateValue: wakeTime), "wakeSchedules rejects a date")
        check(!HelperRequestPolicy.isValid(operation: "wakeSchedules", componentID: "", boolValue: true, intValue: nil), "wakeSchedules rejects a boolean")
        check(!HelperRequestPolicy.isValid(operation: "wakeSchedules", componentID: "", boolValue: nil, intValue: 3), "wakeSchedules rejects an integer")
        check(!HelperRequestPolicy.isValid(operation: "wakeSchedules", componentID: "sleepUntilReset", boolValue: nil, intValue: nil), "wakeSchedules rejects a component id")
        check(!HelperRequestPolicy.isValid(operation: "ping", componentID: "", boolValue: nil, intValue: nil, dateValue: wakeTime), "ping rejects a stray date")
        check(!HelperRequestPolicy.isValid(operation: "restoreComponent", componentID: "fanBoost", boolValue: nil, intValue: nil, dateValue: wakeTime), "restoreComponent rejects a stray date")
        check(!HelperRequestPolicy.isValid(operation: "fanPercent", componentID: "", boolValue: nil, intValue: 50, dateValue: wakeTime), "fanPercent rejects a stray date")

        // MARK: Owned wake reply parser

        let wakeA = UUID()
        let wakeB = UUID()
        let wakeDetails: [String: String] = [
            "count": "2",
            "wake.\(wakeB.uuidString).epoch": "1781000600",
            "wake.\(wakeB.uuidString).kind": "wake",
            "wake.\(wakeB.uuidString).createdBy": "sleepUntilReset",
            "wake.\(wakeB.uuidString).present": "yes",
            "wake.\(wakeA.uuidString).epoch": " 1781000000 ",
            "wake.\(wakeA.uuidString).kind": "wake",
            "wake.\(wakeA.uuidString).createdBy": "sleepUntilReset",
            "wake.\(wakeA.uuidString).present": "unknown",
            "wake.\(wakeA.uuidString).note": "ignored",
            "unrelated": "ignored",
        ]
        let parsedWakes = HelperWakeSchedulePolicy.parse(details: wakeDetails)
        check(parsedWakes.count == 2, "only wake entries are parsed")
        check(parsedWakes.first?.id == wakeA, "wakes are sorted by instant")
        check(parsedWakes.first?.at == Date(timeIntervalSince1970: 1_781_000_000), "epoch becomes an instant")
        check(parsedWakes.first?.createdBy == "sleepUntilReset", "the owner label is preserved")
        check(parsedWakes.first?.present == nil, "unknown presence stays unknown")
        check(parsedWakes.last?.present == true, "present yes is true")

        check(HelperWakeSchedulePolicy.parse(details: ["count": "0"]).isEmpty, "a count without entries is empty")
        check(HelperWakeSchedulePolicy.parse(details: ["wake.not-a-uuid.epoch": "1781000000"]).isEmpty, "an unreadable identity is dropped")
        check(HelperWakeSchedulePolicy.parse(details: ["wake.\(wakeA.uuidString).kind": "wake"]).isEmpty, "an entry without an instant is dropped")
        check(HelperWakeSchedulePolicy.parse(details: [
            "wake.\(wakeA.uuidString).epoch": "nope",
            "wake.\(wakeA.uuidString).kind": "wake",
        ]).isEmpty, "an unreadable instant is dropped")
        check(HelperWakeSchedulePolicy.parse(details: [
            "wake.\(wakeA.uuidString).epoch": "1781000000",
            "wake.\(wakeA.uuidString).kind": "sleep",
        ]).isEmpty, "a non-wake kind is dropped")
        let conflicting: [String: String] = [
            "wake.\(wakeA.uuidString.lowercased()).epoch": "1781000000",
            "wake.\(wakeA.uuidString.uppercased()).epoch": "1781000005",
        ]
        check(HelperWakeSchedulePolicy.parse(details: conflicting).isEmpty, "conflicting instants for one identity are dropped")

        // MARK: Status -> capability

        let refused = HelperStatusPolicy.capability(operation: "fanPercent", replyOK: false, message: "status failed", details: [:])
        check(!refused.supported && refused.reason == "status failed", "failed status is unsupported with the helper message")
        let refusedBlank = HelperStatusPolicy.capability(operation: "fanPercent", replyOK: false, message: "  ", details: [:])
        check(!refusedBlank.supported && refusedBlank.reason == "the privileged helper could not report its capabilities", "failed status has a default reason")
        let unsupported = HelperStatusPolicy.capability(
            operation: "fanPercent",
            replyOK: true,
            message: "status ok",
            details: ["fanPercent": "unsupported", "fanPercent.reason": "no SMC backend"]
        )
        check(!unsupported.supported && unsupported.reason == "no SMC backend", "explicit unsupported wins with its reason")
        let zero = HelperStatusPolicy.capability(operation: "lowPowerMode", replyOK: true, message: "status ok", details: ["lowPowerMode": "0"])
        check(!zero.supported && zero.reason == "status ok", "boolean-ish zero is unsupported")
        let supported = HelperStatusPolicy.capability(operation: "fanPercent", replyOK: true, message: "status ok", details: ["fanPercent": "supported"])
        check(supported.supported && supported.reason == "status ok", "explicit support uses the helper message")
        let truthy = HelperStatusPolicy.capability(
            operation: "fanPercent",
            replyOK: true,
            message: "",
            details: ["fanPercent": "1", "fanPercent.reason": "SMC fan control available"]
        )
        check(truthy.supported && truthy.reason == "SMC fan control available", "boolean-ish one is supported with its reason")
        let unlisted = HelperStatusPolicy.capability(operation: "fanPercent", replyOK: true, message: "status ok", details: [:])
        check(!unlisted.supported, "unlisted capability fails closed")
        let unlistedBlank = HelperStatusPolicy.capability(operation: "fanPercent", replyOK: true, message: "", details: [:])
        check(!unlistedBlank.supported, "a blank unlisted operation fails closed")

        // MARK: Protocol negotiation

        check(HelperStatusPolicy.minimumAuthoritativeProtocolVersion == 2, "protocol 2 is the authoritative minimum")
        check(HelperStatusPolicy.protocolVersion(details: ["protocol": "2"]) == 2, "the daemon's protocol key parses")
        check(HelperStatusPolicy.protocolVersion(details: ["protocolVersion": "2"]) == 2, "protocol version parses")
        check(HelperStatusPolicy.protocolVersion(details: ["protocolVersion": " 2 "]) == 2, "protocol version tolerates whitespace")
        check(HelperStatusPolicy.protocolVersion(details: ["protocol.version": "3"]) == 3, "protocol.version alias parses")
        check(HelperStatusPolicy.protocolVersion(details: ["protocolVersion": "1"]) == 1, "protocol 1 is readable but old")
        check(HelperStatusPolicy.protocolVersion(details: ["protocolVersion": ""]) == nil, "empty protocol version is unknown")
        check(HelperStatusPolicy.protocolVersion(details: ["protocolVersion": "two"]) == nil, "garbled protocol version is unknown")
        check(HelperStatusPolicy.protocolVersion(details: ["protocolVersion": "-1"]) == nil, "negative protocol version is unknown")
        check(HelperStatusPolicy.protocolVersion(details: [:]) == nil, "missing protocol version is unknown")

        check(HelperStatusPolicy.supportsAuthoritativeRequests(replyOK: true, details: ["protocol": "2"]), "the daemon's protocol 2 supports authoritative outcomes")
        check(HelperStatusPolicy.supportsAuthoritativeRequests(replyOK: true, details: ["protocolVersion": "2"]), "protocol 2 supports authoritative outcomes")
        check(HelperStatusPolicy.supportsAuthoritativeRequests(replyOK: true, details: ["protocolVersion": "3"]), "newer protocol supports authoritative outcomes")
        check(!HelperStatusPolicy.supportsAuthoritativeRequests(replyOK: true, details: ["protocolVersion": "1"]), "protocol 1 is legacy")
        check(!HelperStatusPolicy.supportsAuthoritativeRequests(replyOK: true, details: [:]), "missing version is not authoritative")
        check(!HelperStatusPolicy.supportsAuthoritativeRequests(replyOK: true, details: ["protocolVersion": "no"]), "garbled version is not authoritative")
        check(!HelperStatusPolicy.supportsAuthoritativeRequests(replyOK: false, details: ["protocolVersion": "2"]), "failed status is not authoritative")

        check(HelperStatusPolicy.isLegacyHelper(replyOK: true, details: ["protocolVersion": "1"]), "protocol 1 helper is legacy")
        check(HelperStatusPolicy.isLegacyHelper(replyOK: true, details: [:]), "unversioned helper is legacy")
        check(!HelperStatusPolicy.isLegacyHelper(replyOK: true, details: ["protocolVersion": "2"]), "protocol 2 helper is not legacy")
        check(!HelperStatusPolicy.isLegacyHelper(replyOK: false, details: ["protocolVersion": "1"]), "no live status is unknown, not a legacy claim")

        // MARK: Authoritative request outcome parser

        let outcomeRequest = UUID()
        let outcomeKey = "request.\(outcomeRequest.uuidString)."

        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "succeeded"], requestID: outcomeRequest) == .succeeded(leaseComponent: nil), "succeeded is authoritative")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "succeeded", outcomeKey + "leaseComponent": "fanBoost"], requestID: outcomeRequest) == .succeeded(leaseComponent: "fanBoost"), "succeeded carries its lease component")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "outcome": "succeeded", outcomeKey + "lease": "fanBoost"], requestID: outcomeRequest) == .succeeded(leaseComponent: "fanBoost"), "outcome and lease aliases are accepted")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "failedBeforeMutation"], requestID: outcomeRequest) == .failedBeforeMutation, "refusal before mutation")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "failedWithRecoveryLease"], requestID: outcomeRequest) == .failedWithRecoveryLease(leaseComponent: nil), "recovery lease without a component is still failed")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "failedWithRecoveryLease", outcomeKey + "leaseComponent": "fanBoost"], requestID: outcomeRequest) == .failedWithRecoveryLease(leaseComponent: "fanBoost"), "recovery lease carries its component")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "interruptedUnknown"], requestID: outcomeRequest) == .interruptedUnknown, "interrupted is unknown")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "accepted"], requestID: outcomeRequest) == .accepted, "accepted is pending")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "running"], requestID: outcomeRequest) == .running, "running is pending")

        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "unknown"], requestID: outcomeRequest) == .unknown, "an explicit unknown state is unknown")
        check(HelperRequestOutcome.parse(details: [
            "protocol": "2",
            outcomeKey + "state": "succeeded",
            outcomeKey + "lease": "",
            outcomeKey + "message": "",
        ], requestID: outcomeRequest) == .succeeded(leaseComponent: nil), "the daemon's empty lease field is not a component")
        check(HelperRequestOutcome.parse(details: [:], requestID: outcomeRequest) == .unknown, "missing keys are unknown")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "message": "applied"], requestID: outcomeRequest) == .unknown, "unrelated keys are unknown")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": ""], requestID: outcomeRequest) == .unknown, "empty state is unknown")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "Succeeded!"], requestID: outcomeRequest) == .unknown, "garbled state is unknown")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "failedBeforeMutation", outcomeKey + "outcome": "succeeded"], requestID: outcomeRequest) == .unknown, "conflicting state and outcome are unknown")
        check(HelperRequestOutcome.parse(details: [outcomeKey + "state": "succeeded", outcomeKey + "leaseComponent": "a", outcomeKey + "lease": "b"], requestID: outcomeRequest) == .unknown, "conflicting leases are unknown")
        check(HelperRequestOutcome.parse(details: ["transportUncertain": "yes", outcomeKey + "state": "succeeded"], requestID: outcomeRequest) == .unknown, "transport uncertainty beats a journal claim")
        check(HelperRequestOutcome.parse(details: ["transportUncertain": "no", outcomeKey + "state": "succeeded"], requestID: outcomeRequest) == .succeeded(leaseComponent: nil), "a daemon reply may explicitly deny transport uncertainty")
        check(HelperRequestOutcome.parse(details: ["protocolVersion": "1", "leases": "fanBoost"], requestID: outcomeRequest) == .unknown, "a legacy status/lease reply never proves a request outcome")

        let otherRequest = UUID()
        let otherKey = "request.\(otherRequest.uuidString)."
        check(HelperRequestOutcome.parse(details: [otherKey + "state": "succeeded", otherKey + "leaseComponent": "fanBoost"], requestID: outcomeRequest) == .unknown, "another request's success is not ours")
        check(HelperRequestOutcome.parse(details: [otherKey + "state": "succeeded", outcomeKey + "state": "failedBeforeMutation"], requestID: outcomeRequest) == .failedBeforeMutation, "our entry is read even when another request is present")
        check(HelperRequestOutcome.parse(details: [outcomeKey.lowercased() + "state": "succeeded"], requestID: outcomeRequest) == .succeeded(leaseComponent: nil), "lowercase uuid keys are accepted")

        // MARK: Administrator command builder

        let bundleSource = "/Applications/Wakely.app/Contents/Library/LaunchDaemons/dev.wakely.helper.plist"
        let plistName = "dev.wakely.helper.plist"
        let label = "dev.wakely.helper"
        guard let install = HelperInstallCommandBuilder.installPlan(
            sourcePlistPath: bundleSource,
            daemonPlistName: plistName,
            daemonLabel: label
        ) else {
            fatalError("valid bundled plist path must produce an install plan")
        }

        let expectedInstallShell = "set -eu; "
            + "/usr/bin/install -o root -g wheel -m 0644 '/Applications/Wakely.app/Contents/Library/LaunchDaemons/dev.wakely.helper.plist' '/Library/LaunchDaemons/dev.wakely.helper.plist'; "
            + "/bin/launchctl bootout 'system/dev.wakely.helper' 2>/dev/null || /usr/bin/true; "
            + "/bin/launchctl bootstrap system '/Library/LaunchDaemons/dev.wakely.helper.plist'; "
            + "/bin/launchctl print 'system/dev.wakely.helper' >/dev/null"
        check(install.shellScript == expectedInstallShell, "install script is byte-exact")
        check(install.sourcePlistPath == bundleSource, "install source path preserved")
        check(install.installedPlistPath == "/Library/LaunchDaemons/dev.wakely.helper.plist", "installed path is fixed")
        check(install.daemonLabel == label, "label preserved")
        check(install.appleScriptArgument == "do shell script \"\(expectedInstallShell)\" with administrator privileges", "install AppleScript wraps the script once")
        check(!install.appleScriptArgument.contains("\n"), "AppleScript argument is a single line")
        check(install.shellScript.contains("launchctl print"), "install verifies with launchctl print")
        check(install.shellScript.contains("-o root -g wheel -m 0644"), "install sets root:wheel 0644")
        check(install.shellScript.hasPrefix("set -eu; "), "install fails closed")

        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: "Contents/Library/LaunchDaemons/\(plistName)", daemonPlistName: plistName, daemonLabel: label) == nil, "relative path rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: "/Applications/../evil/Contents/Library/LaunchDaemons/\(plistName)", daemonPlistName: plistName, daemonLabel: label) == nil, "traversal rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: "/tmp/\(plistName)", daemonPlistName: plistName, daemonLabel: label) == nil, "path outside the bundle daemons directory rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: "/Applications/Wakely.app/Contents/Library/LaunchDaemons/other.plist", daemonPlistName: plistName, daemonLabel: label) == nil, "mismatched plist name rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: "/Applications/O'Brien.app/Contents/Library/LaunchDaemons/\(plistName)", daemonPlistName: plistName, daemonLabel: label) == nil, "single quote in path rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: bundleSource, daemonPlistName: plistName, daemonLabel: "") == nil, "empty label rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: bundleSource, daemonPlistName: plistName, daemonLabel: "dev.wakely.helper;rm -rf /") == nil, "injected label rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: bundleSource, daemonPlistName: plistName, daemonLabel: "dev/wakely") == nil, "slash in label rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: bundleSource, daemonPlistName: plistName, daemonLabel: "dev wakely") == nil, "space in label rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: bundleSource, daemonPlistName: "helper.txt", daemonLabel: label) == nil, "non-plist daemon name rejected")
        check(HelperInstallCommandBuilder.installPlan(sourcePlistPath: bundleSource, daemonPlistName: "dev/helper.plist", daemonLabel: label) == nil, "slash in plist name rejected")

        guard let uninstall = HelperInstallCommandBuilder.uninstallPlan(daemonPlistName: plistName, daemonLabel: label) else {
            fatalError("valid names must produce an uninstall plan")
        }
        let expectedUninstallShell = "set -eu; "
            + "/bin/launchctl bootout 'system/dev.wakely.helper' 2>/dev/null || /usr/bin/true; "
            + "/bin/rm -f '/Library/LaunchDaemons/dev.wakely.helper.plist' '/Library/PrivilegedHelperTools/dev.wakely.helper' '/Library/PrivilegedHelperTools/dev.wakely.helper.peer'; "
            + "[ ! -e '/Library/LaunchDaemons/dev.wakely.helper.plist' ]"
        check(uninstall.shellScript == expectedUninstallShell, "uninstall script is byte-exact")
        check(uninstall.sourcePlistPath.isEmpty, "uninstall has no source path")
        check(uninstall.installedPlistPath == "/Library/LaunchDaemons/dev.wakely.helper.plist", "uninstall targets the fixed path")
        check(uninstall.appleScriptArgument == "do shell script \"\(expectedUninstallShell)\" with administrator privileges", "uninstall AppleScript wraps the script once")
        check(HelperInstallCommandBuilder.uninstallPlan(daemonPlistName: plistName, daemonLabel: "bad/label") == nil, "uninstall validates the label")
        let dataDir = "/Library/Application Support/dev.wakely.helper"
        check(!uninstall.shellScript.contains(dataDir), "a plain helper uninstall keeps the helper's backups")
        if let full = HelperInstallCommandBuilder.uninstallPlan(daemonPlistName: plistName, daemonLabel: label, removeData: true) {
            check(full.shellScript.contains("/bin/rm -rf '\(dataDir)'"), "Delete Wakely removes the helper's root-owned data")
        } else { check(false, "full uninstall plan builds") }

        check(
            HelperInstallCommandBuilder.appleScript(shellScript: "echo \"hi\" \\ done")
                == "do shell script \"echo \\\"hi\\\" \\\\ done\" with administrator privileges",
            "AppleScript quotes and backslashes are escaped"
        )

        print("PASS: \(helperPolicyChecks) pure helper-client policy checks; no registration, install, prompt, or XPC performed")
