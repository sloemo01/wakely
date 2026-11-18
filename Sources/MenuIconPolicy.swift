import AppKit

/// Decorative symbols only: never changes the source item's action or AX label.
enum MenuIconPolicy {
    static func symbolName(title: String, action: Selector?, hasSubmenu: Bool) -> String? {
        let selector = action.map(NSStringFromSelector) ?? ""
        switch selector {
        case "openSettings": return "gearshape"
        case "openComponents": return "square.grid.2x2"
        case "showAbout": return "info.circle"
        case "quit": return "power"
        case "lockForCleaning": return "lock"
        case "stopKeepAwake": return "stop.circle"
        case "startKeepAwake:": return title == "Indefinitely" ? "infinity" : "clock"
        case "activateAgent:": return "terminal"
        default: break
        }
        if title == "Arm Wakely" { return "shield.lefthalf.filled" }
        if title.hasPrefix("Unarm") { return "shield.slash" }
        if title.hasPrefix("Keep Awake") { return "sun.max" }
        if title == "Stop Keep Awake" { return "stop.circle" }
        if title == "Indefinitely" { return "infinity" }
        if ["1 hour", "2 hours", "4 hours"].contains(title) { return "clock" }
        if title.hasPrefix("Settings") { return "gearshape" }
        if title == "Components" { return "square.grid.2x2" }
        if title.hasPrefix("About") { return "info.circle" }
        if title.hasPrefix("Quit") { return "power" }
        if title.hasPrefix("Lock for Cleaning") { return "lock" }
        return hasSubmenu ? "folder" : (action != nil ? "circle" : nil)
    }
}
