import AppKit

// Renders the real menu-bar mark on light and dark backgrounds and inspects
// pixels. No app delegate, engine, window or system setting is touched.
@main
struct BrandIconStrokeTests {
    struct Counts {
        var black = 0
        var white = 0
        var amber = 0
        var green = 0
        var other = 0
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func render(_ image: NSImage, on background: NSColor) -> NSBitmapImageRep {
        let side = 78
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side,
                                         pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            preconditionFailure("bitmap rep")
        }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        background.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func count(_ rep: NSBitmapImageRep) -> Counts {
        var counts = Counts()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if r < 0.08 && g < 0.08 && b < 0.08 { counts.black += 1 }
                else if r > 0.92 && g > 0.92 && b > 0.92 { counts.white += 1 }
                else if r > 0.70 && g > 0.50 && b < 0.40 { counts.amber += 1 }
                else if g > 0.45 && r < 0.45 && b < 0.55 { counts.green += 1 }
                else { counts.other += 1 }
            }
        }
        return counts
    }

    static func main() throws {
        let rows = BrandIcon.pixelRows
        check(rows.count == 11 && rows.allSatisfy { $0.count == 11 }, "11x11 glyph grid")
        let glyphCount = rows.reduce(0) { $0 + $1.filter { $0 == "1" }.count }
        check(glyphCount > 20, "glyph has real pixels")

        let idle = BrandIcon.statusImage(color: nil)
        check(!idle.isTemplate, "idle icon must keep its explicit white pixels")

        let darkBackground = NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.22, alpha: 1)
        for (name, background) in [("light", NSColor.white), ("dark", darkBackground)] {
            let rep = render(idle, on: background)
            let counts = count(rep)
            check(counts.black < 10, "\(name): idle icon must not have a black outline (\(counts.black))")
            check(counts.amber < 10, "\(name): idle icon must not have a coloured outline (\(counts.amber))")
            if name == "dark" {
                check(counts.white > 40, "dark: idle white glyph missing (\(counts.white))")
            }
            if let png = rep.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/tmp/wakely-brand-\(name).png"))
            }
            print("\(name): black=\(counts.black) white=\(counts.white) amber=\(counts.amber)")
        }

        // A green active state (such as indefinite Keep Awake) repaints the
        // outline while the glyph interior remains white.
        let active = BrandIcon.statusImage(color: .systemGreen)
        check(!active.isTemplate, "active icon must keep its coloured outline")
        let activeRep = render(active, on: darkBackground)
        let activeCounts = count(activeRep)
        check(activeCounts.black < 10, "active: outline must not turn black")
        check(activeCounts.green > 40, "active: green outline missing (\(activeCounts.green))")
        check(activeCounts.white > 40, "active: white interior missing (\(activeCounts.white))")
        check(activeCounts.amber < 10, "active: amber outline should be replaced")
        check(activeCounts.green < activeCounts.white * 3 / 2,
              "active: outline is too heavy (\(activeCounts.green) coloured vs \(activeCounts.white) white)")
        if let png = activeRep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/wakely-brand-active.png"))
        }
        print("active: green=\(activeCounts.green) white=\(activeCounts.white)")

        let armed = BrandIcon.statusImage(color: .systemYellow)
        let armedRep = render(armed, on: darkBackground)
        let armedCounts = count(armedRep)
        check(armedCounts.amber > 40, "armed: yellow outline missing (\(armedCounts.amber))")
        check(armedCounts.white > 40, "armed: white interior missing (\(armedCounts.white))")
        check(armedCounts.black < 10, "armed: outline must not turn black")
        check(armedCounts.amber < armedCounts.white * 3 / 2,
              "armed: outline is too heavy (\(armedCounts.amber) coloured vs \(armedCounts.white) white)")
        if let png = armedRep.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: "/tmp/wakely-brand-armed.png"))
        }
        print("armed: yellow=\(armedCounts.amber) white=\(armedCounts.white)")
        print("PASS: idle icon is white-only; state colour paints a thin active outline")
    }
}
