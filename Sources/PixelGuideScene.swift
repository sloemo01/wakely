import SwiftUI

/// Preview-only storyboard. The enclosing guide owns its 5 fps playback clock.
/// Onboarding is authored on a 160 × 60 grid; legacy props use 160 × 40.
/// Both stages snap to device pixels, with no interpolation or off-grid edges.
struct PixelGuideScene: View {
    let kind: GuideSceneKind
    let beat: Int
    let frame: Int
    @Environment(\.colorScheme) private var appearance
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Canvas { context, size in
            let scale = max(1, displayScale)
            let tour = [.welcome, .awakeModes, .components, .permissions, .ready].contains(kind)
            let gridHeight: CGFloat = tour ? 60 : 40
            let unit = floor(min(size.width / 160, size.height / gridHeight) * scale) / scale
            guard unit > 0 else { return }
            let origin = CGPoint(
                x: (floor((size.width - 160 * unit) / 2 * scale) / scale),
                y: (floor((size.height - gridHeight * unit) / 2 * scale) / scale))
            let art = GuidePixels(context: context, origin: origin, unit: unit, deviceScale: scale,
                                  on: GoldenSpritePalette.colors(on: true, appearance: appearance),
                                  off: GoldenSpritePalette.colors(on: false, appearance: appearance))
            art.scene(kind, beat: min(2, max(0, beat)), frame: ((frame % 12) + 12) % 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}

/// A small, reusable pixel-prop vocabulary. No clocks, services, or live state.
private struct GuidePixels {
    var context: GraphicsContext
    let origin: CGPoint
    let unit: CGFloat
    let deviceScale: CGFloat
    let on: [Character: Color]
    let off: [Character: Color]

    func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ tone: Character = "s", lit: Bool = true) {
        guard w > 0, h > 0, let color = (lit ? on : off)[tone] else { return }
        let box = CGRect(x: origin.x + CGFloat(x) * unit, y: origin.y + CGFloat(y) * unit,
                         width: CGFloat(w) * unit, height: CGFloat(h) * unit)
        context.fill(Path(box), with: .color(color), style: FillStyle(antialiased: false))
    }

    func glyph(_ x: Int, _ y: Int, _ rows: [String], _ tone: Character = "i", lit: Bool = true) {
        for (dy, row) in rows.enumerated() {
            for (dx, pixel) in row.enumerated() where pixel != "." {
                rect(x + dx, y + dy, 1, 1, tone, lit: lit)
            }
        }
    }

    func panel(_ x: Int, _ y: Int, _ w: Int, _ h: Int, lit: Bool = true) {
        rect(x + 1, y + h, w - 1, 1, "n", lit: lit)
        rect(x, y + 1, w, h - 2, "u", lit: lit)
        rect(x + 1, y, w - 2, h, "b", lit: lit)
        rect(x + 1, y + 1, w - 2, 1, "i", lit: lit)
        rect(x + 2, y + 2, w - 4, h - 4, "n", lit: lit)
    }

    func check(_ x: Int, _ y: Int, lit: Bool = true) {
        glyph(x, y, ["......##", ".....##.", "##..##..", ".####...", "..##...."], "i", lit: lit)
    }

    func moon(_ x: Int, _ y: Int) {
        glyph(x, y, ["..###..", ".##....", "##.....", "##.....", "##.....", ".##...#", "..####."], "l", lit: false)
    }

    func arrow(_ x: Int, _ y: Int, lit: Bool = true) {
        glyph(x, y, ["....#...", ".....#..", "########", ".....#..", "....#..."], "l", lit: lit)
    }

    /// Wakely's actual 11×11 eye-with-rays mark, shared with BrandIcon. The
    /// highlight is its single pupil; rays and ring stay in the golden palette.
    func wakely(_ x: Int, _ y: Int, lit: Bool = true) {
        for (row, line) in BrandIcon.pixelRows.enumerated() {
            for (column, pixel) in line.enumerated() where pixel == "1" {
                let pupil = row == 5 && column == 5
                rect(x + column, y + row, 1, 1, pupil ? "w" : "l", lit: lit)
            }
        }
    }

    /// The 7x7 outlined status item is right-aligned inside an illustrated
    /// menu bar. It never spills onto the wallpaper or becomes a desktop icon.
    func statusIcon(_ x: Int, _ y: Int, lit: Bool = true) {
        for (row, line) in BrandIcon.miniatureStatusPixelRows.enumerated() {
            for (column, pixel) in line.enumerated() where pixel != "." {
                rect(x + column, y + row, 1, 1, pixel == "1" ? "w" : "l", lit: lit)
            }
        }
    }

    func keyboard(_ x: Int, _ y: Int, caps: Bool = false, lit: Bool = true) {
        rect(x, y, 28, 10, "d", lit: lit)
        rect(x, y, 28, 1, "i", lit: lit)
        for row in 0..<2 {
            for col in 0..<8 { rect(x + 2 + col * 3, y + 2 + row * 3, 2, 2, "u", lit: lit) }
        }
        rect(x + 8, y + 8, 12, 1, "b", lit: lit)
        rect(x + 2, y + 5, 2, 2, caps ? "w" : "b", lit: caps)
    }

    func mac(_ x: Int, _ y: Int, closed: Bool, awake: Bool, screen: Bool = true) {
        // Hard pixel stair-steps suggest a thin three-quarter MacBook. Screen
        // pixels stop at the glass inset: no logo can leak over the bezel.
        if closed {
            let steps = [(5, 17, 32, 1), (3, 18, 36, 1), (1, 19, 40, 2), (0, 21, 42, 1)]
            for (dx, dy, width, height) in steps {
                rect(x + dx, y + dy, width, height, "s", lit: awake)
            }
            rect(x + 5, y + 17, 32, 1, "i", lit: awake)
            rect(x + 1, y + 19, 39, 1, "u", lit: awake)
            rect(x, y + 22, 42, 1, "d", lit: awake)
            rect(x + 17, y + 21, 9, 1, "n", lit: awake)
            rect(x + 4, y + 23, 4, 1, "n", lit: awake)
            rect(x + 34, y + 23, 4, 1, "n", lit: awake)
            glyph(x + 19, y + 19, ["#..", ".#.", "..#"], "d", lit: awake)
            return
        }

        // Bezel and recessed glass: the camera belongs on the bezel, not on
        // the display. A single dark bezel separates these two regions.
        for (dx, dy, width, height) in [(6, 0, 30, 1), (4, 1, 34, 1), (4, 2, 34, 18), (6, 20, 30, 1)] {
            rect(x + dx, y + dy, width, height, "d", lit: awake)
        }
        rect(x + 5, y + 2, 32, 17, "s", lit: awake)
        rect(x + 6, y + 2, 30, 1, "i", lit: awake)
        rect(x + 6, y + 3, 30, 1, "u", lit: awake)
        rect(x + 6, y + 4, 30, 14, "n", lit: awake)
        rect(x + 20, y + 2, 1, 1, "b", lit: awake)
        rect(x + 6, y + 19, 30, 1, "b", lit: awake)

        if awake && screen {
            // A 7px-tall menu strip holds a right-aligned, 7x7 status icon.
            // Below it: wallpaper, one small window and a separate dock.
            rect(x + 7, y + 4, 28, 7, "d")
            rect(x + 8, y + 4, 7, 1, "l")
            rect(x + 16, y + 4, 6, 1, "b")
            statusIcon(x + 28, y + 4)
            rect(x + 8, y + 12, 6, 1, "u")
            rect(x + 8, y + 13, 13, 7, "b")
            rect(x + 9, y + 14, 11, 2, "u")
            rect(x + 10, y + 14, 1, 1, "l")
            rect(x + 10, y + 17, 8, 1, "n")
            rect(x + 10, y + 19, 6, 1, "n")
            rect(x + 11, y + 21, 20, 2, "d")
            rect(x + 11, y + 21, 20, 1, "u")
            for column in 0..<4 {
                rect(x + 12 + column * 5, y + 21, 2, 1, column == 0 ? "l" : "s")
            }
        }

        // Hinge, keyboard deck, two rows of keys and a separate trackpad.
        rect(x + 4, y + 21, 34, 1, "b", lit: awake)
        rect(x + 14, y + 21, 14, 1, "n", lit: awake)
        for (dx, dy, width) in [(5, 22, 32), (3, 23, 36), (1, 24, 40), (0, 25, 42)] {
            rect(x + dx, y + dy, width, 1, "s", lit: awake)
        }
        rect(x + 5, y + 22, 32, 1, "i", lit: awake)
        rect(x + 7, y + 23, 28, 1, "u", lit: awake)
        for column in 0..<10 {
            rect(x + 8 + column * 3, y + 23, 1, 1, "d", lit: awake)
        }
        for column in 0..<9 {
            rect(x + 7 + column * 3, y + 24, 1, 1, "d", lit: awake)
        }
        rect(x + 13, y + 25, 5, 1, "b", lit: awake)
        rect(x + 19, y + 25, 5, 1, "b", lit: awake)
        rect(x, y + 26, 42, 1, "d", lit: awake)
        rect(x + 4, y + 26, 34, 1, "u", lit: awake)
        rect(x + 17, y + 26, 8, 1, "n", lit: awake)
    }

    func battery(_ x: Int, _ y: Int, level: Int, lit: Bool = true) {
        panel(x, y, 29, 15, lit: lit)
        rect(x + 29, y + 5, 2, 5, "d", lit: lit)
        for index in 0..<4 {
            rect(x + 3 + index * 6, y + 4, 4, 7, index < level ? "l" : "u", lit: lit)
        }
    }

    func clock(_ x: Int, _ y: Int, phase: Int, lit: Bool = true) {
        panel(x, y, 21, 21, lit: lit)
        rect(x + 10, y + 3, 1, 2, "s", lit: lit)
        rect(x + 10, y + 16, 1, 2, "s", lit: lit)
        rect(x + 3, y + 10, 2, 1, "s", lit: lit)
        rect(x + 16, y + 10, 2, 1, "s", lit: lit)
        rect(x + 10, y + 6, 1, 5, "i", lit: lit)
        rect(x + (phase == 2 ? 6 : 10), y + 10, 5, 1, "l", lit: lit)
        rect(x + 9, y - 2, 3, 2, "b", lit: lit)
    }

    func plug(_ x: Int, _ y: Int, connected: Bool) {
        panel(x, y, 14, 17, lit: connected)
        rect(x + 4, y - 3, 2, 3, "i", lit: connected)
        rect(x + 9, y - 3, 2, 3, "i", lit: connected)
        rect(x + 6, y + 17, 2, 5, "d", lit: connected)
        rect(x - 5, y + 21, 12, 2, "d", lit: connected)
        glyph(x + 4, y + 5, ["..##", ".##.", "####", ".##.", "##.."], "l", lit: connected)
    }

    func window(_ x: Int, _ y: Int, progress: Int, lit: Bool = true) {
        panel(x, y, 32, 22, lit: lit)
        rect(x + 2, y + 2, 28, 3, "d", lit: lit)
        for dot in 0..<3 { rect(x + 4 + dot * 3, y + 3, 1, 1, "i", lit: lit) }
        rect(x + 5, y + 8, 12, 1, "s", lit: lit)
        rect(x + 5, y + 11, 21, 1, "b", lit: lit)
        rect(x + 5, y + 16, 22, 2, "u", lit: lit)
        rect(x + 5, y + 16, min(22, max(0, progress)), 2, "l", lit: lit)
    }

    func packets(_ x: Int, _ y: Int, frame: Int, lit: Bool = true) {
        for index in 0..<8 { rect(x + index * 3, y, 1, 1, "d", lit: lit) }
        rect(x + (frame % 8) * 3, y - 1, 2, 3, "i", lit: lit)
    }

    func lock(_ x: Int, _ y: Int, locked: Bool) {
        panel(x, y + 7, 17, 13, lit: locked)
        rect(x + (locked ? 4 : 11), y, 9, 2, "l", lit: locked)
        rect(x + (locked ? 3 : 17), y + 2, 2, 6, "s", lit: locked)
        rect(x + 12, y + 2, 2, 6, "s", lit: locked)
        rect(x + 8, y + 11, 2, 4, "i", lit: locked)
    }

    func wifi(_ x: Int, _ y: Int, lit: Bool) {
        glyph(x, y, ["...########...", ".##........##.", "#............#", "....######....", "...#......#...", "......##......", ".....#..#.....", "......##......"], "l", lit: lit)
    }

    func drive(_ x: Int, _ y: Int, mounted: Bool) {
        panel(x, y, 19, 24, lit: mounted)
        rect(x + 4, y + 4, 11, 12, "d", lit: mounted)
        rect(x + 5, y + 5, 9, 1, "l", lit: mounted)
        rect(x + 5, y + 19, 6, 1, "u", lit: mounted)
        rect(x + 13, y + 19, 2, 2, mounted ? "w" : "b", lit: mounted)
    }

    // Onboarding uses a taller stage, with all screen content inside its bezel.
    // Props share a one-pixel outline and a consistent front-facing perspective.
    func tourLaptop(_ x: Int, _ y: Int, closed: Bool = false, lit: Bool = true) {
        rect(x + 1, y + 40, 60, 2, "n", lit: false)
        if closed {
            rect(x + 5, y + 30, 50, 2, "i", lit: lit)
            rect(x + 2, y + 32, 56, 3, "s", lit: lit)
            rect(x, y + 35, 60, 3, "d", lit: lit)
            rect(x + 2, y + 35, 56, 1, "l", lit: lit)
            rect(x + 25, y + 37, 10, 1, "n", lit: lit)
            return
        }
        panel(x + 5, y, 50, 32, lit: lit)
        rect(x + 7, y + 3, 46, 26, "n", lit: lit)
        rect(x + 28, y + 1, 4, 1, "d", lit: lit)
        if lit {
            // A quiet desktop: one window, no Dock or wallpaper ornaments.
            // The shared 9×7 miniature is reduced on the device-pixel grid;
            // its menu strip stays entirely inside the recessed glass.
            let cell = max(1, floor(unit * deviceScale / 2)) / deviceScale
            let iconWidth = Int(ceil(9 * cell / unit))
            let iconHeight = Int(ceil(7 * cell / unit))
            rect(x + 8, y + 4, 44, iconHeight + 2, "d")
            rect(x + 10, y + 5, 6, 1, "i")
            let iconOrigin = CGPoint(x: origin.x + CGFloat(x + 51 - iconWidth) * unit,
                                     y: origin.y + CGFloat(y + 5) * unit)
            for (row, line) in BrandIcon.miniatureStatusPixelRows.enumerated() {
                for (column, pixel) in line.enumerated() where pixel != "." {
                    let box = CGRect(x: iconOrigin.x + CGFloat(column) * cell,
                                     y: iconOrigin.y + CGFloat(row) * cell,
                                     width: cell, height: cell)
                    if let color = on[pixel == "1" ? "w" : "l"] {
                        context.fill(Path(box), with: .color(color),
                                     style: FillStyle(antialiased: false))
                    }
                }
            }
            rect(x + 14, y + 16, 28, 10, "b")
            rect(x + 15, y + 17, 26, 2, "u")
            rect(x + 18, y + 22, 15, 1, "i")
        }
        rect(x + 4, y + 32, 52, 1, "u", lit: lit)
        rect(x + 2, y + 33, 56, 3, "s", lit: lit)
        for row in 0..<2 {
            for key in 0..<12 { rect(x + 8 + key * 4, y + 33 + row * 2, 2, 1, "d", lit: lit) }
        }
        rect(x, y + 36, 60, 3, "b", lit: lit)
        rect(x + 23, y + 36, 14, 2, "i", lit: lit)
        rect(x + 2, y + 39, 56, 1, "u", lit: lit)
    }

    func tourToggle(_ x: Int, _ y: Int, enabled: Bool) {
        rect(x + 1, y, 13, 6, enabled ? "b" : "d", lit: enabled)
        rect(x, y + 1, 15, 4, enabled ? "b" : "d", lit: enabled)
        rect(x + (enabled ? 9 : 2), y + 1, 4, 4, "w", lit: enabled)
    }

    func tourCursor(_ x: Int, _ y: Int) {
        glyph(x, y, ["#......", "##.....", "###....", "####...", "#####..", "###....", "#.##...", "...##.."], "w")
    }

    func tourScene(_ kind: GuideSceneKind, beat: Int, frame: Int) {
        let selected = beat > 0
        switch kind {
        case .welcome:
            tourLaptop(14, 11)
            // One enlarged menu detail, not a second miniature desktop.
            panel(96, 12, 49, 34)
            rect(98, 14, 45, 9, "d")
            rect(101, 17, 9, 1, "i")
            statusIcon(132, 15)
            rect(102, 28, 36, 11, selected ? "b" : "n")
            rect(106, 33, 17, 1, "i")
            if beat == 0 { tourCursor(137, 20) }
            else { tourCursor(131, 33) }
        case .awakeModes:
            tourLaptop(12, 10, lit: beat != 2)
            tourLaptop(89, 10, closed: true, lit: beat > 0)
            // Sun = lid-open hold; a shield = independently armed closed lid.
            glyph(37, 4, ["..#..", "#.#.#", ".###.", "#.#.#", "..#.."], "l", lit: beat != 2)
            glyph(114, 12, ["#######", "#.....#", "#..#..#", "#.###.#", "#..#..#", ".#...#.", "..###.."], "l", lit: selected)
            // Independent states, with no animated traffic between the lids.
            if beat == 2 { moon(38, 25) }
        case .components:
            // Three complete component cards, not indistinguishable tiles.
            for index in 0..<3 {
                let x = 16 + index * 44
                let enabled = selected && index != 1
                panel(x, 10, 39, 37, lit: enabled)
                switch index {
                case 0: glyph(x + 15, 16, ["..###..", ".##....", "##.....", "##.....", ".##...#", "..####."], "l", lit: enabled)
                case 1: glyph(x + 14, 16, [".#####.", "##...##", "#..#..#", "#..##.#", "#.....#", ".#####."], "l", lit: enabled)
                default: glyph(x + 14, 16, [".#####.", "##...##", "#.....#", "#######", "..#.#..", ".##.##."], "l", lit: enabled)
                }
                rect(x + 7, 28, 25, 1, "i", lit: enabled)
                tourToggle(x + 12, 36, enabled: enabled)
            }
            if !selected { tourCursor(43, 41) }
        case .permissions:
            tourLaptop(12, 10)
            panel(94, 9, 53, 39, lit: selected)
            // Access prompt: shield, explanation, and an explicit choice.
            glyph(99, 14, ["#######", "#.....#", "#..#..#", "#..#..#", "#.....#", ".#...#.", "..###.."], "l", lit: selected)
            rect(111, 15, 28, 2, "i", lit: selected)
            rect(99, 27, 34, 1, "s", lit: selected)
            rect(113, 36, 26, 7, "b", lit: selected)
            rect(119, 39, 14, 1, "w", lit: selected)
            if beat == 2 { tourCursor(135, 40) }
        case .ready:
            tourLaptop(17, 10)
            panel(96, 10, 47, 37)
            // The actual brand mark above a single, deliberately off switch.
            wakely(113, 15)
            tourToggle(111, 33, enabled: false)
            // Neutral state, never a fake armed or permission-granted result.
            if beat == 2 { tourCursor(133, 37) }
        default: break
        }
    }

    func scene(_ kind: GuideSceneKind, beat: Int, frame: Int) {
        if [.welcome, .awakeModes, .components, .permissions, .ready].contains(kind) {
            tourScene(kind, beat: beat, frame: frame)
            return
        }
        // Quiet shelf, edge screws, and three storyboard pips unify the scenes.
        rect(10, 35, 140, 1, "d", lit: false)
        rect(11, 36, 138, 1, "u", lit: false)
        for index in 0..<3 { rect(75 + index * 4, 38, 2, 1, index == beat ? "i" : "d", lit: index == beat) }
        let active = beat > 0
        let result = beat == 2
        let sleeping = (result && [.battery, .timer, .drive, .bluetooth, .sleep].contains(kind))
            || (kind == .reset && !result)
        let released = result && [.application, .wifi].contains(kind)
        let closed = kind == .awakeModes ? beat == 1 : (active && ![.keyboard, .permissions, .components, .ready, .welcome, .wifi, .schedule, .application].contains(kind))
        mac(19, 6, closed: closed, awake: !sleeping && !released && (active || kind == .welcome))
        if sleeping { moon(65, 12) }
        else if active { packets(66, 23, frame: frame, lit: true) }
        else { arrow(74, 21, lit: false) }

        switch kind {
        case .welcome:
            // A miniature desktop makes the actual entry point clear: the
            // Wakely eye sits in the menu bar, not in a Dock-style app window.
            panel(99, 5, 49, 28, lit: true)
            rect(101, 7, 45, 7, "d")
            rect(104, 8, 7, 1, "l")
            rect(114, 8, 5, 1, "b")
            statusIcon(138, 7, lit: true)
            if active {
                panel(119, 17, 26, 14, lit: true)
                rect(122, 19, 20, 3, "d")
                rect(123, 20, 13, 1, "i")
                rect(123, 25, 15, 1, "s")
                if result { check(132, 23) }
            } else {
                glyph(109, 19, ["#...", "##..", "###.", "####", "##..", "..#."], "i")
            }
        case .awakeModes:
            // Lid-open Keep Awake, then independently armed closed session.
            mac(104, 6, closed: beat != 0, awake: active)
            if result { check(78, 10) }
            else { wakely(78, 9, lit: active) }
        case .components:
            for row in 0..<2 {
                for col in 0..<3 {
                    let x = 99 + col * 14, y = 6 + row * 14
                    panel(x, y, 11, 11, lit: beat > 0 && row * 3 + col < beat * 2)
                    rect(x + 4, y + 4, 3, 3, "l", lit: beat > 0 && row * 3 + col < beat * 2)
                }
            }
        case .permissions:
            panel(99, 6, 40, 26, lit: active)
            lock(104, 10, locked: !result)
            for row in 0..<3 {
                rect(127, 11 + row * 6, 7, 1, "b")
                if beat >= row { check(126, 10 + row * 6) }
            }
        case .ready:
            wakely(110, 7, lit: active)
            panel(99, 19, 39, 12, lit: active)
            if result { check(114, 22) }
            else { rect(104, 24, active ? 26 : 9, 2, "l", lit: active) }
        case .agents:
            window(101, 7, progress: result ? 22 : (active ? 8 + frame % 6 : 3))
            if result { check(137, 20) }
            else { glyph(138, 12, ["##..##", "######", ".####.", "..##.."], "l", lit: active) }
        case .display:
            panel(100, 6, 37, 24, lit: active)
            if active { wakely(113, 13) }
            rect(116, 30, 4, 3, "d", lit: active)
            rect(109, 33, 18, 1, "b", lit: active)
            if result { check(141, 13) }
        case .notification:
            window(99, 12, progress: result ? 22 : 7, lit: active)
            if active {
                panel(110, 5, 34, 10)
                wakely(113, 7)
                rect(126, 8, 14, 1, "l")
                rect(126, 11, result ? 14 : 7, 1, "b")
                if result { check(137, 25) }
            }
        case .light:
            panel(96, 7, 48, 24, lit: active)
            rect(98, 9, 44, 6, "d", lit: active)
            wakely(129, 9, lit: active)
            if result { check(114, 21) }
            else { rect(103, 21, active ? 22 : 10, 2, "b", lit: active) }
        case .reset:
            clock(104, 10, phase: beat, lit: result)
            if !result { moon(136, 12) }
            else { window(126, 12, progress: 9 + frame % 5) }
        case .keyboard:
            keyboard(100, 20, caps: active, lit: active)
            if active { wakely(109, 7) }
            if result { check(136, 21) }
        case .sound:
            glyph(105, 13, ["....##", "...###", "######", "######", "######", "...###", "....##"], "l", lit: active)
            if beat == 1 {
                glyph(115, 12, ["#...#", ".#...#", ".#...#", ".#...#", ".#...#", "#...#"], "s")
            }
            if result { check(125, 22) }
        case .lock:
            lock(108, 10, locked: active)
            if result {
                panel(133, 19, 19, 9)
                for dot in 0..<4 { rect(136 + dot * 3, 23, 1, 1, "i") }
            }
        case .battery:
            battery(102, 13, level: 4 - beat, lit: !result)
            rect(116, 10, 1, 3, "i", lit: !result)
            if result { moon(140, 9) }
        case .charger:
            plug(active ? 107 : 119, 11, connected: active)
            rect(65, 29, active ? 50 : 38, 2, "d", lit: active)
            if result { check(135, 13) }
        case .timer:
            clock(105, 10, phase: beat, lit: !result)
            if !result { rect(133, 25, 3, 4 - beat, "l") }
            else { moon(136, 11) }
        case .fan:
            panel(102, 7, 27, 27, lit: active)
            let alternating = active && frame % 4 >= 2
            glyph(109, 13, alternating
                  ? ["##......##", ".##....##.", "..##..##..", "...####...", "...####...", "..##..##..", ".##....##.", "##......##"]
                  : ["....##....", "....##....", "....##....", "##########", "##########", "....##....", "....##....", "....##...."], "l", lit: active)
            rect(136, 20 - beat * 4, 3, 10 + beat * 4, "s", lit: active)
            for tick in 0..<3 { rect(140, 14 + tick * 6, 3, 1, "b", lit: active) }
        case .drive:
            drive(109, 7, mounted: !result)
            rect(67, 29, 42, 1, "d", lit: !result)
            if result {
                glyph(135, 12, ["...#...", "..###..", ".#####.", "#######", ".......", "#######"], "l")
                check(135, 24)
            }
        case .bluetooth:
            glyph(111, 8, ["...#....", "...##...", "#..#.#..", ".#.#..#.", "..####..", "...##...", "..####..", ".#.#..#.", "#..#.#..", "...##...", "...#...."], "l", lit: !result)
            keyboard(100, 24, lit: !result)
            if result { rect(133, 14, 10, 2, "b", lit: false) }
        case .connection:
            window(106, 7, progress: active ? 15 : 0, lit: active)
            glyph(112, 15, ["#......", ".#.....", "..#....", ".#.....", "#...###"], "i", lit: active)
            if result { clock(136, 16, phase: 1, lit: false) }
        case .shortcut:
            for index in 0..<3 {
                panel(98 + index * 17, 9 + index * 5, 13, 12, lit: beat >= index)
                if beat >= index { check(101 + index * 17, 12 + index * 5) }
                if index < 2 { rect(111 + index * 17, 17 + index * 5, 4, 1, "d", lit: active) }
            }
        case .application:
            window(104, 7, progress: result ? 0 : 16, lit: !result)
            if result { moon(140, 13) }
            else { wakely(115, 14, lit: active) }
        case .wifi:
            wifi(104, 7, lit: active && !result)
            plug(131, 13, connected: !result)
            if beat == 1 { check(107, 23) }
            if result { rect(104, 23, 14, 2, "b", lit: false) }
        case .schedule:
            panel(98, 6, 29, 27, lit: active)
            rect(100, 9, 25, 4, "d", lit: active)
            for row in 0..<3 {
                for col in 0..<4 { rect(102 + col * 6, 16 + row * 5, 3, 2, row == 1 && col == beat ? "i" : "b", lit: active) }
            }
            plug(136, 14, connected: true)
            if result { check(108, 8) }
        case .sleep:
            window(103, 7, progress: result ? 22 : (active ? 14 + frame % 4 : 5), lit: !result)
            if result { check(114, 17); moon(139, 9) }
        }
    }
}
