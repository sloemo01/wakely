// ProtectedComponentPolicyTests — pure policy tests for the protected-component block
// in Sources/ComponentBehaviors.swift.
//
// This file is self-contained so `swiftc Tests/ProtectedComponentPolicyTests.swift`
// works on its own. The generated section below must stay byte-identical to the
// `// BEGIN TESTABLE PROTECTED POLICY` block in Sources/ComponentBehaviors.swift;
// Tests/test_protected_component_policy.py re-extracts that block, compares it,
// then compiles and runs this file. No AppKit, IOKit, helper, XPC or
// UserDefaults access is reachable from here.

import Foundation

// BEGIN GENERATED PROTECTED POLICY
//
// Pure policy for the privileged protected components: no AppKit, IOKit, XPC,
// HelperClient or UserDefaults. Tests extract this block, compile it on its own
// and exercise ordering, idempotence and the capability gate.

enum ProtectedComponentPolicy {
    enum Scope: String, Equatable {
        case session
        case persistent
    }

    enum Action: Equatable {
        case lowPowerOn
        case suppressWakeSources
        case fanPercent
        case touchIDOff
        case autoRestartOn
        case bootOnLidOpenOff
    }

    struct Step: Equatable {
        let componentID: String
        let action: Action
        let needsBattery: Bool
        let needsNoExternalDisplay: Bool
    }

    struct GateDecision: Equatable {
        let allowed: Bool
        let reason: String
    }

    /// Fixed application order. Restoration walks it backwards.
    static let orderedSteps: [Step] = [
        Step(componentID: "lowPowerWhileClosed", action: .lowPowerOn,
             needsBattery: true, needsNoExternalDisplay: false),
        Step(componentID: "sleepMeansSleep", action: .suppressWakeSources,
             needsBattery: false, needsNoExternalDisplay: false),
        Step(componentID: "fanBoost", action: .fanPercent,
             needsBattery: false, needsNoExternalDisplay: false),
        Step(componentID: "passwordAfterClose", action: .touchIDOff,
             needsBattery: false, needsNoExternalDisplay: true),
        Step(componentID: "homeServer", action: .autoRestartOn,
             needsBattery: false, needsNoExternalDisplay: false),
        Step(componentID: "stayOffWhenOpened", action: .bootOnLidOpenOff,
             needsBattery: false, needsNoExternalDisplay: false)
    ]

    static let sessionScoped: Set<String> = [
        "lowPowerWhileClosed", "fanBoost", "passwordAfterClose"
    ]
    static let persistent: Set<String> = ["homeServer", "stayOffWhenOpened", "sleepMeansSleep"]

    static var componentIDs: Set<String> { Set(orderedSteps.map(\.componentID)) }

    static func scope(of componentID: String) -> Scope? {
        if sessionScoped.contains(componentID) { return .session }
        if persistent.contains(componentID) { return .persistent }
        return nil
    }

    static func isProtected(_ componentID: String) -> Bool { scope(of: componentID) != nil }

    /// Helper operation names, kept as strings so this block stays free of the
    /// helper client and its XPC types.
    static func operation(for componentID: String) -> String? {
        switch componentID {
        case "lowPowerWhileClosed": return "lowPowerMode"
        case "sleepMeansSleep": return "suppressWakeSources"
        case "fanBoost": return "fanPercent"
        case "passwordAfterClose": return "touchIDUnlock"
        case "homeServer": return "autoRestartAfterPowerLoss"
        case "stayOffWhenOpened": return "bootOnLidOpen"
        default: return nil
        }
    }

    /// 0 means automatic in the helper, which is not a boost; the enabled component
    /// therefore clamps to 1...100 and defaults to 100.
    /// The original's `HelperSMC.fanSpeedPercents` is `30...100`: it never asks
    /// for less than 30% of a fan's maximum. Decompiled from
    /// reference helper's `get_fanSpeedPercents`.
    static let fanPercentRange = 30...100

    static func fanPercent(from raw: Int?) -> Int {
        min(fanPercentRange.upperBound, max(fanPercentRange.lowerBound, raw ?? 100))
    }

    static func sessionPlan(enabled: Set<String>, onBattery: Bool, externalDisplay: Bool) -> [Step] {
        orderedSteps.filter { step in
            guard enabled.contains(step.componentID) else { return false }
            if step.needsBattery, !onBattery { return false }
            if step.needsNoExternalDisplay, externalDisplay { return false }
            return true
        }
    }

    static func pendingSessionPlan(enabled: Set<String>, applied: Set<String>,
                                   onBattery: Bool, externalDisplay: Bool) -> [Step] {
        sessionPlan(enabled: enabled, onBattery: onBattery, externalDisplay: externalDisplay)
            .filter { !applied.contains($0.componentID) }
    }

    static func persistentPlan(enabled: Set<String>) -> [Step] {
        orderedSteps.filter { persistent.contains($0.componentID) && enabled.contains($0.componentID) }
    }

    /// Reverse application order, restricted to what was actually applied.
    static func restorePlan(applied: Set<String>, limit: Scope? = nil) -> [String] {
        orderedSteps.reversed().compactMap { step in
            guard applied.contains(step.componentID) else { return nil }
            if let limit = limit, scope(of: step.componentID) != limit { return nil }
            return step.componentID
        }
    }

    /// Reads the component ids a helper `status` reply reports as having saved
    /// leases. Unknown ids are ignored; the result keeps application order.
    static func leases(details: [String: String]) -> [String] {
        var found: Set<String> = []
        for key in ["leases", "savedLeases", "saved.leases", "componentLeases",
                    "components", "savedComponents"] {
            guard let raw = details[key] else { continue }
            for piece in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
                let id = String(piece)
                if isProtected(id) { found.insert(id) }
            }
        }
        for (key, value) in details where key.hasPrefix("lease.") {
            let id = String(key.dropFirst("lease.".count))
            if isProtected(id), truthy(value) { found.insert(id) }
        }
        return orderedSteps.map(\.componentID).filter { found.contains($0) }
    }

    static func staleLeases(reported: [String], enabled: Set<String>) -> [String] {
        orderedSteps.map(\.componentID).filter { reported.contains($0) && !enabled.contains($0) }
    }

    static func truthy(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "active", "supported", "enabled": return true
        default: return false
        }
    }

    /// A component is enabled only when the helper is reachable and reports the
    /// operation as supported. Non-protected components need no gate.
    static func gate(componentID: String, reachable: Bool, supported: Bool,
                     supportReason: String = "") -> GateDecision {
        guard isProtected(componentID) else { return GateDecision(allowed: true, reason: "") }
        guard reachable else {
            return GateDecision(
                allowed: false,
                reason: "the privileged helper is not reachable; install it and approve it before enabling this component")
        }
        guard supported else {
            let text = supportReason.trimmingCharacters(in: .whitespacesAndNewlines)
            return GateDecision(
                allowed: false,
                reason: text.isEmpty ? "the privileged helper does not support this operation" : text)
        }
        return GateDecision(allowed: true, reason: "")
    }

    /// In-memory ledger mirroring the runtime's `applied` set: `markApplied`
    /// returns false for a duplicate, and restore plans only name ids that were
    /// actually applied.
    struct Ledger {
        private(set) var applied: Set<String> = []

        init() {}

        mutating func markApplied(_ componentID: String) -> Bool {
            guard ProtectedComponentPolicy.isProtected(componentID) else { return false }
            return applied.insert(componentID).inserted
        }

        /// A lease from a previous run proves the helper performed the change.
        mutating func adopt(_ componentID: String) -> Bool { markApplied(componentID) }

        mutating func markRestored(_ componentID: String) -> Bool {
            applied.remove(componentID) != nil
        }

        func pending(enabled: Set<String>, onBattery: Bool, externalDisplay: Bool) -> [Step] {
            ProtectedComponentPolicy.pendingSessionPlan(
                enabled: enabled, applied: applied,
                onBattery: onBattery, externalDisplay: externalDisplay)
        }

        func restorePlan(limit: Scope? = nil) -> [String] {
            ProtectedComponentPolicy.restorePlan(applied: applied, limit: limit)
        }
    }
}
// END GENERATED PROTECTED POLICY

@main
struct ProtectedComponentPolicyTests {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            checks += 1
        }

        // (a) Which components are session-scoped and which are persistent.

        let order = ["lowPowerWhileClosed", "sleepMeansSleep", "fanBoost",
                     "passwordAfterClose", "homeServer", "stayOffWhenOpened"]
        check(ProtectedComponentPolicy.orderedSteps.map(\.componentID) == order,
              "application order is fixed")
        check(ProtectedComponentPolicy.sessionScoped ==
              Set(["lowPowerWhileClosed", "fanBoost", "passwordAfterClose"]),
              "low power, fan boost and Touch ID are session-scoped")
        check(ProtectedComponentPolicy.persistent ==
              Set(["sleepMeansSleep", "homeServer", "stayOffWhenOpened"]),
              "wake sources, auto restart and boot-on-open are persistent")
        check(ProtectedComponentPolicy.componentIDs == Set(order),
              "the protected set is exactly the six wired components")
        check(ProtectedComponentPolicy.componentIDs
                == ProtectedComponentPolicy.sessionScoped.union(ProtectedComponentPolicy.persistent),
              "every protected component has one scope")
        check(ProtectedComponentPolicy.scope(of: "lowPowerWhileClosed") == .session,
              "low power scope")
        check(ProtectedComponentPolicy.scope(of: "stayOffWhenOpened") == .persistent,
              "stay off scope")
        check(ProtectedComponentPolicy.scope(of: "capsLock") == nil,
              "unrelated components have no protected scope")
        check(!ProtectedComponentPolicy.isProtected("sleepUntilReset"),
              "the manual wake component is not in the automatic protected set")
        for id in order {
            check(ProtectedComponentPolicy.isProtected(id), "\(id) is protected")
            check(ProtectedComponentPolicy.operation(for: id) != nil,
                  "\(id) names one helper operation")
        }
        check(ProtectedComponentPolicy.operation(for: "sleepUntilReset") == nil,
              "no helper operation is invented for the manual wake component")

        // (b) Apply/restore ordering, conditions and idempotence.

        let all = ProtectedComponentPolicy.componentIDs
        let full = ProtectedComponentPolicy.sessionPlan(
            enabled: all, onBattery: true, externalDisplay: false)
        check(full.map(\.componentID) == order, "all six apply in order")

        let onAC = ProtectedComponentPolicy.sessionPlan(
            enabled: all, onBattery: false, externalDisplay: false)
        check(onAC.map(\.componentID) == ["sleepMeansSleep", "fanBoost", "passwordAfterClose",
                                      "homeServer", "stayOffWhenOpened"],
              "low power is skipped on AC power")

        let external = ProtectedComponentPolicy.sessionPlan(
            enabled: all, onBattery: true, externalDisplay: true)
        check(external.map(\.componentID) == ["lowPowerWhileClosed", "sleepMeansSleep",
                                          "fanBoost", "homeServer", "stayOffWhenOpened"],
              "Touch ID is left alone when an external display is attached")

        check(ProtectedComponentPolicy.sessionPlan(
            enabled: ["fanBoost"], onBattery: false, externalDisplay: true)
                .map(\.componentID) == ["fanBoost"],
              "only enabled components can apply")
        check(ProtectedComponentPolicy.sessionPlan(
            enabled: [], onBattery: true, externalDisplay: false).isEmpty,
              "nothing enabled means nothing to apply")

        check(ProtectedComponentPolicy.persistentPlan(enabled: all).map(\.componentID)
                == ["sleepMeansSleep", "homeServer", "stayOffWhenOpened"],
              "persistent plan is ordered and excludes session components")
        check(ProtectedComponentPolicy.persistentPlan(enabled: ["lowPowerWhileClosed"]).isEmpty,
              "a session component never enters the persistent plan")

        var ledger = ProtectedComponentPolicy.Ledger()
        check(ledger.pending(enabled: all, onBattery: true, externalDisplay: false).count == 6,
              "a fresh ledger has all six pending")
        for id in order {
            check(ledger.markApplied(id), "first apply of \(id) is accepted")
        }
        check(ledger.pending(enabled: all, onBattery: true, externalDisplay: false).isEmpty,
              "a repeated tick applies nothing")
        check(!ledger.markApplied("fanBoost"), "a duplicate apply is rejected")
        check(!ledger.markApplied("capsLock"), "a non-protected component cannot be applied")

        check(ledger.restorePlan(limit: .session)
                == ["passwordAfterClose", "fanBoost", "lowPowerWhileClosed"],
              "session restore reverses apply order and skips persistent components")
        check(ledger.restorePlan() == order.reversed(),
              "full restore reverses the whole apply order")
        check(ledger.restorePlan()
                == ["stayOffWhenOpened", "homeServer", "passwordAfterClose", "fanBoost",
                    "sleepMeansSleep", "lowPowerWhileClosed"],
              "full restore order is explicit")

        check(ledger.markRestored("fanBoost"), "restoring an applied component is accepted")
        check(!ledger.markRestored("fanBoost"), "restoring twice is rejected")
        check(ledger.pending(enabled: all, onBattery: true, externalDisplay: false)
                .map(\.componentID) == ["fanBoost"],
              "a restored component is the only one that applies again")
        check(!ledger.restorePlan().contains("fanBoost"),
              "a restored component is not restored again")

        var crash = ProtectedComponentPolicy.Ledger()
        check(crash.adopt("lowPowerWhileClosed"), "a saved lease is adopted once")
        check(!crash.adopt("lowPowerWhileClosed"), "a lease is not adopted twice")
        check(crash.restorePlan(limit: .session) == ["lowPowerWhileClosed"],
              "an adopted lease is restorable")
        check(crash.pending(enabled: all, onBattery: true, externalDisplay: false)
                .map(\.componentID) == ["sleepMeansSleep", "fanBoost", "passwordAfterClose",
                                     "homeServer", "stayOffWhenOpened"],
              "an adopted lease is never applied again")

        let details = [
            "leases": "lowPowerWhileClosed, homeServer notARealComponent",
            "lease.fanBoost": "1",
            "lease.passwordAfterClose": "0"
        ]
        check(ProtectedComponentPolicy.leases(details: details)
                == ["lowPowerWhileClosed", "fanBoost", "homeServer"],
              "lease details parse known ids, keep order, and ignore false/unknown entries")
        check(ProtectedComponentPolicy.leases(details: [:]).isEmpty,
              "a helper with no lease details reports none")
        check(ProtectedComponentPolicy.staleLeases(
            reported: ["fanBoost", "homeServer"], enabled: ["homeServer"]) == ["fanBoost"],
              "a lease for a component that is no longer enabled is stale")
        check(ProtectedComponentPolicy.staleLeases(
            reported: ["fanBoost"], enabled: ["fanBoost"]).isEmpty,
              "a lease for a still-enabled component is not stale")

        check(ProtectedComponentPolicy.fanPercent(from: nil) == 100,
              "fan boost default is 100 percent")
        check(ProtectedComponentPolicy.fanPercent(from: 0) == 30,
              "0 (automatic) is not reported as a boost")
        check(ProtectedComponentPolicy.fanPercent(from: 1) == 30, "fan boost lower bound matches 30...100")
        check(ProtectedComponentPolicy.fanPercent(from: 55) == 55, "fan boost keeps a valid value")
        check(ProtectedComponentPolicy.fanPercent(from: 100) == 100, "fan boost upper bound")
        check(ProtectedComponentPolicy.fanPercent(from: 250) == 100, "fan boost never exceeds 100")

        // (c) Capability-gate decisions given reachable, supported and component id.

        let unreachable = ProtectedComponentPolicy.gate(
            componentID: "fanBoost", reachable: false, supported: true)
        check(!unreachable.allowed, "an unreachable helper never enables a component")
        check(unreachable.reason.contains("not reachable"), "the refusal says the helper is unreachable")

        let unsupported = ProtectedComponentPolicy.gate(
            componentID: "fanBoost", reachable: true, supported: false,
            supportReason: "SMC does not expose F0Md")
        check(!unsupported.allowed, "an unsupported operation never enables a component")
        check(unsupported.reason == "SMC does not expose F0Md",
              "the refusal carries the helper's reason")

        let bareUnsupported = ProtectedComponentPolicy.gate(
            componentID: "fanBoost", reachable: true, supported: false)
        check(!bareUnsupported.allowed, "an unsupported operation without a reason is refused")
        check(bareUnsupported.reason.contains("does not support"),
              "a missing reason still explains the refusal")

        let allowed = ProtectedComponentPolicy.gate(
            componentID: "fanBoost", reachable: true, supported: true)
        check(allowed.allowed && allowed.reason.isEmpty,
              "reachable plus supported enables the component")

        let ordinary = ProtectedComponentPolicy.gate(
            componentID: "capsLock", reachable: false, supported: false)
        check(ordinary.allowed, "a component that needs no helper is not gated")

        print("PASS: \(checks) pure protected-component policy checks; no helper call, apply or restore performed")
    }
}
