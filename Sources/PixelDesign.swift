import SwiftUI

/// Eager, identity-preserving layout for the small component catalog. Keeping
/// cards alive lets SwiftUI interpolate positions during search/filter changes.
struct ComponentGridLayout: Layout {
    var spacing: CGFloat = 12

    private func metrics(width requestedWidth: CGFloat, subviews: Subviews) -> (Int, CGFloat, [CGFloat]) {
        // SwiftUI probes custom layouts with zero, unspecified AND infinite sizes.
        // Never convert an unbounded proposal to Int.
        let width = requestedWidth.isFinite ? max(0, requestedWidth) : 720
        let columns = width >= 630 + 2 * spacing ? 3 : (width >= 420 + spacing ? 2 : 1)
        let cell = max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        var rows: [CGFloat] = []
        for index in subviews.indices {
            let row = index / columns
            if row == rows.count { rows.append(0) }
            rows[row] = max(rows[row], subviews[index].sizeThatFits(ProposedViewSize(width: cell, height: nil)).height)
        }
        return (columns, cell, rows)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let requested = proposal.width ?? 720
        let width = requested.isFinite ? max(0, requested) : 720
        let (_, _, rows) = metrics(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(0, +) + CGFloat(max(0, rows.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (columns, cell, rows) = metrics(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for index in subviews.indices {
            let row = index / columns
            if index > 0 && index % columns == 0 { y += rows[row - 1] + spacing }
            subviews[index].place(at: CGPoint(x: bounds.minX + CGFloat(index % columns) * (cell + spacing), y: y),
                                 anchor: .topLeading, proposal: ProposedViewSize(width: cell, height: rows[row]))
        }
    }
}

/// Small bitmap typography for display labels. Descriptions stay native text
/// for legibility, selection, localization and accessibility.
struct PixelText: View {
    let text: String
    var pixel: CGFloat = 2
    var color: Color = Theme.ink

    private var letters: [Character] { Array(text.uppercased()) }
    private var width: CGFloat { CGFloat(max(0, letters.count * 6 - 1)) * pixel }

    var body: some View {
        Canvas { context, _ in
            for (index, letter) in letters.enumerated() {
                let rows = Self.glyphs[letter] ?? Self.glyphs["?"]!
                for (y, row) in rows.enumerated() {
                    for (x, bit) in row.enumerated() where bit == "1" {
                        let rect = CGRect(x: CGFloat(index * 6 + x) * pixel,
                                          y: CGFloat(y) * pixel, width: pixel, height: pixel)
                        context.fill(Path(rect), with: .color(color), style: FillStyle(antialiased: false))
                    }
                }
            }
        }
        .frame(width: width, height: 7 * pixel)
        .accessibilityLabel(text)
    }

    private static let glyphs: [Character: [String]] = [
        "A": ["01110","10001","10001","11111","10001","10001","10001"],
        "B": ["11110","10001","10001","11110","10001","10001","11110"],
        "C": ["01111","10000","10000","10000","10000","10000","01111"],
        "D": ["11110","10001","10001","10001","10001","10001","11110"],
        "E": ["11111","10000","10000","11110","10000","10000","11111"],
        "F": ["11111","10000","10000","11110","10000","10000","10000"],
        "G": ["01111","10000","10000","10111","10001","10001","01111"],
        "H": ["10001","10001","10001","11111","10001","10001","10001"],
        "I": ["11111","00100","00100","00100","00100","00100","11111"],
        "J": ["00111","00010","00010","00010","10010","10010","01100"],
        "K": ["10001","10010","10100","11000","10100","10010","10001"],
        "L": ["10000","10000","10000","10000","10000","10000","11111"],
        "M": ["10001","11011","10101","10101","10001","10001","10001"],
        "N": ["10001","11001","10101","10011","10001","10001","10001"],
        "O": ["01110","10001","10001","10001","10001","10001","01110"],
        "P": ["11110","10001","10001","11110","10000","10000","10000"],
        "Q": ["01110","10001","10001","10001","10101","10010","01101"],
        "R": ["11110","10001","10001","11110","10100","10010","10001"],
        "S": ["01111","10000","10000","01110","00001","00001","11110"],
        "T": ["11111","00100","00100","00100","00100","00100","00100"],
        "U": ["10001","10001","10001","10001","10001","10001","01110"],
        "V": ["10001","10001","10001","10001","10001","01010","00100"],
        "W": ["10001","10001","10001","10101","10101","10101","01010"],
        "X": ["10001","10001","01010","00100","01010","10001","10001"],
        "Y": ["10001","10001","01010","00100","00100","00100","00100"],
        "Z": ["11111","00001","00010","00100","01000","10000","11111"],
        "0": ["01110","10001","10011","10101","11001","10001","01110"],
        "1": ["00100","01100","00100","00100","00100","00100","01110"],
        "2": ["01110","10001","00001","00010","00100","01000","11111"],
        "3": ["11110","00001","00001","01110","00001","00001","11110"],
        "4": ["00010","00110","01010","10010","11111","00010","00010"],
        "5": ["11111","10000","10000","11110","00001","00001","11110"],
        "6": ["01110","10000","10000","11110","10001","10001","01110"],
        "7": ["11111","00001","00010","00100","01000","01000","01000"],
        "8": ["01110","10001","10001","01110","10001","10001","01110"],
        "9": ["01110","10001","10001","01111","00001","00001","01110"],
        " ": ["00000","00000","00000","00000","00000","00000","00000"],
        "-": ["00000","00000","00000","11111","00000","00000","00000"],
        ".": ["00000","00000","00000","00000","00000","00110","00110"],
        ":": ["00000","00110","00110","00000","00110","00110","00000"],
        "/": ["00001","00001","00010","00100","01000","10000","10000"],
        "+": ["00000","00100","00100","11111","00100","00100","00000"],
        "?": ["01110","10001","00001","00010","00100","00000","00100"]
    ]
}
