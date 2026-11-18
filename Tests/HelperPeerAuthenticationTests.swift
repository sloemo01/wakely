// Pure identity-policy and requirement-parser regression tests. No helper,
// administrator prompts, registration, settings writes or hardware access.
import Foundation
import Security

@main
struct HelperPeerAuthenticationTests {
    static func main() {
        precondition(HelperPeerPolicy.requirement(certificateSHA1: nil) == nil)
        for invalid in ["", "Wakely Dev", String(repeating: "a", count: 39),
                        String(repeating: "a", count: 41), String(repeating: "g", count: 40),
                        String(repeating: "A", count: 40), "\" or true //"] {
            precondition(HelperPeerPolicy.requirement(certificateSHA1: invalid) == nil)
        }
        let digest = String(repeating: "a1", count: 20)
        let requirement = HelperPeerPolicy.requirement(certificateSHA1: digest)!
        precondition(requirement == "(identifier \"dev.wakely.app\" or identifier \"dev.wakely.watchdog\") and certificate leaf = H\"\(digest)\"")
        precondition(!requirement.contains("subject.CN"))
        var parsed: SecRequirement?
        precondition(SecRequirementCreateWithString(requirement as CFString, [], &parsed) == errSecSuccess)
        precondition(parsed != nil)
        let adHoc = HelperPeerPolicy.adHocRequirement(
            appCDHash: String(repeating: "ab", count: 20),
            watchdogCDHash: String(repeating: "cd", count: 20)
        )!
        precondition(adHoc.contains("identifier \"dev.wakely.app\" and cdhash H\""))
        precondition(adHoc.contains("identifier \"dev.wakely.watchdog\" and cdhash H\""))
        precondition(adHoc.contains(" or "))
        var adHocParsed: SecRequirement?
        precondition(SecRequirementCreateWithString(adHoc as CFString, [], &adHocParsed) == errSecSuccess)
        precondition(HelperPeerPolicy.adHocRequirement(appCDHash: "not-a-hash", watchdogCDHash: nil) == nil)
        let peerText = "app=\(String(repeating: "ab", count: 20))\nwatchdog=\(String(repeating: "cd", count: 20))\n"
        precondition(HelperPeerPolicy.parsePeerConfig(peerText)?.app == String(repeating: "ab", count: 20))
        precondition(HelperPeerPolicy.parsePeerConfig(peerText)?.watchdog == String(repeating: "cd", count: 20))
        precondition(HelperPeerPolicy.parsePeerConfig("app=nope") == nil)
        // An ad-hoc test executable must not acquire a peer requirement merely
        // because it has a valid code-signing identifier when no peer file is
        // explicitly supplied.
        if CommandLine.arguments.contains("--expect-adhoc") {
            precondition(HelperPeerPolicy.requirementForRunningHelper() == nil)
            var executable: SecStaticCode?
            let url = URL(fileURLWithPath: CommandLine.arguments[0]) as CFURL
            precondition(SecStaticCodeCreateWithPath(url, [], &executable) == errSecSuccess)
            precondition(SecStaticCodeCheckValidity(executable!, [], parsed!) != errSecSuccess,
                         "A matching ad-hoc bundle identifier must not satisfy certificate-pinned authentication")
        }
        print("Helper peer authentication policy tests passed")
    }
}
