import Foundation

// Pure table tests: compile with Sources/ComponentCapability.swift and
// Sources/ComponentCatalog.swift only. Nothing here launches the app, enables a
// component, reads hardware, or changes a preference.
@main
struct ComponentCapabilityTests {
    static func main() {
        let catalog = ComponentCatalog.all
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        check(ComponentCapabilityPolicy.duplicateIDs.isEmpty, "no duplicate capability entries")
        for component in catalog {
            check(ComponentCapabilityPolicy.isRegistered(component.id), "missing capability entry for \(component.id)")
            let capability = ComponentCapabilityPolicy.capability(for: component.id)
            check(capability.componentID == component.id, "entry id matches \(component.id)")
            check(!capability.reason.isEmpty, "reason present for \(component.id)")
            check(!capability.reason.contains("\n"), "reason is one line for \(component.id)")
            // A PASS *claim* is forbidden, but words like "password" are not.
            check(capability.reason.range(of: "\\bPASS\\b",
                                          options: .regularExpression) == nil,
                  "no PASS claim for \(component.id)")
            if component.needsHelper {
                // A helper-gated component may be automatic now, but it must never
                // be left with no capability statement at all.
                check(capability.status != .unsupported,
                      "helper-gated \(component.id) has a capability statement")
            } else {
                // Every non-helper component must say something explicit.
                check(capability.status != .unsupported, "non-helper \(component.id) is not left unsupported")
            }
        }

        check(Set(catalog.map(\.id)).isSuperset(of: ComponentCapabilityPolicy.registeredIDs),
              "every capability entry names a real component")
        check(ComponentCapabilityPolicy.capability(for: "not-a-real-component").status == .unsupported,
              "unregistered components fail closed")

        // The components wired to the privileged helper report a shipped automatic
        // path and name the helper's limits instead of hiding them.
        for id in ["sleepUntilReset", "lowPowerWhileClosed", "fanBoost", "passwordAfterClose",
                   "stayOffWhenOpened", "homeServer", "sleepMeansSleep"] {
            let capability = ComponentCapabilityPolicy.capability(for: id)
            check(capability.status == .implemented || capability.status == .partial,
                  "\(id) reports a shipped automatic path")
            check(capability.reason.lowercased().contains("helper"),
                  "\(id) reason names the privileged helper")
            check(capability.status != .protectedManualOnly,
                  "\(id) is no longer manual-only")
        }
        check(ComponentCapabilityPolicy.capability(for: "fanBoost").reason.contains("F0Md")
              && ComponentCapabilityPolicy.capability(for: "fanBoost").reason.contains("F0Tg"),
              "fan boost names the SMC keys it depends on")
        check(ComponentCapabilityPolicy.capability(for: "stayOffWhenOpened").reason.contains("BootPreference"),
              "stay off names the NVRAM setting it depends on")
        check(ComponentCapabilityPolicy.capability(for: "homeServer").reason.contains("autorestart"),
              "home server names the pmset setting it depends on")
        check(ComponentCapabilityPolicy.capability(for: "passwordAfterClose").reason.contains("unlock"),
              "password after close names when Touch ID is restored")
        check(ComponentCapabilityPolicy.capability(for: "sleepMeansSleep").reason.contains("powernap")
              && ComponentCapabilityPolicy.capability(for: "sleepMeansSleep").reason.contains("restores"),
              "sleep means sleep names the owned wake sources and restoration")
        for id in ["keepAwake", "cleaningLock"] {
            check(ComponentCapabilityPolicy.capability(for: id).status == .protectedManualOnly,
                  "\(id) stays manual-only")
        }
        for id in ["agentScreen", "agentStatus"] {
            check(ComponentCapabilityPolicy.capability(for: id).status == .partial,
                  "\(id) must not claim original metadata parity")
        }
        for status in [ComponentCapabilityStatus.implemented, .partial, .protectedManualOnly, .unsupported] {
            check(!status.label.isEmpty, "status \(status.rawValue) has a label")
        }

        print("PASS component capability table: \(catalog.count) components, \(checks) checks, no runtime effects")
    }
}
