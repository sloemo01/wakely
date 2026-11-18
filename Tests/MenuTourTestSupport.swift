import AppKit
import SwiftUI

// Presentation-only dependencies. No engine, permissions, helper or AppDelegate
// is linked into this executable. The actual coach is extracted by the runner.
enum Theme {
    enum Accent { case security }
    static func accent(_ value: Accent) -> Color { .orange }
    static let controlPressed = Color.gray
    static let goldSoft = Color.yellow
    static let control = Color.gray
    static let accentInk = Color.black
    static let window = Color.black
    static let gold = Color.yellow
    static let ink = Color.white
    static let textSecondary = Color.gray
    static let textTertiary = Color.gray
    static let stroke = Color.gray
    static let strokeHover = Color.gray
    static let cardHover = Color.gray
    static let controlHover = Color.gray
    static let cardHoverBorder = Color.gray
    static let hoverOutline = Color.gray
    static let selectedSurface = Color.gray
}
@MainActor final class ComponentEngine {
    static let shared = ComponentEngine()
    var keepAwakeEnabled = true
    func isEnabled(_ id: String) -> Bool { keepAwakeEnabled }
}
@MainActor final class HighlightTourNavigation {
    static let shared = HighlightTourNavigation()
    func previewCreation() { fatalError("Menu tour must not preview creation") }
}
