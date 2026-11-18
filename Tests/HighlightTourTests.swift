import Foundation

@main
struct HighlightTourTests {
    static func main() {
        let expected: [HighlightTourStep] = [
            .welcome, .componentCard, .componentDetail, .inlineOption, .optionEditor,
            .addComponent, .addScreen, .general, .menuOverview, .menuArm,
            .menuKeepAwake, .menuDurations, .menuNavigation, .finish
        ]
        precondition(HighlightTourStep.allCases == expected)
        precondition(expected.count == 14)
        precondition(expected.count == OnboardingProgress.lastStep + 1)
        precondition(Set(expected.map(\.rawValue)).count == expected.count)
        let rawValues = ["welcome", "componentCard", "componentDetail", "inlineOption",
                         "optionEditor", "addComponent", "addScreen", "general", "menuOverview",
                         "menuArm", "menuKeepAwake", "menuDurations", "menuNavigation", "finish"]
        precondition(expected.map(\.rawValue) == rawValues)
        for (index, step) in expected.enumerated() {
            precondition(HighlightTourStep(rawValue: step.rawValue) == step)
            precondition(step.isMenu == (8...12).contains(index))
        }
        precondition(!HighlightTourStep.general.isMenu)
        precondition(HighlightTourStep.menuOverview.isMenu)
        precondition(HighlightTourStep.menuNavigation.isMenu)
        precondition(!HighlightTourStep.finish.isMenu)
        precondition(HighlightTourStep.welcome.target == "componentsIntro")
        for step in expected[1...12] {
            precondition(step.target == step.rawValue)
        }
        precondition(HighlightTourStep.finish.target == "general")
        precondition(HighlightTourStep(rawValue: "unknown") == nil)
        print("PASS: all 14 tour steps, stable raw values, menu boundaries and settings anchors")
        print("Scope: pure Foundation models only; no Settings, engine, helper or live app linked")
    }
}
