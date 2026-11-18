import SwiftUI
import AppKit
import CoreText

/// A paragraph with a live control inside it.
///
/// The sentence flows as normal wrapped text; one token is replaced by a chip
/// carrying ‹ value ›, so the explanation and the setting are the same thing
/// rather than a paragraph followed by a control panel. Interactive labels
/// update atomically so changing their length cannot leave departing glyphs.
struct InlineChipText: View {
    let text: String
    /// Token (including its braces, e.g. "{value}") mapped to its inline control.
    let chips: [String: AnyView]

    private enum Piece: Identifiable {
        case word(String, Int)
        case chip(String)
        /// A chip swallows the separator that used to follow its token, so the
        /// sentence needs one put back after it.
        case space(Int)
        var id: String {
            switch self {
            case .word(_, let index): return "w\(index)"
            case .chip(let key): return "c\(key)"
            case .space(let index): return "s\(index)"
            }
        }
    }

    private var pieces: [Piece] {
        var result: [Piece] = []
        var index = 0
        for token in text.split(separator: " ", omittingEmptySubsequences: false) {
            var word = String(token)
            // A chip may be followed by punctuation ("{drive};"), so the token
            // ends at its closing brace and whatever follows stays as text.
            if word.hasPrefix("{"), let close = word.firstIndex(of: "}") {
                let key = String(word[word.startIndex...close])
                if chips[key] != nil {
                    result.append(.chip(key))
                    word = String(word[word.index(after: close)...])
                    // Punctuation hugs the chip; ordinary words get the
                    // separator the token used to supply.
                    let punctuation = CharacterSet(charactersIn: ";,.:!?)]}")
                    let hugs = word.unicodeScalars.first.map { punctuation.contains($0) } ?? false
                    if word.isEmpty || !hugs {
                        result.append(.space(index))
                        index += 1
                    }
                    if word.isEmpty { continue }
                }
            }
            result.append(.word(word, index))
            index += 1
        }
        return result
    }

    var body: some View {
        FlowLayout(spacing: 0, lineSpacing: 5) {
            ForEach(pieces) { piece in
                switch piece {
                case .chip(let key): chips[key]
                case .word(let word, _):
                    Text(word + " ")
                        .layoutValue(key: InlinePunctuationKey.self,
                                     value: word.first.map { ";,.:!?)]}".contains($0) } ?? false)
                case .space:
                    Text(" ").layoutValue(key: InlineSeparatorKey.self, value: true)
                }
            }
        }
    }
}

private struct InlineSeparatorKey: LayoutValueKey {
    static let defaultValue = false
}
private struct InlinePunctuationKey: LayoutValueKey {
    static let defaultValue = false
}

/// Left-to-right layout that wraps on the available width and aligns every item
/// to the shared text baseline, so a chip sits in the sentence rather than on it.
struct FlowLayout: Layout {
    var spacing: CGFloat = 0
    var lineSpacing: CGFloat = 4

    private struct Metrics {
        var size: CGSize
        var baseline: CGFloat
        var separator: Bool
        var punctuation: Bool
    }

    private func metrics(_ subviews: Subviews) -> [Metrics] {
        subviews.map { subview in
            let size = subview.sizeThatFits(.unspecified)
            let baseline = subview.dimensions(in: .unspecified)[.firstTextBaseline]
            return Metrics(size: size, baseline: baseline.isFinite ? baseline : size.height,
                           separator: subview[InlineSeparatorKey.self],
                           punctuation: subview[InlinePunctuationKey.self])
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var height: CGFloat { ascent + descent }
    }
    private func lines(_ metrics: [Metrics], width: CGFloat) -> [Line] {
        var result: [Line] = []
        var line = Line()
        var pendingSeparators: [Int] = []
        var index = 0
        while index < metrics.count {
            if metrics[index].separator {
                pendingSeparators.append(index)
                index += 1
                continue
            }
            // Punctuation belongs to the previous token, never a line of its own.
            var group = [index]
            var next = index + 1
            while next < metrics.count, metrics[next].punctuation {
                group.append(next)
                next += 1
            }
            let separators = line.indices.isEmpty ? [] : pendingSeparators
            let addition = separators + group
            let addedWidth = addition.reduce(CGFloat.zero) { $0 + metrics[$1].size.width }
                + CGFloat(addition.count - (line.indices.isEmpty ? 1 : 0)) * spacing
            if !line.indices.isEmpty, line.width + addedWidth > width {
                result.append(line)
                line = Line()
            }
            let placed = (line.indices.isEmpty ? [] : separators) + group
            for itemIndex in placed {
                let item = metrics[itemIndex]
                if !line.indices.isEmpty { line.width += spacing }
                line.indices.append(itemIndex)
                line.width += item.size.width
                line.ascent = max(line.ascent, item.baseline)
                line.descent = max(line.descent, item.size.height - item.baseline)
            }
            pendingSeparators = []
            index = next
        }
        if !line.indices.isEmpty { result.append(line) }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(metrics(subviews), width: width)
        return CGSize(width: min(width, rows.map(\.width).max() ?? 0),
                      height: rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let items = metrics(subviews)
        var y = bounds.minY
        for line in lines(items, width: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let item = items[index]
                subviews[index].place(at: CGPoint(x: x, y: y + line.ascent - item.baseline),
                                      anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }
}

/// The single line box shared by a chip's chevrons and its morphing value.
///
/// `TorphText` draws through a `Canvas`, so it exposes no text baseline for the
/// arrows to align to; a baseline-based layout drifts the moment the font or
/// the value changes. So both sides get the same explicit height, and both draw
/// with the same top-leading Canvas convention inside it. The chevrons' ink is
/// then centred on the digits' cap band — in Pixel Operator ‹ and › run from
/// about 1.9 pt to the x-height, so their optical centre is a little above
/// where a centred `Text` would put them.
struct ChipLineBox {
    let valueFont: NSFont
    let arrowFont: NSFont

    /// The explicit height both the value and the arrows are laid out in.
    /// Never smaller than the 18 pt the chip was designed around, so a font
    /// with unusually tight metrics cannot shrink the control.
    var height: CGFloat { max(18, TorphLayout.lineHeight(valueFont)) }

    /// `TorphText`'s intrinsic line box is centred in `height` by its frame, so
    /// its canvas — and the digits' baseline — start this far down.
    private var valueTopInset: CGFloat {
        (height - TorphLayout.lineHeight(valueFont)) / 2
    }

    /// Baseline of the digits, from the top of the shared box. The chip hands
    /// this to `FlowLayout` so the sentence's words sit on the same baseline as
    /// the number, even though the number itself is drawn in a Canvas.
    var valueBaseline: CGFloat { valueTopInset + valueFont.ascender }

    /// Vertical centre of the digits' cap band, measured from the box top.
    var capCentre: CGFloat { valueBaseline - valueFont.capHeight / 2 }

    /// Where a chevron's top-leading origin goes so the middle of its ink lands
    /// on `capCentre`. Both the value and the arrows draw with a top-leading
    /// `Text` in a Canvas, so the same baseline convention applies to both.
    func arrowTop(for glyph: String) -> CGFloat {
        capCentre - (arrowFont.ascender - Self.inkBounds(glyph, font: arrowFont).midY)
    }

    /// Horizontal origin that centres the chevron's ink (not its advance) in
    /// the 13 pt tap target.
    func arrowLeft(for glyph: String, width: CGFloat) -> CGFloat {
        let ink = Self.inkBounds(glyph, font: arrowFont)
        return (width - ink.width) / 2 - ink.minX
    }

    /// The glyph's outline box in font space, relative to its baseline.
    private static func inkBounds(_ glyph: String, font: NSFont) -> CGRect {
        let fallback = CGRect(x: 0, y: font.capHeight / 2, width: 0, height: 0)
        var characters = Array(glyph.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count),
              glyphs[0] != 0 else {
            return fallback
        }
        let bounds = CTFontGetBoundingRectsForGlyphs(font as CTFont, .horizontal, &glyphs, nil, 1)
        guard bounds.width > 0, bounds.height > 0 else { return fallback }
        return bounds
    }
}

/// ‹ value › with the value morphing as it changes.
struct ValueChip: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let style: Style

    enum Style {
        case minutes
        case seconds
        case percent
        case hours

        func label(_ value: Int) -> String {
            switch self {
            case .minutes:
                if value >= 60, value % 60 == 0 {
                    let hours = value / 60
                    return "\(hours) hour\(hours == 1 ? "" : "s")"
                }
                return "\(value) minutes"
            case .hours: return "\(value) hours"
            case .seconds: return "\(value) seconds"
            case .percent: return "\(value)%"
            }
        }

        /// Spoken name for the quantity, so the value description names a unit.
        var accessibilityName: String {
            switch self {
            case .minutes, .hours, .seconds: return "Duration"
            case .percent: return "Percentage"
            }
        }
    }

    var body: some View {
        InlineValueChip(value: $value, domain: .linear(range, step: max(1, step)),
                        format: style.inlineFormat, accessibilityName: style.accessibilityName)
    }
}

/// A choice written into the sentence; clicking it opens the options.
///
/// A `Menu` cannot host the morphing label (its title is drawn by AppKit and a
/// Canvas inside it stays blank), so this uses a plain button and a popover.
struct OptionChip<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    @State private var open = false
    @State private var revision = 0
    @State private var hover = false

    private var font: NSFont { ClamType.bodyFont(12.5, .semibold) }
    private var lineHeight: CGFloat { max(18, TorphLayout.lineHeight(font)) }

    private var current: String {
        options.first { $0.value == selection }?.label ?? options.first?.label ?? ""
    }

    var body: some View {
        let _ = revision
        return Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(current)
                    .font(.custom(font.fontName, size: font.pointSize))
                    .fixedSize()
                    .foregroundStyle(Theme.ink)
                    .frame(height: lineHeight)
                Text("⌄")
                    .font(ClamType.body(11, .bold))
                    .foregroundStyle(Theme.gold)
                    .frame(height: lineHeight)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(PixelShape(cut: 2).fill(hover ? Theme.chipHover : Theme.chip))
            .overlay(PixelShape(cut: 2).strokeBorder(hover ? Theme.cardHoverBorder : Theme.strokeHover))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(options.indices, id: \.self) { index in
                    Button {
                        selection = options[index].value
                        revision &+= 1
                        open = false
                    } label: {
                        HStack(spacing: 8) {
                            Text(options[index].label)
                                .font(ClamType.body(12.5))
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 12)
                            if options[index].value == selection {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 190)
            .background(Theme.sidebar)
            .modifier(AppAppearanceModifier())
        }
        .accessibilityLabel(current)
    }
}
