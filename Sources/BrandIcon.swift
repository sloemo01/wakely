import AppKit

/// The Wakely pixel mark: a chunky 11x11 sun/eye. The full-colour application
/// icon is intentionally separate; only the macOS status item uses this outline.
enum BrandIcon {
    static let pixelRows = [
        ".....1.....",
        ".1...1...1.",
        "..1.....1..",
        "..1111111..",
        ".1.......1.",
        "1....1....1",
        ".1.......1.",
        "..1111111..",
        "..1.....1..",
        ".1...1...1.",
        ".....1....."
    ]

    /// The full-colour app mark, loaded from the bundled ICNS. Kept for About.
    static var appImage: NSImage? {
        if let url = Bundle.main.url(forResource: "Wakely", withExtension: "icns") {
            return NSImage(contentsOf: url)
        }
        return NSApp.applicationIconImage
    }

    /// A legible 7x7 reduction for tiny illustrated menu bars. It retains the
    /// real item's eye, rays, amber fill and dark outline without becoming a
    /// second oversized app logo on the laptop's desktop.
    static let miniatureStatusPixelRows = [
        "..#...#..",
        "...###...",
        ".#.....#.",
        "#...1...#",
        ".#.....#.",
        "...###...",
        "..#...#..",
    ]

    /// Padded grid: the 11x11 glyph plus one cell of room on every side for the
    /// outline, so a stroke never gets clipped at the image edge.
    private static let grid = 13

    /// Glyph cells in the padded 13x13 grid. The idle icon uses these directly,
    /// without an outline, so it stays a clean white mark.
    private static func glyphCells() -> [(x: Int, y: Int)] {
        var cells: [(x: Int, y: Int)] = []
        for (row, line) in pixelRows.enumerated() {
            for (column, character) in line.enumerated() where character == "1" {
                cells.append((column + 1, row + 1))
            }
        }
        return cells
    }

    private static func drawGlyph(_ cells: [(x: Int, y: Int)], color: NSColor,
                                  cell: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        color.setFill()
        for square in cells {
            NSRect(x: CGFloat(square.x) * cell + offsetX,
                   y: CGFloat(grid - 1 - square.y) * cell + offsetY,
                   width: cell, height: cell).fill()
        }
    }

    /// Draws the glyph with a one-device-pixel coloured edge. Offset copies of
    /// the glyph put the thin stroke outside the white interior; a full-cell
    /// dilation made the armed icon look visibly heavier than the idle mark.
    static func strokedImage(stroke: NSColor, fill: NSColor = .white,
                             cell: CGFloat = 2) -> NSImage {
        let side = CGFloat(grid) * cell
        let cells = glyphCells()
        let edge = cell / 4
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSGraphicsContext.current?.shouldAntialias = false
            for (dx, dy) in [(edge, 0), (-edge, 0), (0, edge), (0, -edge),
                             (edge, edge), (edge, -edge), (-edge, edge), (-edge, -edge)] {
                drawGlyph(cells, color: stroke, cell: cell, offsetX: dx, offsetY: dy)
            }
            drawGlyph(cells, color: fill, cell: cell, offsetX: 0, offsetY: 0)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Unarmed, inactive menu-bar icon: the white glyph alone. Drawing only the
    /// fill cells keeps the idle state monochrome, with no amber or black ring.
    static func idleStatusImage(cell: CGFloat = 2) -> NSImage {
        let side = CGFloat(grid) * cell
        let cells = glyphCells()
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSGraphicsContext.current?.shouldAntialias = false
            drawGlyph(cells, color: .white, cell: cell, offsetX: 0, offsetY: 0)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Menu-bar icon. Idle shows the white glyph only. Armed and active states
    /// put their colour on the outline while the interior stays white.
    static func statusImage(color: NSColor?) -> NSImage {
        guard let color else { return idleStatusImage() }
        return strokedImage(stroke: color, fill: .white, cell: 2)
    }
}
