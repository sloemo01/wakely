import SwiftUI
import AppKit

/// Anchors come from the real views, so the spotlight follows scrolling and resizing.
struct HighlightTourAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

extension View {
    func tourTarget(_ id: String) -> some View {
        transformAnchorPreference(key: HighlightTourAnchorKey.self, value: .bounds) { values, anchor in
            values[id] = anchor
        }
    }
}

private struct TourMask: Shape {
    let target: CGRect?
    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if let target { p.addRoundedRect(in: target, cornerSize: CGSize(width: 8, height: 8)) }
        return p
    }
}

/// Optional read-only layout observer for offscreen verification; unset in the app.
@MainActor
enum HighlightTourLayoutProbe {
    struct Sample {
        let step: HighlightTourStep
        let target: CGRect?
        let coach: CGRect
        let viewport: CGRect
    }
    static var observe: ((Sample) -> Void)?
}

private struct TourCoachHeight: PreferenceKey {
    static var defaultValue: CGFloat = 220
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The underlying UI remains visually unchanged and inert. Only the spotlight's
/// safe navigation proxy or a local-value copy of the REAL inline control accepts input.
struct HighlightTourOverlay: View {
    let anchors: [String: Anchor<CGRect>]
    @ObservedObject private var guide = GuideCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || guide.previewReduceMotion }
    @State private var coachHeight: CGFloat = 220

    private var targetID: String? {
        if guide.creationPreviewOpened {
            if guide.currentTourStep == .addComponent { return "addComponentForm" }
            if guide.currentTourStep == .addScreen { return "addScreenForm" }
        }
        return guide.currentTourStep.target
    }

    var body: some View {
        GeometryReader { proxy in
            let raw = targetID.flatMap { anchors[$0] }.map { proxy[$0] }
            let viewport = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 8, dy: 8)
            let measured = raw.flatMap { rect -> CGRect? in
                let clipped = rect.intersection(viewport)
                return clipped.width > 8 && clipped.height > 8 ? clipped.insetBy(dx: -5, dy: -5) : nil
            }
            let width = min(380.0, max(260, proxy.size.width - 32))
            let origin = coachOrigin(target: measured, size: proxy.size, width: width)
            ZStack(alignment: .topLeading) {
                TourMask(target: measured)
                    .fill(Theme.scrim.opacity(0.65), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture { } // Outside clicks never enable the real controls.
                    .accessibilityHidden(true)

                if let measured {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Theme.goldSoft, lineWidth: 2)
                        .frame(width: measured.width, height: measured.height)
                        .offset(x: measured.minX, y: measured.minY)
                        .allowsHitTesting(false).accessibilityHidden(true)

                    if guide.currentTourStep == .inlineOption || guide.currentTourStep == .optionEditor {
                        TourPracticeValue()
                            .position(x: measured.midX, y: measured.midY)
                    } else if canActivateTarget {
                        Button(action: activateTarget) { Color.clear }
                            .buttonStyle(.plain)
                            .frame(width: measured.width, height: measured.height)
                            .offset(x: measured.minX, y: measured.minY)
                            .accessibilityLabel(targetActionLabel)
                    }
                }

                HighlightTourCoach(compact: proxy.size.height < 560)
                    .frame(width: width)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: TourCoachHeight.self, value: g.size.height)
                    })
                    .offset(x: origin.x, y: origin.y)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: guide.progress.step)
            .onPreferenceChange(TourCoachHeight.self) { coachHeight = $0 }
            .onAppear { report(target: measured, origin: origin, size: proxy.size, width: width) }
            .onChange(of: measured) { _, _ in report(target: measured, origin: origin, size: proxy.size, width: width) }
            .onChange(of: coachHeight) { _, _ in report(target: measured, origin: origin, size: proxy.size, width: width) }
        }
        .onExitCommand { guide.dismiss() }
    }

    private func report(target: CGRect?, origin: CGPoint, size: CGSize, width: CGFloat) {
        HighlightTourLayoutProbe.observe?(.init(step: guide.currentTourStep, target: target,
            coach: CGRect(origin: origin, size: CGSize(width: width, height: coachHeight)),
            viewport: CGRect(origin: .zero, size: size)))
    }

    private var canActivateTarget: Bool {
        [.welcome, .componentCard, .componentDetail, .addComponent, .addScreen].contains(guide.currentTourStep)
            && !guide.creationPreviewOpened
    }
    private var targetActionLabel: String {
        switch guide.currentTourStep {
        case .addComponent: return "Preview adding a component; no files are created"
        case .addScreen: return "Preview adding a screen; no files are created"
        default: return guide.currentTourStep.nextTitle
        }
    }
    private func activateTarget() {
        if guide.currentTourStep == .addComponent || guide.currentTourStep == .addScreen {
            HighlightTourNavigation.shared.previewCreation()
        } else { guide.next() }
    }
    private func coachOrigin(target: CGRect?, size: CGSize, width: CGFloat) -> CGPoint {
        let h = min(coachHeight, max(180, size.height - 24))
        let x: CGFloat
        let y: CGFloat
        if let target {
            // Small targets (a single card or inline value) leave room beside
            // them. Prefer that space so the coach never hides the demonstration.
            if target.maxX + width + 28 <= size.width {
                return CGPoint(x: target.maxX + 12,
                               y: min(max(12, target.minY), max(12, size.height - h - 12)))
            }
            if target.minX - width - 12 >= 16 {
                return CGPoint(x: target.minX - width - 12,
                               y: min(max(12, target.minY), max(12, size.height - h - 12)))
            }
            x = min(max(16, target.midX - width / 2), max(16, size.width - width - 16))
            if target.maxY + h + 26 <= size.height {
                y = target.maxY + 12
            } else if target.minY - h - 12 >= 12 {
                y = target.minY - h - 12
            } else {
                // Compact windows prefer a clear lower corner; Next always stays visible.
                y = max(12, size.height - h - 12)
            }
        } else {
            x = max(16, (size.width - width) / 2)
            y = max(12, (size.height - h) / 2)
        }
        return CGPoint(x: x, y: y)
    }
}

/// Reused by the actual compact menu footer and Settings spotlight.
struct HighlightTourCoach: View {
    var compact = false
    @ObservedObject private var guide = GuideCoordinator.shared
    @FocusState private var primaryFocused: Bool
    @AccessibilityFocusState private var headingFocused: Bool

    private var step: HighlightTourStep { guide.currentTourStep }
    var explanation: String {
        if guide.creationPreviewOpened {
            return step == .addComponent
                ? "This is the real creation form. Describe the capability, copy the prompt, and give it to your agent. Wakely validates the result. This tour only shows the form; it doesn't copy anything or create a component."
                : "This is the real screen form. Describe the page and give its prompt to your agent. The generated screen becomes a tab. This tour doesn't copy the prompt, write files or create a screen."
        }
        return step.explanation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack {
                Text("TOUR · \(guide.displayedStep) OF \(guide.displayedStepCount)")
                    .font(WakelyType.label(9)).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                Button("Skip") { guide.dismiss() }
                    .buttonStyle(.plain).font(WakelyType.body(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("Skip tour and keep your place")
            }
            Text(step.title).font(WakelyType.name(compact ? 15 : 17))
                .accessibilityAddTraits(.isHeader).accessibilityFocused($headingFocused)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(explanation).font(WakelyType.body(compact ? 11.5 : 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: compact ? 100 : 140)
            .fixedSize(horizontal: false, vertical: true)

            if (step == .addComponent || step == .addScreen), !guide.creationPreviewOpened {
                Button("Show the form") { HighlightTourNavigation.shared.previewCreation() }
                    .font(WakelyType.body(11.5))
            }
            HStack(spacing: 8) {
                Button("Back") { guide.previous() }.disabled(guide.progress.step == 0)
                Spacer(minLength: 4)
                Button(step.nextTitle) {
                    if step == .finish { guide.completeOnboarding() }
                    else { guide.next() }
                }
                .buttonStyle(PixelButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .focused($primaryFocused)
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PixelShape(cut: 4).fill(Theme.window))
        .overlay(PixelShape(cut: 4).strokeBorder(Theme.gold.opacity(0.75), lineWidth: 1))
        .foregroundStyle(Theme.ink)
        .buttonStyle(PixelButtonStyle())
        .environment(\.font, WakelyType.body(12))
        .onAppear {
            headingFocused = true
            if step != .optionEditor { primaryFocused = true }
        }
        .onChange(of: guide.progress.step) { _, _ in
            headingFocused = true
            if step != .optionEditor { primaryFocused = true }
        }
    }
}

/// This is the production inline control with an isolated binding, never a saved preference.
struct TourPracticeValue: View {
    @ObservedObject private var guide = GuideCoordinator.shared
    var body: some View {
        InlineValueChip(value: $guide.demoMinutes,
                        domain: .explicit(Array(stride(from: 15, through: 720, by: 15))),
                        format: ValueChip.Style.minutes.inlineFormat,
                        accessibilityName: "Practice time; does not change your settings",
                        requestEditing: guide.currentTourStep == .optionEditor,
                        onEditingChanged: { editing in
                            if editing, guide.currentTourStep == .inlineOption { guide.next() }
                        })
            .fixedSize()
    }
}

/// UI-only routing. The policy coordinator stays independent of engines/settings.
@MainActor
final class HighlightTourNavigation {
    static let shared = HighlightTourNavigation()
    private struct Snapshot {
        let tab: String
        let query: String
        let onOnly: Bool
        let detail: ComponentDefinition?
        let selected: String?
    }
    private var snapshot: Snapshot?
    private var wasMenu = false

    func install() {
        let guide = GuideCoordinator.shared
        guide.onTourStepChange = { [weak self] step in self?.show(step) }
        guide.onTourEnd = { [weak self] in self?.end() }
        if guide.isPresented { show(guide.currentTourStep) }
    }

    private func show(_ step: HighlightTourStep) {
        let model = SettingsModel.shared
        let guide = GuideCoordinator.shared
        if snapshot == nil {
            snapshot = Snapshot(tab: model.tab, query: model.query, onOnly: model.showOnOnly,
                                detail: model.detailComponent, selected: model.selectedComponent)
        }
        model.showMakeYourOwn = false
        model.closeScreenPrompt()
        model.closeScreenEditor()
        model.showOnOnly = false
        if step.isMenu {
            wasMenu = true
            if !guide.isPreviewing { FluidOpen.shared.syncHighlightedTourMenu() }
            return
        }
        if wasMenu {
            wasMenu = false
            if !guide.isPreviewing { FluidOpen.shared.restoreSettingsAfterTour() }
        }
        switch step {
        case .general, .finish:
            model.tab = "general"
            model.detailComponent = nil
        case .componentDetail, .inlineOption, .optionEditor:
            model.tab = "components"
            model.query = "Agent Light"
            model.selectedComponent = HighlightTourStep.demonstrationComponentID
            model.detailComponent = ComponentCatalog.definition(for: HighlightTourStep.demonstrationComponentID)
        case .componentCard:
            model.tab = "components"
            model.query = "Agent Light"
            model.detailComponent = nil
        default:
            model.tab = "components"
            model.query = ""
            model.detailComponent = nil
        }
    }

    func previewCreation() {
        let guide = GuideCoordinator.shared
        guard guide.isPresented, !guide.creationPreviewOpened else { return }
        if guide.currentTourStep == .addComponent {
            SettingsModel.shared.showMakeYourOwn = true
        } else if guide.currentTourStep == .addScreen {
            SettingsModel.shared.beginScreenPrompt()
        } else { return }
        guide.creationPreviewOpened = true
    }

    private func end() {
        let model = SettingsModel.shared
        model.showMakeYourOwn = false
        model.closeScreenPrompt()
        model.closeScreenEditor()
        if let snapshot {
            model.tab = snapshot.tab
            model.query = snapshot.query
            model.showOnOnly = snapshot.onOnly
            model.detailComponent = snapshot.detail
            model.selectedComponent = snapshot.selected
        }
        snapshot = nil
        if wasMenu {
            wasMenu = false
            if !GuideCoordinator.shared.isPreviewing { FluidOpen.shared.restoreSettingsAfterTour() }
        }
    }
}
