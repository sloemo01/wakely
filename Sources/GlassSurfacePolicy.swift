import Foundation

/// Pure material-selection policy. The view layer only supplies runtime facts;
/// this type makes the precedence explicit and testable without AppKit.
enum GlassSurfacePolicy {
    enum Style: Equatable {
        case native
        case fallback
        case opaque
    }

    static func resolve(reduceTransparency: Bool,
                        force: String?,
                        nativeAvailable: Bool) -> Style {
        if reduceTransparency { return .opaque }
        switch force?.lowercased() {
        case "off", "opaque":
            return .opaque
        case "fallback", "visual-effect":
            return .fallback
        case "native", "glass":
            return nativeAvailable ? .native : .fallback
        default:
            return nativeAvailable ? .native : .fallback
        }
    }
}
