import Foundation

/// Standalone matrix for HomeServerPolicy and HomeServerRearmBudget. Compiled
/// with the policy file alone: no AppKit, no ServiceManagement, no login item,
/// no helper and no UserDefaults. Every case injects its own clock.
@main
struct HomeServerPolicyTests {
    static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard condition() else { fatalError(message, file: file, line: line) }
    }

    static func main() {
        let tests: [(String, () -> Void)] = [
            ("launch arms only when the component is on and the Mac is on AC", launchArming),
            ("control-disarm gate needs the component and AC", controlGate),
            ("reason classifier recognises control actions", controlReasons),
            ("reason classifier recognises every safety class", safetyReasons),
            ("an unknown reason is honored, never ignored", unknownReason),
            ("Home Server ignores only control disarms", disarmMatrix),
            ("login item is gated on the three restart-sensitive components", loginItemGating),
            ("rearm budget allows five automatic rearms per hour", rearmBudget),
            ("rearm budget slides its one-hour window", budgetWindow),
        ]
        for (name, test) in tests {
            test()
            print("PASS: \(name)")
        }
        print("\(tests.count) HomeServerPolicy tests passed")
    }

    // MARK: - Startup

    static func launchArming() {
        typealias P = HomeServerPolicy
        expect(P.shouldArmAtLaunch(componentEnabled: true, onCharger: true),
               "Home Server on AC arms at launch")
        expect(!P.shouldArmAtLaunch(componentEnabled: true, onCharger: false),
               "Home Server on battery does not arm at launch")
        expect(!P.shouldArmAtLaunch(componentEnabled: false, onCharger: true),
               "a disabled Home Server does not arm at launch")
        expect(!P.shouldArmAtLaunch(componentEnabled: false, onCharger: false),
               "disabled and on battery arms nothing")
    }

    static func controlGate() {
        typealias P = HomeServerPolicy
        expect(P.shouldIgnoreControlDisarm(componentEnabled: true, onCharger: true),
               "enabled on AC is the only case where a control stop can be ignored")
        expect(!P.shouldIgnoreControlDisarm(componentEnabled: true, onCharger: false),
               "on battery a control stop disarms")
        expect(!P.shouldIgnoreControlDisarm(componentEnabled: false, onCharger: true),
               "a disabled component never ignores a disarm")
        expect(!P.shouldIgnoreControlDisarm(componentEnabled: false, onCharger: false),
               "disabled and on battery never ignores a disarm")
    }

    // MARK: - Classifier

    static func controlReasons() {
        typealias P = HomeServerPolicy
        for reason in ["you", "url", "menu", "Caps Lock turned off",
                       "the lid opened", "nothing was working",
                       "the sleep timer ended"] {
            expect(P.classifyDisarm(reason) == .control,
                   "\"\(reason)\" is a control action")
            expect(!P.classifyDisarm(reason).isSafety,
                   "\"\(reason)\" is not a safety stop")
        }
        expect(P.classifyDisarm("") == .unrecognized,
               "an empty reason is unknown, so it is honored rather than ignored")
    }

    static func safetyReasons() {
        typealias P = HomeServerPolicy
        let cases: [(String, P.DisarmClass)] = [
            ("Wakely quit", .quit),
            ("the low battery guard tripped", .lowBattery),
            ("the battery is at or below 20%", .lowBattery),
            ("the battery reached 20%", .lowBattery),
            ("the battery budget ran out", .batteryBudget),
            ("the Mac got too hot", .thermal),
            ("thermal pressure 2", .thermal),
            ("component disabled", .componentDisabled),
            ("the privileged helper is being removed", .helperRemoved),
        ]
        for (reason, expected) in cases {
            expect(P.classifyDisarm(reason) == expected,
                   "\"\(reason)\" must classify as \(expected), got \(P.classifyDisarm(reason))")
            expect(P.classifyDisarm(reason).isSafety,
                   "\"\(reason)\" is a safety-class stop")
        }
        // Safety wins even when a control word is also present.
        expect(P.classifyDisarm("Wakely quit after you asked") == .quit,
               "quit is never downgraded to control by an extra word")
    }

    static func unknownReason() {
        typealias P = HomeServerPolicy
        expect(P.classifyDisarm("something nobody taught us") == .unrecognized,
               "an unlisted reason is unrecognized")
        expect(!P.classifyDisarm("something nobody taught us").isSafety,
               "unrecognized is not claimed as safety evidence")
        expect(!P.shouldIgnoreDisarm(componentEnabled: true, onCharger: true,
                                     reason: "something nobody taught us", shuttingDown: false),
               "an unrecognized reason is never ignored")
    }

    static func disarmMatrix() {
        typealias P = HomeServerPolicy
        // The one ignored case.
        expect(P.shouldIgnoreDisarm(componentEnabled: true, onCharger: true,
                                    reason: "you", shuttingDown: false),
               "a manual stop is ignored while Home Server holds an AC session")
        expect(P.shouldIgnoreDisarm(componentEnabled: true, onCharger: true,
                                    reason: "url", shuttingDown: false),
               "a URL stop is ignored while Home Server holds an AC session")
        // Every safety/quit/disable reason is honored.
        for reason in ["Wakely quit", "the battery is at or below 20%",
                       "the battery budget ran out", "the Mac got too hot",
                       "component disabled", "the privileged helper is being removed"] {
            expect(!P.shouldIgnoreDisarm(componentEnabled: true, onCharger: true,
                                         reason: reason, shuttingDown: false),
                   "\"\(reason)\" must disarm even while Home Server is on AC")
        }
        expect(!P.shouldIgnoreDisarm(componentEnabled: true, onCharger: true,
                                     reason: "unlisted stop", shuttingDown: false),
               "an unrecognized stop is honored rather than swallowed")
        expect(!P.shouldIgnoreDisarm(componentEnabled: true, onCharger: true,
                                     reason: "you", shuttingDown: true),
               "an orderly quit is never ignored")
        expect(!P.shouldIgnoreDisarm(componentEnabled: true, onCharger: false,
                                     reason: "you", shuttingDown: false),
               "on battery a control stop disarms")
        expect(!P.shouldIgnoreDisarm(componentEnabled: false, onCharger: true,
                                     reason: "you", shuttingDown: false),
               "a disabled Home Server ignores nothing")
    }

    // MARK: - Login item

    static func loginItemGating() {
        typealias P = HomeServerPolicy
        expect(P.shouldRegisterLoginItem(enabledComponentIDs: ["homeServer"]),
               "Home Server needs the login item")
        expect(P.shouldRegisterLoginItem(enabledComponentIDs: ["passwordAfterClose"]),
               "Password After Close needs the login item")
        expect(P.shouldRegisterLoginItem(enabledComponentIDs: ["sleepUntilReset"]),
               "Sleep Until Reset needs the login item")
        expect(P.shouldRegisterLoginItem(enabledComponentIDs: ["capsLock", "homeServer"]),
               "any one of the three is enough")
        expect(!P.shouldRegisterLoginItem(enabledComponentIDs: []),
               "no components means no login item")
        expect(!P.shouldRegisterLoginItem(enabledComponentIDs: ["capsLock", "agentStatus"]),
               "unrelated components do not request a login item")
        expect(P.loginItemComponentIDs == ["homeServer", "passwordAfterClose", "sleepUntilReset"],
               "the login-item set is exactly the three restart-sensitive components")
    }

    // MARK: - Rearm budget

    static func rearmBudget() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var budget = HomeServerRearmBudget()
        expect(budget.canRearm(now: start), "a fresh budget may rearm")
        expect(budget.remaining(now: start) == HomeServerRearmBudget.maximumPerHour,
               "a fresh budget has all five slots")

        for index in 0..<HomeServerRearmBudget.maximumPerHour {
            expect(budget.recordRearm(now: start.addingTimeInterval(Double(index))),
                   "rearm \(index + 1) of five is allowed")
        }
        expect(!budget.recordRearm(now: start.addingTimeInterval(10)),
               "the sixth rearm in one hour is refused")
        expect(!budget.canRearm(now: start.addingTimeInterval(10)),
               "the budget is exhausted")
        expect(budget.remaining(now: start.addingTimeInterval(10)) == 0,
               "no slots remain")
        budget.reset()
        expect(budget.canRearm(now: start), "reset restores the full budget")
    }

    static func budgetWindow() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var times = (0..<HomeServerRearmBudget.maximumPerHour)
            .map { start.addingTimeInterval(Double($0)) }
        var budget = HomeServerRearmBudget(rearms: times)
        expect(!budget.canRearm(now: start.addingTimeInterval(3599)),
               "at 59:59 the five rearms are still inside the window")
        expect(budget.canRearm(now: start.addingTimeInterval(3601)),
               "at 60:01 the first rearm has left the window")
        expect(budget.recordRearm(now: start.addingTimeInterval(3601)),
               "a freed slot can be used")
        expect(budget.rearmCount(now: start.addingTimeInterval(3601)) == 5,
               "the new rearm fills the window again")

        // Pruning is explicit and never invents slots.
        times = [start.addingTimeInterval(-7200)]
        budget = HomeServerRearmBudget(rearms: times)
        expect(budget.rearmCount(now: start) == 0, "two-hour-old rearms are outside the window")
        budget.prune(now: start)
        expect(budget.rearms.isEmpty, "prune drops entries outside the window")
    }
}
