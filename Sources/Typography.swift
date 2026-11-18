import SwiftUI
import AppKit
import CoreText

/// Bundled pixel typography.
///
/// The family is Pixel Operator (CC0 1.0), a bitmap UI face with true
/// lowercase and thick one-pixel stems. It replaces the earlier Silkscreen /
/// Pixelify Sans pair, which was more decorative but thinner at small sizes.
///
///  * PixelOperator      — body copy and names.
///  * PixelOperator-Bold — pane titles and large headings.
///  * PixelOperator8     — the 8 px cut, for small all-caps labels.
///  * PixelOperatorMono  — prompts and code-like text.
///
/// Preserve the authored compact pixel rhythm. Interaction contrast is refined
/// through semantic colours, not by replacing the face or globally scaling it.
enum ClamType {

    // MARK: Font faces

    private static let bodyRegular = "PixelOperator"
    private static let bodyBold = "PixelOperator-Bold"
    private static let displayBold = "PixelOperator-Bold"
    private static let smallBold = "PixelOperator8-Bold"
    private static let monoRegular = "PixelOperatorMono"
    private static let monoBold = "PixelOperatorMono-Bold"

    /// Register the bundled families once. Called before any window is built.
    /// A failure is logged by the caller and `.custom` falls back to the system
    /// face, so typography can never prevent the app from starting.
    @discardableResult
    static func registerBundledFonts() -> Bool {
        let names = ["PixelOperator.ttf", "PixelOperator-Bold.ttf",
                     "PixelOperator8.ttf", "PixelOperator8-Bold.ttf",
                     "PixelOperatorMono.ttf", "PixelOperatorMono-Bold.ttf"]
        var registered = 0
        for subdirectory in ["Fonts/Pixel", "Fonts"] {
            for name in names {
                guard let url = Bundle.main.url(forResource: name, withExtension: nil,
                                                subdirectory: subdirectory) else { continue }
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    registered += 1
                } else {
                    _ = error
                }
            }
        }
        return registered > 0
    }

    // MARK: Semantic styles

    // Keep the original pixel proportions. Native renderers and SwiftUI share
    // these resolutions, including the fallback path, so chips never mismeasure.
    static func bodySize(_ requested: CGFloat) -> CGFloat { max(11, requested + 1.25) }
    static func nameSize(_ requested: CGFloat) -> CGFloat { max(13, requested) }
    static func labelSize(_ requested: CGFloat) -> CGFloat { max(9, requested) }
    static func monoSize(_ requested: CGFloat) -> CGFloat { max(9, requested) }

    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(isHeavy(weight) ? bodyBold : bodyRegular, size: bodySize(size))
    }

    static func name(_ size: CGFloat) -> Font {
        .custom(bodyBold, size: nameSize(size))
    }

    static func display(_ size: CGFloat) -> Font {
        .custom(displayBold, size: max(12, size))
    }

    static func bodyFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        NSFont(name: isHeavy(weight) ? bodyBold : bodyRegular, size: bodySize(size))
            ?? .systemFont(ofSize: bodySize(size), weight: isHeavy(weight) ? .semibold : .regular)
    }

    static func monoFont(_ size: CGFloat, _ weight: Font.Weight = .regular) -> NSFont {
        NSFont(name: isHeavy(weight) ? monoBold : monoRegular, size: monoSize(size))
            ?? .monospacedSystemFont(ofSize: monoSize(size), weight: isHeavy(weight) ? .semibold : .regular)
    }

    static func displayFont(_ size: CGFloat) -> NSFont {
        NSFont(name: displayBold, size: max(12, size))
            ?? .systemFont(ofSize: max(12, size), weight: .bold)
    }

    static func label(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .custom(weight == .regular ? "PixelOperator8" : smallBold, size: labelSize(size))
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(weight == .regular ? monoRegular : monoBold, size: monoSize(size))
    }

    static func resolvedFontSummary() -> String {
        let display = displayFont(19)
        let body = bodyFont(13)
        let mono = monoFont(11.5)
        return "display=\(display.fontName)@\(display.pointSize) body=\(body.fontName)@\(body.pointSize) mono=\(mono.fontName)@\(mono.pointSize)"
    }

    private static func isHeavy(_ weight: Font.Weight) -> Bool {
        switch weight {
        case .semibold, .bold, .heavy, .black: return true
        default: return false
        }
    }
}
