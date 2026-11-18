import AppKit
import CoreText

@main
struct TypographyMetricsTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { fatalError(message) }
    }

    static func checkResolvedMetrics() {
        for requested: CGFloat in [0, 9, 11.5, 12.5, 13, 19, 28] {
            let body = ClamType.bodyFont(requested)
            let mono = ClamType.monoFont(requested)
            let display = ClamType.displayFont(requested)
            check(body.pointSize == ClamType.bodySize(requested), "body renderer and measurement size agree")
            check(mono.pointSize == ClamType.monoSize(requested), "mono renderer and measurement size agree")
            check(display.pointSize == max(12, requested), "display renderer and measurement size agree")
            let expectedBody = NSFont(name: "PixelOperator", size: ClamType.bodySize(requested))
                ?? .systemFont(ofSize: ClamType.bodySize(requested))
            check(body.fontName == expectedBody.fontName, "body uses PixelOperator or its same-size fallback")
            let bold = ClamType.bodyFont(requested, .bold)
            let expectedBold = NSFont(name: "PixelOperator-Bold", size: ClamType.bodySize(requested))
                ?? .systemFont(ofSize: ClamType.bodySize(requested), weight: .semibold)
            check(bold.pointSize == expectedBold.pointSize && bold.fontName == expectedBold.fontName,
                  "bold body uses its pixel face or a same-size weighted fallback")
        }
        let body = ClamType.bodyFont(13)
        let mono = ClamType.monoFont(11.5)
        let display = ClamType.displayFont(19)
        check(body.ascender - body.descender + body.leading < 32, "body metrics fit compact 32pt menu rows")
        check(mono.ascender - mono.descender + mono.leading < 32, "mono metrics fit compact menu rows")
        let summary = ClamType.resolvedFontSummary()
        for (role, font) in [("body", body), ("mono", mono), ("display", display)] {
            check(summary.contains("\(role)=\(font.fontName)@\(font.pointSize)"),
                  "diagnostics truthfully report the resolved \(role) face and size")
        }
    }

    static func main() {
        for requested: CGFloat in [0, 9, 11.5, 12.5, 13, 19, 28] {
            check(ClamType.bodySize(requested) == max(11, requested + 1.25), "restored body scale and floor")
            check(ClamType.nameSize(requested) == max(13, requested), "restored name scale and floor")
            check(ClamType.labelSize(requested) == max(9, requested), "restored label scale and floor")
            check(ClamType.monoSize(requested) == max(9, requested), "restored mono scale and floor")
        }
        // A standalone test initially exercises whichever faces AppKit resolves,
        // including same-size fallbacks; then register the real bundled faces.
        checkResolvedMetrics()
        _ = ClamType.registerBundledFonts()
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Fonts/Pixel")
        for name in ["PixelOperator", "PixelOperator-Bold", "PixelOperator8", "PixelOperator8-Bold",
                     "PixelOperatorMono", "PixelOperatorMono-Bold"] {
            let url = fonts.appendingPathComponent(name + ".ttf")
            check(FileManager.default.fileExists(atPath: url.path), "bundled font exists: \(name)")
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            check(NSFont(name: name, size: 13) != nil, "bundled face resolves: \(name)")
        }
        checkResolvedMetrics()
        print("PASS: \(checks) restored pixel typography and truthful metrics checks")
    }
}
