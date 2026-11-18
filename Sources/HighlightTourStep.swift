import Foundation

/// Navigation and copy only. Steps never represent a power or component action.
enum HighlightTourStep: String, CaseIterable {
    case welcome, componentCard, componentDetail, inlineOption, optionEditor
    case addComponent, addScreen, general
    case menuOverview, menuArm, menuKeepAwake, menuDurations, menuNavigation
    case finish

    static let demonstrationComponentID = "agentLight"

    var isMenu: Bool {
        switch self {
        case .menuOverview, .menuArm, .menuKeepAwake, .menuDurations, .menuNavigation: return true
        default: return false
        }
    }

    var target: String? {
        switch self {
        case .welcome: return "componentsIntro"
        case .finish: return "general"
        default: return rawValue
        }
    }

    var title: String {
        switch self {
        case .welcome: return "Meet Wakely, right here"
        case .componentCard: return "One component, one job"
        case .componentDetail: return "The explanation is the setting"
        case .inlineOption: return "These words are controls"
        case .optionEditor: return "Try changing a value"
        case .addComponent: return "Add a capability"
        case .addScreen: return "Add a whole screen"
        case .general: return "The app-wide settings"
        case .menuOverview: return "Your everyday menu"
        case .menuArm: return "Prepare for closing the lid"
        case .menuKeepAwake: return "Stay awake with the lid open"
        case .menuDurations: return "Choose how long"
        case .menuNavigation: return "Find your way back"
        case .finish: return "You know your way around"
        }
    }

    var explanation: String {
        switch self {
        case .welcome:
            return "Wakely lets you choose when your Mac stays awake, including with the lid closed. Components add small, specific behaviours. This tour points at the real controls; it won't arm your Mac or turn anything on."
        case .componentCard:
            return "We'll look at just Agent Light. Its name and short description tell you its job. Click the card to see the details. The switch is separate: it enables the component, and we won't touch it."
        case .componentDetail:
            return "The card opens into this detail page. Read what the component does and when it runs. Agent Light can show an agent's state in the menu bar. The highlighted value lives inside its explanation."
        case .inlineOption:
            return "Hover over the highlighted time to reveal the arrows. Use them to step the value, drag the number to scrub, or double-click it to type. You can practise here: this tour uses a temporary value, not your saved setting."
        case .optionEditor:
            return "This is the same inline number editor used by components. Type minutes and press Return to accept, or Escape to cancel. The practice value is discarded when the tour ends."
        case .addComponent:
            return "Make Your Own is where you describe a small capability to your coding agent. Wakely supplies a bounded prompt, then validates the files your agent creates. Nothing is built or enabled just by opening this form."
        case .addScreen:
            return "A screen is a new tab, not another component switch. Describe a page—such as live weather—to your agent. Wakely gives it the screen instructions and loads the finished page."
        case .general:
            return "General holds appearance, startup, helper setup, safety and support. Access is requested only when needed. You can also replay this tour here. We won't change any of these settings."
        case .menuOverview:
            return "This is Wakely's real menu, under its menu-bar mark. It shows the controls available with your current components. During the tour, menu actions are explanation-only."
        case .menuArm:
            return "Arm Wakely prepares a closed-lid session. A manual menu arm normally ends when you reopen the lid. If you're already armed, the menu shows Unarm instead; this tour leaves that session alone."
        case .menuKeepAwake:
            return "Keep Awake With Lid Open prevents idle system sleep while the lid is open. It is separate from arming closed-lid behaviour. Whether the display stays lit is a separate component option."
        case .menuDurations:
            return "The real submenu offers Indefinitely, 1 hour, 2 hours and 4 hours. A checkmark reflects a real active hold, not a tour selection. We're only looking—no duration is started."
        case .menuNavigation:
            return "Components opens your capabilities, Settings returns to General, and About has app information. Quit exits Wakely and releases its holds. None of those menu actions runs during this tour."
        case .finish:
            return "That's the tour: components, their inline settings, your own components and screens, General, and the menu. No component was enabled and no power setting was changed. Replay it from Getting Started whenever you like."
        }
    }

    var nextTitle: String {
        switch self {
        case .componentCard: return "Open this component"
        case .inlineOption: return "Try the editor"
        case .general: return "Show the menu"
        case .finish: return "Finish tour"
        default: return "Next"
        }
    }
}
