import SwiftUI
import AppKit

/// Preview/QA entry uses the same real Settings view as production onboarding.
struct GuideDestinationView: View {
    var body: some View { SettingsView(initialTab: "components") }
}

/// Retained only for legacy scene fixtures; never used as the onboarding route.
private struct LegacyGuideDestinationView: View {
    @ObservedObject private var guide = GuideCoordinator.shared
    @ObservedObject private var settings = SettingsModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    @FocusState private var primaryFocused: Bool

    private var active: Bool { settings.panelPresented || ProcessInfo.processInfo.environment["WAKELY_GUIDE_PREVIEW_ACTIVE"] == "1" }

    var body: some View {
        GeometryReader { proxy in
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("GETTING STARTED").font(WakelyType.label(10))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Skip for now") { guide.dismiss() }
                    .help("Close the tour and keep your place")
            }
            .frame(height: 28)
            onboarding(sceneHeight: max(140, min(240, proxy.size.height - 270)))
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
        .foregroundStyle(Theme.ink)
        .buttonStyle(PixelButtonStyle())
        .onExitCommand { guide.dismiss() }
        .onAppear {
            headingFocused = true
            primaryFocused = true
        }
        .onChange(of: guide.progress.step) { _, _ in headingFocused = true }
        }
    }

    private func onboarding(sceneHeight: CGFloat) -> some View {
        let page = OnboardingCatalog.pages[guide.progress.step]
        return VStack(spacing: 12) {
            // Keep the outlined mark exclusive to the macOS status bar. The
            // full-colour app icon is centred in the onboarding window instead.
            VStack(spacing: 8) {
                if guide.progress.step == 0, let appIcon = BrandIcon.appImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Wakely logo")
                }
                Text(page.title)
                    .font(WakelyType.display(22))
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($headingFocused)
                Text(page.body)
                    .font(WakelyType.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, minHeight: 36)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .id(page.id)
            .transition(reduceMotion ? .identity : .opacity)

            GuideScenePlayer(kind: page.scene, beats: page.beats, active: active,
                             previewBeat: guide.previewBeat,
                             forceReducedMotion: guide.previewReduceMotion,
                             sceneHeight: sceneHeight)
                .id("tour-\(guide.generation)-\(page.id)")

            Spacer(minLength: 0)
            HStack {
                Button("← Back") { guide.previous() }
                    .disabled(guide.progress.step == 0)
                    .frame(minWidth: 80, alignment: .leading)
                Spacer(minLength: 4)
                GuideProgressDots(current: guide.progress.step,
                                  labels: OnboardingCatalog.pages.map(\.title),
                                  onSelect: { guide.go(to: $0) })
                Spacer(minLength: 4)
                Button(guide.progress.step == 4 ? "Explore Components →" : "Continue →") {
                    if guide.progress.step == 4 {
                        settings.tab = "components"
                        if settings.detailComponent != nil { settings.requestDetailBack() }
                        guide.completeOnboarding()
                    } else { guide.next() }
                }
                .buttonStyle(PixelButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
                .focused($primaryFocused)
                .frame(minWidth: 140, alignment: .trailing)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .contain)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: guide.progress.step)
    }

}

/// Film-like playback with a finite 5fps clock. Pausing, leaving the panel or
/// backgrounding the application freezes time, rather than playing offscreen.
struct GuideScenePlayer: View {
    let kind: GuideSceneKind
    let beats: [GuideBeat]
    let active: Bool
    var previewBeat: Int? = nil
    var forceReducedMotion = false
    var sceneHeight: CGFloat = 180
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var playback = GuidePlayback()
    @State private var applicationActive = NSApp.isActive

    private var reduced: Bool { systemReduceMotion || forceReducedMotion }
    private var canAnimate: Bool { active && applicationActive && !reduced && previewBeat == nil }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2,
                                paused: !playback.isRunning || !canAnimate)) { context in
            let position = playback.position(at: context.date)
            let beat = previewBeat ?? playback.beat(at: context.date)
            let frame = previewBeat != nil || reduced ? 0 : playback.frame(at: context.date)
            VStack(spacing: 4) {
                PixelGuideScene(kind: kind, beat: reduced ? (previewBeat ?? 1) : beat, frame: frame)
                    .frame(height: sceneHeight)
                    .accessibilityHidden(true)
                HStack(spacing: 12) {
                    Spacer()
                    if !reduced {
                        Button {
                            playback.togglePause(at: Date(), canAnimate: canAnimate)
                        } label: {
                            Image(systemName: playback.isRunning ? "pause" : "play")
                                .frame(width: 24, height: 24)
                        }
                        .disabled(playback.isFinished || previewBeat != nil)
                        .accessibilityLabel(playback.isRunning ? "Pause preview" : "Play preview")
                        .help(playback.isRunning ? "Pause animation" : "Play animation")
                        Button {
                            playback.replay(at: Date(), canAnimate: canAnimate)
                        } label: {
                            Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 24)
                        }
                        .disabled(previewBeat != nil)
                        .accessibilityLabel("Replay preview")
                        .help("Replay animation")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .frame(height: 24)
            }
            .onChange(of: position >= GuidePlayback.duration) { _, finished in
                if finished { playback.finish(at: context.date) }
            }
        }
        .onAppear {
            if let previewBeat { selectScene(previewBeat) }
            else { playback.updateActivity(active: canAnimate, reduceMotion: reduced, at: Date()) }
        }
        .onDisappear { playback.freeze(at: Date()) }
        .onChange(of: canAnimate) { _, available in
            playback.updateActivity(active: available, reduceMotion: reduced, at: Date())
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in applicationActive = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in applicationActive = false }
    }

    private func selectScene(_ index: Int) {
        playback.selectBeat(index)
    }
}

/// Pixel-sized marks with proper 28pt hit targets and keyboard/VoiceOver labels.
struct GuideProgressDots: View {
    let current: Int
    let labels: [String]
    var labelPrefix = "Step"
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(labels.indices, id: \.self) { index in
                GuideDot(current: current, index: index, count: labels.count,
                         prefix: labelPrefix, title: labels[index]) { onSelect(index) }
            }
        }
        .accessibilityElement(children: .contain)
        .onKeyPress(.leftArrow) {
            onSelect(max(0, current - 1)); return .handled
        }
        .onKeyPress(.rightArrow) {
            onSelect(min(max(0, labels.count - 1), current + 1)); return .handled
        }
    }
}

private struct GuideDot: View {
    let current: Int
    let index: Int
    let count: Int
    let prefix: String
    let title: String
    var action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            PixelShape(cut: 1)
                .fill(current == index ? Theme.gold : (index < current ? Theme.gold.opacity(0.45) : Theme.control))
                .frame(width: current == index ? 10 : 6, height: 6)
                .overlay(PixelShape(cut: 1).strokeBorder(current == index ? Theme.gold : Theme.textTertiary, lineWidth: 1))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(PixelShape(cut: 3).fill(hover ? Theme.controlHover : .clear))
                .overlay(PixelShape(cut: 3).strokeBorder(focused ? Theme.gold : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .onHover { hover = $0 }
        .accessibilityLabel("\(prefix) \(index + 1) of \(count): \(title)")
        .accessibilityValue(current == index ? "Current step" : (index < current ? "Previous step" : "Available step"))
        .accessibilityAddTraits(current == index ? .isSelected : [])
        .help(title)
    }
}
