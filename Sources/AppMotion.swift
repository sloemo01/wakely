import SwiftUI
import AppKit

/// Motion belongs to the surface being changed, never to a whole settings
/// transaction. Pixel art, scrubbing and the deterministic reveal stay atomic
/// or use their own timing; geometry/chrome share these restrained springs.
enum AppMotion {
    enum Preset { case feedback, control, navigation, layout, sheet }

    static func animation(_ preset: Preset, reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else { return nil }
        switch preset {
        case .feedback: return .spring(response: 0.22, dampingFraction: 0.92)
        case .control: return .spring(response: 0.28, dampingFraction: 0.88)
        case .navigation: return .spring(response: 0.38, dampingFraction: 0.94)
        case .layout: return .spring(response: 0.40, dampingFraction: 0.95)
        case .sheet: return .spring(response: 0.42, dampingFraction: 0.90)
        }
    }

    /// AppKit durations, on the same short-feedback / longer-layout scale.
    static let submenuDuration: TimeInterval = 0.20
    static let pixelRevealDuration: TimeInterval = 0.24
    static let longFrameCutoff: TimeInterval = 0.80
}

private struct WakelyPaneActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var wakelyPaneIsActive: Bool {
        get { self[WakelyPaneActiveKey.self] }
        set { self[WakelyPaneActiveKey.self] = newValue }
    }
}
