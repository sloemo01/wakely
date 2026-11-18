// Peer authentication for the privileged helper.
//
// Preferred identity: the code-signing certificate shared by the app, watchdog
// and helper. This works for Developer ID and self-signed builds without
// trusting a forgeable subject/CN.
//
// Ad-hoc builds have no certificate. For those, the administrator installer
// records the exact cdhash of the app and watchdog in a root-owned file. The
// listener accepts only those cdhashes. That is deliberately narrower than a
// bundle identifier: a different ad-hoc build cannot inherit the endpoint.
import CryptoKit
import Foundation
import Security

enum HelperPeerPolicy {
    static let appIdentifier = "dev.wakely.app"
    static let watchdogIdentifier = "dev.wakely.watchdog"
    static let peerConfigPath = "/Library/PrivilegedHelperTools/dev.wakely.helper.peer"

    /// Only a certificate digest obtained from the running helper is accepted.
    /// Ad-hoc signatures have no certificate and must use the cdhash config.
    static func requirement(certificateSHA1: String?) -> String? {
        guard let digest = certificateSHA1, digest.count == 40,
              digest.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else { return nil }
        return "(identifier \"\(appIdentifier)\" or identifier \"\(watchdogIdentifier)\") and certificate leaf = H\"\(digest)\""
    }

    /// Requirement for an ad-hoc helper. The app and watchdog have different
    /// cdhashes, so each gets its own identifier+hash clause.
    static func adHocRequirement(appCDHash: String, watchdogCDHash: String?) -> String? {
        guard let app = normalizedCDHash(appCDHash) else { return nil }
        var clauses = ["(identifier \"\(appIdentifier)\" and cdhash H\"\(app)\")"]
        if let raw = watchdogCDHash, let watchdog = normalizedCDHash(raw) {
            clauses.append("(identifier \"\(watchdogIdentifier)\" and cdhash H\"\(watchdog)\")")
        }
        return clauses.joined(separator: " or ")
    }

    static func normalizedCDHash(_ value: String) -> String? {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard hex.count == 40 || hex.count == 64,
              hex.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else { return nil }
        return hex
    }

    /// Parses the root-owned `key=value` peer file written by the administrator
    /// installer. Unknown keys are ignored; malformed hashes fail closed.
    static func parsePeerConfig(_ text: String) -> (app: String, watchdog: String?)? {
        var app: String?
        var watchdog: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "app": app = normalizedCDHash(value)
            case "watchdog": watchdog = normalizedCDHash(value)
            default: continue
            }
        }
        guard let app else { return nil }
        return (app, watchdog)
    }

    static func requirementForRunningHelper(peerConfigPath: String? = nil) -> String? {
        if let certificate = certificateRequirement() { return certificate }
        guard let peerConfigPath else { return nil }
        guard let config = loadPeerConfig(at: peerConfigPath) else { return nil }
        return adHocRequirement(appCDHash: config.app, watchdogCDHash: config.watchdog)
    }

    private static func certificateRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &information) == errSecSuccess,
              let fields = information as? [String: Any],
              let certificates = fields[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        // The code requirement certificate hash syntax uses SHA-1. This pins the
        // full certificate, not its forgeable subject/CN; no SHA-1 signature is made.
        let bytes = SecCertificateCopyData(leaf) as Data
        let digest = Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return requirement(certificateSHA1: digest)
    }

    /// The helper runs as root. Refuse a peer file that another user could
    /// rewrite: root:wheel ownership and no group/other write bits.
    private static func loadPeerConfig(at path: String) -> (app: String, watchdog: String?)? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0, size < 4096,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber, owner.intValue == 0,
              let group = attributes[.groupOwnerAccountID] as? NSNumber, group.intValue == 0,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parsePeerConfig(text)
    }
}
