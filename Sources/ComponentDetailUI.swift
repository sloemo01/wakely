import SwiftUI
import AppKit

/// Geometry shared by the grid card, the wide detail header and the morph
/// overlay. Every value is in the settings window's own point space, so the
/// overlay can place a surface with plain offsets instead of guessing frames.
enum ComponentCardMetrics {
    static let radius: CGFloat = 14
    static let pageInset: CGFloat = 28
    /// Top of the detail header, measured from the top of the components pane.
    /// 34 (back row top) + 24 (back row) + 16 (gap).
    static let headerTop: CGFloat = 74
    static let headerHeight: CGFloat = 112
    static let cardPadding: CGFloat = 20
    static let cardIconTop: CGFloat = 18
    static let iconSize: CGFloat = 56
    static let cardMinHeight: CGFloat = 160
    /// 18 icon top + 56 icon + 14 gap (the card's own VStack padding).
    static let cardTitleTop: CGFloat = 88

    static let headerIconX: CGFloat = 20
    static let headerIconTop: CGFloat = 28
    static let headerTextX: CGFloat = 92
    static let headerTitleTop: CGFloat = 30
    static let headerTaglineTop: CGFloat = 56
    static let headerSwitchTop: CGFloat = 46
    static let cardSwitchTop: CGFloat = 36
    static let switchWidth: CGFloat = 40
}

/// The settled wide header. It must match the morph overlay's expanded layer
/// exactly; both read every position from `ComponentCardMetrics`.
struct ComponentDetailHeader: View {
    let component: ComponentDefinition
    let isOn: Bool
    var onToggle: () -> Void

    private var accent: Color { Theme.accent(component.category) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: ComponentCardMetrics.radius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: ComponentCardMetrics.radius, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 1)
                )
                .overlay(
                    ComponentActivationStroke(
                        shape: RoundedRectangle(cornerRadius: ComponentCardMetrics.radius, style: .continuous),
                        isOn: isOn, color: accent.opacity(0.55))
                )

            ComponentSprite(componentID: component.icon, isOn: isOn, size: ComponentCardMetrics.iconSize)
                .offset(x: ComponentCardMetrics.headerIconX, y: ComponentCardMetrics.headerIconTop)

            Text(component.name)
                .font(ClamType.name(16))
                .tracking(-0.1)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .frame(width: headerTextWidth, alignment: .leading)
                .offset(x: ComponentCardMetrics.headerTextX, y: ComponentCardMetrics.headerTitleTop)

            Text(component.tagline)
                .font(ClamType.body(12.5))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .lineLimit(2)
                .frame(width: headerTextWidth, alignment: .leading)
                .offset(x: ComponentCardMetrics.headerTextX, y: ComponentCardMetrics.headerTaglineTop)

            ClamSwitch(isOn: isOn, action: onToggle)
                .offset(x: max(0, detailWidth - ComponentCardMetrics.cardPadding
                                  - ComponentCardMetrics.switchWidth),
                        y: ComponentCardMetrics.headerSwitchTop)
        }
        .frame(height: ComponentCardMetrics.headerHeight)
        .accessibilityElement(children: .contain)
    }

    /// The tagline never runs under the switch.
    private var headerTextWidth: CGFloat {
        max(120, detailWidth - ComponentCardMetrics.headerTextX - ComponentCardMetrics.cardPadding - ComponentCardMetrics.switchWidth - 16)
    }

    @Environment(\.detailHeaderWidth) private var detailWidth
}

private struct DetailHeaderWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 640
}

extension EnvironmentValues {
    var detailHeaderWidth: CGFloat {
        get { self[DetailHeaderWidthKey.self] }
        set { self[DetailHeaderWidthKey.self] = newValue }
    }
}

/// The in-window detail route: a breadcrumb, the wide header and the sentence
/// with its inline controls. It replaces the old narrow modal sheet; the
/// window chrome, sidebar and page title stay where they were.
struct ComponentDetailPage<Content: View>: View {
    let component: ComponentDefinition
    let isOn: Bool
    var onBack: () -> Void
    var onToggle: () -> Void
    var showsHeader: Bool = true
    var allowsBackShortcut: Bool = true
    /// Destination content arrives late during the morph. Keeping these
    /// separate from the page background avoids the old whole-page fade.
    var contentProgress: Double = 1
    var navigationProgress: Double = 1
    var backgroundProgress: Double = 1
    @ViewBuilder var content: Content

    @State private var backHover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("All Components").font(ClamType.body(12.5, .medium))
                    }
                    .foregroundStyle(backHover ? Theme.ink : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 24)
                .onHover { backHover = $0 }
                .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: backHover)
                .keyboardShortcut(.cancelAction)
                .disabled(!allowsBackShortcut)
                .padding(.top, 34)
                .padding(.leading, ComponentCardMetrics.pageInset)
                .opacity(navigationProgress)

                let width = max(320, proxy.size.width - ComponentCardMetrics.pageInset * 2)
                ComponentDetailHeader(component: component, isOn: isOn, onToggle: onToggle)
                    .environment(\.detailHeaderWidth, width)
                    .opacity(showsHeader ? 1 : 0)
                    .frame(width: width)
                    .padding(.top, 16)
                    .padding(.horizontal, ComponentCardMetrics.pageInset)

                EdgeScrollView(topFade: 24, bottomFade: 68) {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, ComponentCardMetrics.pageInset)
                    .padding(.top, 24)
                    .padding(.bottom, 96)
                }
                .scrollIndicators(.hidden)
                .opacity(contentProgress)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.window.opacity(backgroundProgress))
            .onExitCommand(perform: onBack)
        }
    }
}

struct CardMorphSource: Equatable {
    let componentID: String
    let frame: CGRect
}

/// Collects each card's frame in the components-canvas space. Cards are
/// reported even while a detail page covers them, so a return always has a
/// real destination.
struct ComponentCardFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Hosts one morph. A linear animation drives `progress`; the geometry model
/// applies the real opening/closing curve, so easing is defined in one place.
struct MorphPresenter: View {
    let component: ComponentDefinition
    let isOn: Bool
    let canvas: CGSize
    let source: CGRect
    let destination: CGRect
    let direction: CardMorphDirection
    @Binding var progress: Double
    var onFinished: () -> Void

    @State private var started = false
    @State private var finished = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var duration: Double {
        CardMorphGeometry(source: source, destination: destination, direction: direction).duration
    }

    var body: some View {
        CardMorphOverlay(component: component,
                         isOn: isOn,
                         canvas: canvas,
                         source: source,
                         destination: destination,
                         direction: direction,
                         progress: reduceMotion ? 1 : progress,
                         dimsCatalog: false)
        .allowsHitTesting(false)
        .onAppear(perform: start)
        .onChange(of: reduceMotion) { _, reduced in
            if reduced, started, !finished { settleImmediately() }
        }
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        onFinished()
    }

    private func settleImmediately() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { progress = 1 }
        complete()
    }

    private func start() {
        guard !started else { return }
        started = true
        if reduceMotion { settleImmediately(); return }
        // Completion belongs to the rendered animation, not a second timer
        // started before the overlay has even mounted.
        withAnimation(.linear(duration: duration),
                      completionCriteria: .removed) {
            progress = 1
        } completion: {
            complete()
        }
    }
}

/// The floating surface that carries the card between the grid and the header.
/// Progress is animatable data, so AppKit drives every track per frame without
/// a timer or a second animation transaction.
struct CardMorphOverlay: View, Animatable {
    let component: ComponentDefinition
    let isOn: Bool
    let canvas: CGSize
    let source: CGRect
    let destination: CGRect
    let direction: CardMorphDirection

    var progress: Double
    var dimsCatalog: Bool = true
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    private var geometry: CardMorphGeometry {
        CardMorphGeometry(source: source, destination: destination, direction: direction)
    }

    var body: some View {
        let g = geometry
        // Semantic progress is 0 at the card and 1 at the header in both
        // directions. Closing lowers the same value, so no ghost content or
        // second endpoint animation is introduced.
        let p = CardMorphGeometry.clamp01(progress)
        let frame = g.surfaceFrame(presentation: p)
        let radius = g.cornerRadius(presentation: p)
        // The analytic presentation spring owns the velocity and easing. A
        // second direction-specific curve would jump on mid-flight reversal.
        let spatial = p
        ZStack(alignment: .topLeading) {
            Color.black
                .opacity(dimsCatalog ? 0.42 * g.catalogDim(presentation: p) : 0)
                .frame(width: canvas.width, height: canvas.height)

            surface(frame: frame, radius: radius, p: spatial)
                .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Theme.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(isOn ? Theme.accent(component.category).opacity(0.55) : Theme.stroke,
                                      lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .offset(x: frame.minX, y: frame.minY)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .contentShape(Rectangle())
        // The travelling surface is visual only. Reversal and route commands
        // belong to the page/window chrome, never to stale hit targets in it.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func surface(frame: CGRect, radius: CGFloat, p: Double) -> some View {
        // One title and tagline move with the surface. Duplicate text layers
        // fading through one another made the handoff look like a blink.
        let iconTop = lerp(ComponentCardMetrics.cardIconTop, ComponentCardMetrics.headerIconTop, p)
        let switchTop = lerp(ComponentCardMetrics.cardSwitchTop, ComponentCardMetrics.headerSwitchTop, p)
        let compactWidth = max(80, source.width - ComponentCardMetrics.cardPadding * 2)
        let expandedTextWidth = max(120, destination.width - ComponentCardMetrics.headerTextX
            - ComponentCardMetrics.cardPadding - ComponentCardMetrics.switchWidth - 16 - 40)

        return ZStack(alignment: .topLeading) {
            Text(component.name)
                .font(ClamType.name(lerp(15, 16, p)))
                .tracking(-0.1)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .frame(width: lerp(compactWidth, expandedTextWidth, p), alignment: .leading)
                .offset(x: lerp(ComponentCardMetrics.cardPadding, ComponentCardMetrics.headerTextX, p),
                        y: lerp(ComponentCardMetrics.cardTitleTop, ComponentCardMetrics.headerTitleTop, p))
            Text(component.tagline)
                .font(ClamType.body(12.5))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(2)
                .lineLimit(2)
                .frame(width: lerp(compactWidth, expandedTextWidth, p), alignment: .leading)
                .offset(x: lerp(ComponentCardMetrics.cardPadding, ComponentCardMetrics.headerTextX, p),
                        y: lerp(ComponentCardMetrics.cardTitleTop + 23, ComponentCardMetrics.headerTaglineTop, p))

            ComponentSprite(componentID: component.icon, isOn: isOn, size: ComponentCardMetrics.iconSize)
                .offset(x: ComponentCardMetrics.headerIconX, y: iconTop)

            ClamSwitch(isOn: isOn) {}
                .offset(x: max(0, frame.width - ComponentCardMetrics.cardPadding - ComponentCardMetrics.switchWidth),
                        y: switchTop)
                .allowsHitTesting(false)
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(max(0, min(1, t)))
    }
}
