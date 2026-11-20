import SwiftUI

/// A rectangle with stepped, cut corners. This is the one shape the interface
/// uses: pixel UI has no soft radii, only deliberate corner notches.
struct PixelShape: InsettableShape {
    var cut: CGFloat = 3
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> PixelShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let c = max(0, min(cut, min(rect.width, rect.height) / 3))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
        path.closeSubpath()
        return path
    }
}

extension View {
    /// Panel chrome: flat fill and one-pixel border. Elevation is expressed by
    /// surface tone and spacing, never rectangular offset shadows.
    func pixelPanel(fill: Color,
                    border: Color,
                    cut: CGFloat = 3,
                    shadow: Bool = false,
                    shadowOffset: CGFloat = 2) -> some View {
        let _ = (shadow, shadowOffset)
        return self
            .background(PixelShape(cut: cut).fill(fill))
            .overlay(PixelShape(cut: cut).strokeBorder(border, lineWidth: 1))
    }
}

/// A flat, square-cornered button with a hard shadow that collapses when the
/// button is pressed. Used for every ordinary action in the window; cards and
/// sidebar rows opt out with `.plain`.
struct PixelButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        PixelButtonChrome(configuration: configuration, prominent: prominent)
    }
}

private struct PixelButtonChrome: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isFocused) private var focused
    @State private var hover = false

    private var fill: Color {
        if configuration.isPressed {
            return prominent ? Theme.gold.opacity(0.82) : Theme.controlPressed
        }
        if prominent { return hover ? Theme.goldSoft : Theme.gold }
        return hover ? Theme.controlHover : Theme.control
    }

    var body: some View {
        configuration.label
            .font(WakelyType.body(12, .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(prominent ? Theme.accentInk : Theme.ink)
            .background(PixelShape(cut: 2).fill(fill))
            .overlay(PixelShape(cut: 2)
                .strokeBorder(focused ? Theme.gold
                              : (prominent ? Theme.goldSoft.opacity(0.85)
                                 : (hover ? Theme.cardHoverBorder : Theme.strokeHover)),
                              lineWidth: focused ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
            .opacity(isEnabled ? 1 : 0.75)
    }
}

/// A faint checkerboard, used behind the content to give the flat dark panels
/// a hand-placed pixel texture without reducing text contrast.
struct PixelDither: View {
    var step: CGFloat = 4
    var opacity: Double = 0.010

    var body: some View {
        Canvas { context, size in
            let color = Theme.dither.opacity(opacity)
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : step
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: step, height: step)),
                                 with: .color(color))
                    x += step * 2
                }
                y += step
                row += 1
            }
        }
        .allowsHitTesting(false)
    }
}

/// Pixel checkbox used by the weekday row: a small square that fills with the
/// accent colour, not a native rounded button.
struct PixelCheckToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
                .font(WakelyType.body(11.5, .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .foregroundStyle(configuration.isOn ? Theme.accentText : Theme.textSecondary)
                .background(PixelShape(cut: 2)
                    .fill(configuration.isOn ? Theme.gold.opacity(0.35) : Theme.secondary)
                    .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: configuration.isOn))
                .overlay(PixelShape(cut: 2)
                    .strokeBorder(configuration.isOn ? Theme.gold : Theme.stroke, lineWidth: 1)
                    .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: configuration.isOn))
        }
        .buttonStyle(.plain)
    }
}

/// Label plus the pixel switch, so native `Toggle` rows match the cards.
struct PixelSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            Button {
                configuration.isOn.toggle()
            } label: {
                configuration.label
                    .font(WakelyType.body(12.5, .medium))
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            WakelySwitch(isOn: configuration.isOn) { configuration.isOn.toggle() }
        }
    }
}

/// A menu picker with a pixel bezel instead of the native rounded one.
struct PixelMenu<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(label: String, value: Value)]

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(WakelyType.body(13, .medium))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Menu {
                ForEach(options.indices, id: \.self) { index in
                    Button(options[index].label) { selection = options[index].value }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentLabel).font(WakelyType.body(13, .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(PixelShape(cut: 2).fill(Theme.chipHover))
                .overlay(PixelShape(cut: 2).strokeBorder(Theme.strokeHover, lineWidth: 1))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var currentLabel: String {
        options.first(where: { $0.value == selection })?.label
            ?? options.first?.label ?? "—"
    }
}

/// A labelled slider. Pointer position, displayed value and saved setting are
/// committed together; there is no counting queue after the mouse is released.
struct PixelStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var suffix: String = ""
    var note: String = ""
    @State private var revision = 0

    private var domain: InlineValueDomain { .linear(range, step: max(1, step)) }
    private var digits: String { "\(value)\(suffix)" }

    var body: some View {
        let _ = revision
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(label)
                    .font(WakelyType.body(13, .medium))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Text(digits)
                    .font(WakelyType.mono(13, .semibold))
                    .fixedSize()
                    .frame(minWidth: 62, alignment: .trailing)
                if !note.isEmpty {
                    Text(note)
                        .font(WakelyType.body(13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Slider(value: Binding(
                get: { Double(domain.clamp(value)) },
                set: { commit(Int($0.rounded())) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(max(1, step)))
                .tint(Theme.gold)
                .accessibilityLabel(label)
                .accessibilityValue(digits)
        }
        .transaction { $0.animation = nil }
    }

    private func commit(_ candidate: Int) {
        let next = domain.value(at: domain.index(of: candidate))
        guard next != value else { return }
        value = next
        revision &+= 1
    }
}
