import Foundation

@main
struct ComponentPermissionPolicyTests {
    static func main() {
        let ids = Set(ComponentCatalog.all.map(\.id))
        precondition(ids.count == 31)
        let allReady = Set(ComponentPermission.allCases)
        for id in ids {
            let requirements = ComponentPermissionPolicy.requirements(for: id)
            precondition(Set(requirements.map(\.permission)).count == requirements.count)
            let missing = ComponentPermissionPolicy.missingRequired(for: id, ready: [])
            precondition(missing.count == requirements.filter(\.required).count)
            precondition(ComponentPermissionPolicy.missingRequired(for: id, ready: allReady).isEmpty)
            // Simulated first install: no grant must never pass a required gate.
            if requirements.contains(where: \.required) { precondition(!missing.isEmpty) }
            // Simulated revocation: removing any required grant blocks again.
            for requirement in requirements where requirement.required {
                var revoked = allReady
                revoked.remove(requirement.permission)
                precondition(ComponentPermissionPolicy.missingRequired(for: id, ready: revoked)
                    .contains(requirement.permission))
            }
        }
        precondition(ComponentPermissionPolicy.missingRequired(for: "capsLock", ready: []).isEmpty,
                     "Caps Lock arming does not require the optional typing filter")
        precondition(ComponentPermissionPolicy.missingRequired(for: "cleaningLock", ready: []) == [.accessibility])
        precondition(!ComponentPermissionPolicy.resumesEnableAfterGrant("cleaningLock"),
                     "Granting access in Settings must not suddenly lock input")
        precondition(ComponentPermissionPolicy.resumesEnableAfterGrant("armOnWiFi"))
        precondition(ComponentPermissionPolicy.requirements(for: "agentScreen").isEmpty,
                     "Holding a display assertion is not screen capture")
        for permission in ComponentPermission.allCases {
            precondition(permission.settingsURL.scheme == "x-apple.systempreferences")
            precondition(permission.supportsAppDrag == (permission == .accessibility))
            precondition(!permission.instructions.isEmpty)
        }
        precondition(ComponentPermission.accessibility.settingsURL.absoluteString.contains("Privacy_Accessibility"))
        precondition(ComponentPermission.location.settingsURL.absoluteString.contains("Privacy_LocationServices"))
        let automaticHelpers = Set(ComponentCatalog.all
            .filter(\.needsHelper)
            .map(\.id))
        precondition(automaticHelpers.isSubset(of: ComponentPermissionPolicy.helperIDs),
                     "Every helper-dependent entry offers helper onboarding")
        precondition(ComponentPermissionPolicy.requirements(for: "sleepMeansSleep") ==
                     [.init(permission: .helper, required: true)],
                     "Sleep Means Sleep needs the shared helper before it can change battery wake sources")
        print("PASS: all 31 permission maps, clean-install/revocation policy, optional AX, no auto-lock and exact Settings routes")
        print("Scope: pure policy simulation only; no system grants, event taps, notifications or helper installation exercised")
    }
}
