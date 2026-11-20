// SettingsUI — the window, rebuilt to match the shipped app: dark, a sidebar
// (Components / APP: General, License, About), a searchable component grid with
// category sections and cards that animate on hover and on toggle.

import SwiftUI
import AppKit

// MARK: - Shared UI state

@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published var tab: String = "components"
    @Published var panelPresented = false
    @Published var panelSettled = false
    @Published var query: String = ""
    @Published var showOnOnly = false
    @Published var selectedComponent: String?
    @Published var detailComponent: ComponentDefinition?
    @Published var showMakeYourOwnAtLaunch = false
    @Published var showMakeYourOwn = false
    @Published var showScreenEditor = false
    @Published var screenEditorID: UUID?
    @Published var showScreenPrompt = false
    @Published var screenPromptID: UUID?
    @Published var cleaningLockMessage = ""
    @Published var enablementNotice = ""
    @Published private(set) var detailBackRequest = 0
    @Published private(set) var enabled: Set<String> = ComponentEngine.shared.enabledIDs

    /// Window-level Back/Escape is routed here while a detail page owns the
    /// inner route; reversing a card morph must not close the whole panel.
    func requestDetailBack() { detailBackRequest &+= 1 }

    func isOn(_ id: String) -> Bool { enabled.contains(id) }

    func setOn(_ id: String, _ on: Bool) {
        guard !GuideCoordinator.shared.isPresented else { return }
        ComponentEngine.shared.setEnabled(id, on)
        enabled = ComponentEngine.shared.enabledIDs
        if on, !enabled.contains(id) {
            if ComponentPermissions.shared.isSettingUp(id) {
                enablementNotice = "Finish the setup window to turn this on."
            } else {
                enablementNotice = ComponentEngine.shared.enablementReason(for: id)
                    ?? ComponentCapabilityPolicy.capability(for: id).reason
            }
        } else {
            enablementNotice = ""
        }
    }

    func refresh() { enabled = ComponentEngine.shared.enabledIDs }

    var anyModalPresented: Bool { showMakeYourOwn || showScreenEditor || showScreenPrompt }

    func beginScreenEditor(_ id: UUID? = nil) {
        showMakeYourOwn = false
        screenEditorID = id
        showScreenEditor = true
    }

    func closeScreenEditor() {
        showScreenEditor = false
        screenEditorID = nil
    }

    func beginScreenPrompt(_ id: UUID? = nil) {
        showMakeYourOwn = false
        showScreenEditor = false
        screenPromptID = id
        showScreenPrompt = true
    }

    func closeScreenPrompt() {
        showScreenPrompt = false
        screenPromptID = nil
    }

    var onCount: Int { ComponentCatalog.all.filter { enabled.contains($0.id) }.count }

    func components(matching category: ComponentCategory) -> [ComponentDefinition] {
        ComponentCatalog.all.filter { component in
            guard component.category == category else { return false }
            if showOnOnly && !enabled.contains(component.id) { return false }
            guard !query.isEmpty else { return true }
            let haystack = "\(component.name) \(component.tagline) \(component.detail)".lowercased()
            return haystack.contains(query.lowercased())
        }
    }

    var filteredCount: Int {
        ComponentCategory.allCases.reduce(0) { $0 + components(matching: $1).count }
    }
}

// MARK: - Window

/// Hero namespace for the card → sheet morph; nil keeps the plain fade.
private extension View {
    /// Hero morph for the card → sheet transition, native matched geometry.
    /// Without a namespace the view is untouched, so previews stay simple.
    @ViewBuilder
    func morphHero(_ namespace: Namespace.ID?, id: String) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace)
        } else {
            self
        }
    }
}

private struct ComponentMorphKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var componentMorph: Namespace.ID? {
        get { self[ComponentMorphKey.self] }
        set { self[ComponentMorphKey.self] = newValue }
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var glass = GlassPolicy.shared
    @ObservedObject private var permissions = ComponentPermissions.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject private var guides = GuideCoordinator.shared
    @ObservedObject private var customScreens = CustomScreenStore.shared
    @Namespace private var morph

    init(initialTab: String = "components", openMakeYourOwn: Bool = false) {
        if CustomScreenRoute.id(from: initialTab) != nil,
           CustomScreenStore.shared.screen(for: initialTab) == nil {
            SettingsModel.shared.tab = "components"
        } else {
            SettingsModel.shared.tab = initialTab
        }
        if openMakeYourOwn { SettingsModel.shared.showMakeYourOwnAtLaunch = true }
    }

    /// One title layer survives tab changes; the panes reserve its original
    /// space so the search/filter header does not move down a row.
    private var paneTitle: String {
        switch model.tab {
        case "general": return "General"
        case "about": return "About"
        default:
            return customScreens.screen(for: model.tab)?.title ?? "Components"
        }
    }

    /// Components owns its subtitle beside the search field. General and About
    /// share the same title-and-subtitle hierarchy in the window header.
    private var paneSubtitle: String? {
        switch model.tab {
        case "components": return "Choose what your Mac does next."
        case "general": return "Set up appearance, startup, safety and helper access."
        case "about": return "What Wakely does, where it comes from, and its licence."
        default:
            guard let screen = customScreens.screen(for: model.tab), !screen.subtitle.isEmpty else { return nil }
            return screen.subtitle
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Keep panes mounted: switching tabs must not destroy a detail
            // route, scroll position or focused editor just to crossfade it.
            ZStack {
                ComponentsPane().modifier(SettingsPaneMotion(active: model.tab == "components", reduceMotion: reduceMotion))
                CustomScreenPane().modifier(SettingsPaneMotion(active: CustomScreenRoute.id(from: model.tab) != nil, reduceMotion: reduceMotion))
                GeneralPane().modifier(SettingsPaneMotion(active: model.tab == "general", reduceMotion: reduceMotion))
                AboutPane().modifier(SettingsPaneMotion(active: model.tab == "about", reduceMotion: reduceMotion))
            }
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // A visual scrim is not a keyboard/AX safety boundary. Disable the
            // real controls too; the practice control lives outside this subtree.
            .disabled(guides.isPresented)
            .allowsHitTesting(!model.anyModalPresented && !permissions.setupPresented && !guides.isPresented)
            .accessibilityHidden(model.anyModalPresented || permissions.setupPresented || guides.isPresented)

        }
        .background(glass.usesMaterial ? Color.clear : Theme.window)
        .preferredColorScheme(appearance.preferredColorScheme)
        .animation(nil, value: appearance.choice)
        .foregroundStyle(Theme.ink)
        .tint(Theme.gold)
        .buttonStyle(PixelButtonStyle())
        .toggleStyle(PixelSwitchToggleStyle())
        // Pixel Operator is the default for anything without an explicit face:
        // Button labels, field placeholders and picker text included.
        .environment(\.font, ClamType.body(13))
        .environment(\.componentMorph, morph)
        .frame(minWidth: 700, minHeight: 500)
        .overlay(alignment: .topLeading) {
            // The detail route owns its own breadcrumb; the page title steps
            // aside instead of colliding with it.
            if model.tab != "components" || model.detailComponent == nil {
                VStack(alignment: .leading, spacing: 6) {
                    TorphText(paneTitle, font: ClamType.displayFont(19))
                        .foregroundStyle(Theme.ink)
                    if let paneSubtitle {
                        TorphText(paneSubtitle, font: ClamType.bodyFont(13))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .tourTarget(model.tab == "components" ? "componentsIntro" : "paneSubtitle-\(model.tab)")
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 36)
                .allowsHitTesting(false)
                .accessibilityHidden(model.anyModalPresented)
            }
        }
        .overlay(alignment: .bottom) {
            FloatingNav()
                .padding(.bottom, 18)
                .allowsHitTesting(!model.anyModalPresented && !permissions.setupPresented && !guides.isPresented)
                .accessibilityHidden(model.anyModalPresented || permissions.setupPresented || guides.isPresented)
        }
        .overlay {
            SettingsOverlay()
                .buttonStyle(PixelButtonStyle())
                .toggleStyle(PixelSwitchToggleStyle())
                .environment(\.font, ClamType.body(13))
                .disabled(guides.isPresented)
                .allowsHitTesting(!guides.isPresented)
                .accessibilityHidden(guides.isPresented)
        }
        .overlayPreferenceValue(HighlightTourAnchorKey.self) { anchors in
            if guides.isPresented && !guides.isMenuTour {
                HighlightTourOverlay(anchors: anchors)
                    .id(guides.generation)
                    .environment(\.font, ClamType.body(13))
                    .transition(.identity)
            }
        }
        .onAppear { HighlightTourNavigation.shared.install() }
        .onChange(of: customScreens.screens) { _, _ in
            guard CustomScreenRoute.id(from: model.tab) != nil,
                  customScreens.screen(for: model.tab) == nil else { return }
            model.tab = "components"
        }
    }
}

/// Pane identity stays stable; only a small spatial arrival is sprung. Hidden
/// panes are neither interactive nor exposed to assistive technology.
private struct SettingsPaneMotion: ViewModifier {
    let active: Bool
    let reduceMotion: Bool
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var guides = GuideCoordinator.shared
    func body(content: Content) -> some View {
        content
            .environment(\.wakelyPaneIsActive, active && model.panelPresented && !guides.isPresented)
            .opacity(active ? 1 : 0)
            .animation(nil, value: active)
            .offset(x: active || reduceMotion || !model.panelSettled ? 0 : 10)
            .animation(AppMotion.animation(.navigation, reduceMotion: reduceMotion || !model.panelSettled), value: active)
            .allowsHitTesting(active)
            .accessibilityHidden(!active)
            .zIndex(active ? 1 : 0)
    }
}

/// Modal chrome drawn inside the window instead of a native sheet, so the
/// panel keeps square notched corners, a hard shadow and the dither behind it.
private struct SettingsOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var permissions = ComponentPermissions.shared
    @ObservedObject private var screens = CustomScreenStore.shared

    var body: some View {
        // The window can be as short as 500pt; measure it so a sheet's scrolling
        // body shrinks with it and the footer always stays on-screen.
        GeometryReader { proxy in
            let bodyCap = SheetLayout.bodyCap(windowHeight: proxy.size.height)
            ZStack {
                if permissions.setupPresented {
                    scrim { permissions.cancel() }
                        .transition(.opacity)
                    ComponentSetupContent(coordinator: permissions)
                        .frame(width: min(540, max(420, proxy.size.width - 60)),
                               height: min(520, max(420, proxy.size.height - 60)))
                        .background(PixelShape(cut: 4).fill(Theme.window))
                        .overlay(PixelShape(cut: 4).strokeBorder(Theme.strokeHover, lineWidth: 1))
                        .padding(SheetLayout.inset)
                        .transition(reduceMotion ? .identity : .offset(y: 18))
                } else if model.showMakeYourOwn {
                    scrim { model.showMakeYourOwn = false }
                        .transition(.opacity)
                    MakeYourOwnSheet(bodyCap: bodyCap) { model.showMakeYourOwn = false }
                        .padding(SheetLayout.inset)
                        .transition(reduceMotion ? .identity : .offset(y: 18))
                } else if model.showScreenPrompt {
                    scrim { model.closeScreenPrompt() }
                        .transition(.opacity)
                    ScreenPromptSheet(screen: model.screenPromptID.flatMap(screens.screen(with:)),
                                      bodyCap: bodyCap) { model.closeScreenPrompt() }
                        .padding(SheetLayout.inset)
                        .transition(reduceMotion ? .identity : .offset(y: 18))
                } else if model.showScreenEditor {
                    scrim { model.closeScreenEditor() }
                        .transition(.opacity)
                    ScreenEditorSheet(screen: model.screenEditorID.flatMap(screens.screen(with:)),
                                      bodyCap: bodyCap) { model.closeScreenEditor() }
                        .padding(SheetLayout.inset)
                        .transition(reduceMotion ? .identity : .offset(y: 18))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(AppMotion.animation(.sheet, reduceMotion: reduceMotion), value: model.showMakeYourOwn)
        .animation(AppMotion.animation(.sheet, reduceMotion: reduceMotion), value: model.showScreenEditor)
        .animation(AppMotion.animation(.sheet, reduceMotion: reduceMotion), value: model.showScreenPrompt)
        .animation(AppMotion.animation(.sheet, reduceMotion: reduceMotion), value: permissions.setupPresented)
    }

    private func scrim(_ dismiss: @escaping () -> Void) -> some View {
        Theme.scrim.opacity(0.62)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
    }
}

// MARK: - Sheet chrome

/// A sheet is inset from the window and padded again inside its panel, and the
/// window can be as short as the view's 500pt minimum. The footer is pinned to
/// the bottom of the panel; the scrolling body only ever gets what is left, so
/// a footer action can never be pushed past the window edge.
private enum SheetLayout {
    /// Overlay padding around a sheet.
    static let inset: CGFloat = 30
    /// A sheet's own content padding, top and bottom.
    static let padding: CGFloat = 22
    /// Footer row (a 27pt button plus its shadow) and the 16pt gap above it,
    /// with a few points spare for a taller control.
    static let footer: CGFloat = 48

    /// Height left for a sheet's scrolling body at a given window height.
    static func bodyCap(windowHeight: CGFloat) -> CGFloat {
        max(240, windowHeight - inset * 2 - padding * 2 - footer)
    }
}

/// Natural height of a sheet body, so a short sheet stays compact and only an
/// overflowing one scrolls.
private struct SheetBodyHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum Theme {
    /// Keep the provider dynamic: AppKit and SwiftUI resolve the same colour in
    /// the drawing appearance, including subsequent changes to macOS System.
    static func adaptiveNSColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
    }
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: adaptiveNSColor(light: light, dark: dark))
    }
    static let windowColor = adaptiveNSColor(light: 0xF7F7F8, dark: 0x09090B)
    static let window = Color(nsColor: windowColor)
    /// Resolved bytes for existing raster consumers; invalidate their caches on
    /// wakelyAppearanceDidChange rather than retaining a startup sample.
    static var windowInk: (r: Double, g: Double, b: Double) {
        var result = (r: 9.0, g: 9.0, b: 11.0)
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let c = windowColor.usingColorSpace(.sRGB) {
                result = (Double(c.redComponent * 255), Double(c.greenComponent * 255), Double(c.blueComponent * 255))
            }
        }
        return result
    }
    static let sidebar = adaptive(light: 0xEEEEF1, dark: 0x0B0B0E)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x0B0B0E)
    static let cardHover = adaptive(light: 0xF4F0E5, dark: 0x1A1812)
    static let stroke = adaptive(light: 0xC7C7CE, dark: 0x27272A)
    static let strokeHover = adaptive(light: 0xA99568, dark: 0x6A5930)
    static let cardHoverBorder = adaptive(light: 0xA78C4F, dark: 0x8A7338)
    static let controlHover = adaptive(light: 0xD0D0D9, dark: 0x34343C)
    static let navHover = adaptive(light: 0xD9D3C6, dark: 0x2A2720)
    static let hoverOutline = adaptive(light: 0x8C8C96, dark: 0x70707A)
    static let controlPressed = adaptive(light: 0xCBCBD4, dark: 0x3A3A42)
    static let selectedSurface = adaptive(light: 0xF0E5C4, dark: 0x2A2312)
    static let selectedBorder = adaptive(light: 0x9C7A17, dark: 0xE4B936)
    static let gold = adaptive(light: 0x856000, dark: 0xEAB308)
    static let goldSoft = adaptive(light: 0x795500, dark: 0xFACC15)
    static let ink = adaptive(light: 0x202024, dark: 0xFAFAFA)
    static let textSecondary = adaptive(light: 0x41414B, dark: 0xC4C4CC)
    static let textTertiary = adaptive(light: 0x55555F, dark: 0xA6A6B0)
    static let section = textSecondary
    static let secondary = adaptive(light: 0xE8E8ED, dark: 0x18181B)
    static let control = adaptive(light: 0xE5E5EB, dark: 0x1B1B1F)
    static let chip = adaptive(light: 0xE7E7EC, dark: 0x232327)
    static let chipHover = adaptive(light: 0xD1D1DA, dark: 0x303037)
    static let accentInk = adaptive(light: 0xFFFFFF, dark: 0x1A1305)
    static let accentText = goldSoft
    static let dither = ink
    static let shadow = adaptive(light: 0xA0A0AB, dark: 0x000000)
    static let ring = gold.opacity(0.55)
    static let separator = adaptive(light: 0xC7C7CE, dark: 0x27272A)
    static let switchTrack = adaptive(light: 0xC4C4CE, dark: 0x27272A)
    static let switchTrackHover = adaptive(light: 0xB5B5C1, dark: 0x2E2E33)
    // The thumb remains white against both the grey and gold switch tracks.
    static let switchKnob = Color(hex: 0xFAFAFA)
    static let switchKnobBorder = Color.black.opacity(0.45)
    static let scrim = Color.black

    static func accent(_ category: ComponentCategory) -> Color {
        switch category {
        case .agents: return adaptive(light: 0x856000, dark: 0xFBBF24)
        case .keyboard: return adaptive(light: 0x925000, dark: 0xF59E0B)
        case .security: return adaptive(light: 0xA1460C, dark: 0xFB923C)
        case .power: return adaptive(light: 0x796000, dark: 0xFACC15)
        case .connections: return adaptive(light: 0x96501C, dark: 0xFDBA74)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Sidebar

private struct FloatingNav: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var screens = CustomScreenStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @FocusState private var focusedTab: String?

    private var items: [(id: String, title: String, icon: String)] {
        [("components", "Components", "square.grid.2x2")]
            + screens.screens.map { (CustomScreenRoute.tab(for: $0.id), $0.title, $0.icon) }
            + [("general", "General", "slider.horizontal.3"),
               ("about", "About", "info.circle")]
    }

    @ViewBuilder private var tabs: some View {
        ForEach(items, id: \.id) { item in
            tab(item.id, title: item.title, icon: item.icon)
        }
    }

    var body: some View {
        Group {
            if items.count <= 5 {
                HStack(spacing: 3) { tabs }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 3) { tabs }
                }
                .frame(maxWidth: 760)
            }
        }
        .padding(5)
        .background(PixelShape(cut: 3).fill(Theme.sidebar))
        .overlay(PixelShape(cut: 3).strokeBorder(Theme.strokeHover, lineWidth: 1))
        .zIndex(40)
        .accessibilityElement(children: .contain)
    }

    private func tab(_ id: String, title: String, icon: String) -> some View {
        let selected = model.tab == id
        return Button {
            model.tab = id
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title)
                    .font(ClamType.body(13, selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Theme.goldSoft : Theme.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? Theme.goldSoft : Theme.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(PixelShape(cut: 2)
                .fill(selected ? Theme.gold.opacity(hovered == id ? 0.18 : 0.13)
                      : (hovered == id ? Theme.navHover : .clear)))
            .overlay(PixelShape(cut: 2)
                .strokeBorder(focusedTab == id ? Theme.gold
                              : (selected ? Theme.gold.opacity(0.82)
                                 : (hovered == id ? Theme.hoverOutline : .clear)),
                              lineWidth: focusedTab == id ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($focusedTab, equals: id)
        .focusEffectDisabled()
        .onHover { hovered = $0 ? id : nil }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Components pane

private struct ComponentsPane: View {
    @ObservedObject private var guides = GuideCoordinator.shared
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var store = ComponentStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @FocusState private var makeYourOwnFocused: Bool
    @Namespace private var filterIndicator
    @State private var scrollOffset: CGFloat = 0
    private var motion: Animation? { AppMotion.animation(.layout, reduceMotion: reduceMotion) }
    private var custom: [ComponentSpec] {
        store.components.filter {
            (!model.showOnOnly || store.isEnabled($0.id)) &&
            (model.query.isEmpty || "\($0.name) \($0.tagline)".localizedCaseInsensitiveContains(model.query))
        }
    }
    private var visibleErrors: [String] {
        model.showOnOnly ? [] : store.errors.keys.sorted().filter { model.query.isEmpty || $0.localizedCaseInsensitiveContains(model.query) }
    }
    private var onCount: Int { model.onCount + store.components.filter { store.isEnabled($0.id) }.count }
    private var total: Int { ComponentCatalog.all.count + store.components.count }

    @State private var cardFrames: [String: CGRect] = [:]
    @StateObject private var presentation = CardMorphPresentationModel()
    @State private var handledSettleSerial = 0
    @State private var canvasSize = CGSize(width: 900, height: 620)

    /// Where the settled header sits in the components pane. The morph overlay
    /// and the real page both resolve this to the same rect.
    private var detailHeaderFrame: CGRect {
        CGRect(x: ComponentCardMetrics.pageInset,
               y: ComponentCardMetrics.headerTop,
               width: max(320, canvasSize.width - ComponentCardMetrics.pageInset * 2),
               height: ComponentCardMetrics.headerHeight)
    }

    var body: some View {
        GeometryReader { canvas in
            let active = presentation.isActive
            let p = active ? presentation.progress : 1
            let session = presentation.session
            let geometry = session.map {
                CardMorphGeometry(source: $0.source, destination: $0.destination,
                                  direction: active && presentation.phase == .closing ? .closing : .opening)
            }
            ZStack(alignment: .topLeading) {
                catalog
                    .allowsHitTesting(!active && model.detailComponent == nil)
                    .accessibilityHidden(active || model.detailComponent != nil)

                // The dim belongs below the detail page, not above it. When it
                // lived in the moving overlay it darkened the settled page and
                // produced a bright pop at handoff.
                if let geometry {
                    Color.black
                        .opacity(0.42 * geometry.catalogDim(presentation: p))
                        .frame(width: canvas.size.width, height: canvas.size.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                if let component = model.detailComponent {
                    ComponentDetailPage(component: component,
                                     isOn: model.isOn(component.id),
                                     onBack: { closeDetail() },
                                     onToggle: {
                                         model.setOn(component.id, !model.isOn(component.id))
                                     },
                                     showsHeader: !active,
                                     allowsBackShortcut: !guides.isPresented,
                                     contentProgress: active ? (geometry?.contentPresence(presentation: p) ?? 0) : 1,
                                     navigationProgress: active ? (geometry?.navigationPresence(presentation: p) ?? 0) : 1,
                                     backgroundProgress: active ? (geometry?.backgroundPresence(presentation: p) ?? 0) : 1) {
                        ComponentDetailContent(component: component)
                    }
                    .frame(width: canvas.size.width, height: canvas.size.height)
                    .allowsHitTesting(!active)
                    .accessibilityHidden(active)
                }

                if active, let session,
                   let component = ComponentCatalog.definition(for: session.componentID) {
                    CardMorphOverlay(component: component,
                                     isOn: model.isOn(component.id),
                                     canvas: canvas.size,
                                     source: session.source,
                                     destination: session.destination,
                                     direction: presentation.phase == .closing ? .closing : .opening,
                                     progress: presentation.progress,
                                     dimsCatalog: false)
                        .id(session.id)
                }

                if presentation.isAnimating {
                    CardMorphClock(isRunning: true) { dt in
                        presentation.advance(dt: dt)
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .coordinateSpace(name: "components-canvas")
            .onPreferenceChange(ComponentCardFrameKey.self) { frames in
                cardFrames = frames
            }
            .onAppear { canvasSize = canvas.size }
            .onChange(of: canvas.size) { oldSize, size in
                canvasSize = size
                // A live host resize can invalidate both measured endpoints.
                // Settle to the current logical route rather than continuing
                // toward a stale rect or handing off a mismatched frame.
                if presentation.isActive,
                   abs(oldSize.width - size.width) > 0.5 || abs(oldSize.height - size.height) > 0.5 {
                    presentation.rebaseDestination(CGRect(
                        x: ComponentCardMetrics.pageInset,
                        y: ComponentCardMetrics.headerTop,
                        width: max(320, size.width - ComponentCardMetrics.pageInset * 2),
                        height: ComponentCardMetrics.headerHeight))
                    presentation.settle()
                }
            }
        }
        .background(Button("") { if !guides.isPresented { searchFocused = true } }.keyboardShortcut("f", modifiers: .command)
            .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true))
        .onExitCommand {
            if guides.isPresented { return }
            if model.detailComponent != nil {
                closeDetail()
            } else {
                withAnimation(motion) { model.query = "" }
                searchFocused = false
            }
        }
        .onChange(of: guides.isPresented) { _, showing in
            if showing { searchFocused = false; makeYourOwnFocused = false }
            if showing, presentation.isActive {
                presentation.settle()
                if presentation.awaitingCloseCommit { presentation.commitClosed() }
            }
        }
        .onChange(of: presentation.settledEvent) { _, event in
            guard !guides.isPresented, let event, event.serial != handledSettleSerial else { return }
            handledSettleSerial = event.serial
            finishMorph(event)
        }
        .onChange(of: model.detailBackRequest) { _, _ in
            if model.detailComponent != nil { closeDetail() }
        }
        .onChange(of: model.showMakeYourOwn) { wasShowing, showing in
            // The modal owns focus while open. On close, return it to the card
            // that invoked it instead of abandoning keyboard navigation.
            if showing {
                makeYourOwnFocused = false
            } else if wasShowing {
                makeYourOwnFocused = true
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            guard reduced, presentation.isActive else { return }
            presentation.settle()
        }
        .onAppear {
            if model.showMakeYourOwnAtLaunch {
                model.showMakeYourOwnAtLaunch = false
                model.showMakeYourOwn = true
            }
        }
        .onDisappear {
            // Leaving the hosting view must not leave a display link running.
            // The logical detail route is preserved for the retained pane.
            if presentation.isActive { presentation.settle() }
        }
    }

    private var catalog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                // The shared header draws the title and subtitle above this
                // row and morphs between tabs. These hidden copies reserve the
                // exact text block so the search field stays aligned.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Components")
                        .font(ClamType.display(19))
                        .hidden()
                        .accessibilityHidden(true)
                    Text("Choose what your Mac does next.")
                        .font(ClamType.body(13))
                        .hidden()
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 0)
                // Search and the All/On filter share one row; the old
                // "ENABLED" tally row is gone.
                HStack(spacing: 10) {
                    searchField
                    chips
                }
            }
            .padding(.top, 36).padding(.horizontal, 28).padding(.bottom, 25)

            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, 28)

            ScrollViewReader { proxy in
                EdgeScrollView(topFade: 28, bottomFade: 68, onOffset: { scrollOffset = $0 }) {
                    VStack(alignment: .leading, spacing: 26) {
                        Color.clear.frame(height: 0).id("components-top")
                        if model.filteredCount == 0 && custom.isEmpty && visibleErrors.isEmpty {
                            emptyState
                                .transition(.identity)
                        }
                        ForEach(ComponentCategory.allCases, id: \.self) { category in
                            let components = model.components(matching: category)
                            if !components.isEmpty {
                                VStack(alignment: .leading, spacing: 13) {
                                    sectionLabel(category.rawValue, count: components.count, accent: Theme.accent(category))
                                    // These small grids are deliberately eager: stable views allow
                                    // surviving cards to flow to their new position instead of popping in.
                                    VGrid(spacing: 12) {
                                        ForEach(components) { component in
                                            ComponentCard(component: component, isOn: model.isOn(component.id),
                                                onToggle: { model.setOn(component.id, !model.isOn(component.id)) },
                                                onOpen: { openDetail(component) })
                                                .id("tour-component-\(component.id)")
                                                .tourTarget(component.id == HighlightTourStep.demonstrationComponentID ? "componentCard" : "catalog-\(component.id)")
                                                .background(
                                                    GeometryReader { proxy in
                                                        Color.clear.preference(
                                                            key: ComponentCardFrameKey.self,
                                                            value: [component.id: proxy.frame(in: .named("components-canvas"))])
                                                    }
                                                )
                                                // The travelling surface is the only live
                                                // copy of this card. Leaving the grid copy
                                                // visible showed a second title and border
                                                // through the morph.
                                                .opacity(presentation.isActive && presentation.componentID == component.id ? 0 : 1)
                                                .allowsHitTesting(!(presentation.isActive && presentation.componentID == component.id))
                                                .accessibilityHidden(presentation.isActive && presentation.componentID == component.id)
                                                .transition(.identity)
                                        }
                                    }
                                }
                                .transition(.identity)
                            }
                        }
                        if store.customComponentsEnabled && (!custom.isEmpty || (!model.showOnOnly && model.query.isEmpty) || (!model.showOnOnly && store.errors.keys.contains { $0.localizedCaseInsensitiveContains(model.query) })) {
                            VStack(alignment: .leading, spacing: 13) {
                                sectionLabel("CUSTOM", count: custom.count + visibleErrors.count, accent: Theme.textSecondary)
                                VGrid(spacing: 12) {
                                    ForEach(custom) { CustomComponentCard(component: $0).transition(.identity) }
                                    if !model.showOnOnly && model.query.isEmpty {
                                        MakeYourOwnCard { model.showMakeYourOwn = true }
                                            .focused($makeYourOwnFocused)
                                            .id("tour-addComponent").tourTarget("addComponent")
                                        AddScreenCard { model.beginScreenPrompt() }
                                            .id("tour-addScreen").tourTarget("addScreen")
                                            .disabled(!CustomScreenStore.shared.canCreateAnother)
                                    }
                                    if !model.showOnOnly {
                                        ForEach(store.errors.keys.sorted().filter { model.query.isEmpty || $0.localizedCaseInsensitiveContains(model.query) }, id: \.self) { id in
                                            InvalidComponentCard(id: id, errors: store.errors[id] ?? [])
                                        }
                                    }
                                }
                            }
                            .transition(.identity)
                        }
                    }
                    .padding(.horizontal, 28).padding(.top, 0)
                    .padding(.bottom, guides.isPresented ? max(96, canvasSize.height - 180) : 96)
                    .animation(motion, value: model.showOnOnly)
                    .animation(motion, value: model.query)
                }
                .scrollIndicators(.hidden)
                .onChange(of: model.showOnOnly) { _, _ in
                    withAnimation(motion) { proxy.scrollTo("components-top", anchor: .top) }
                }
                .task(id: "\(guides.generation)-\(guides.progress.step)-\(guides.isPresented)") {
                    guard guides.isPresented else { return }
                    let step = guides.currentTourStep
                    await Task.yield()
                    guard guides.isPresented, guides.currentTourStep == step else { return }
                    switch step {
                    case .componentCard:
                        proxy.scrollTo("tour-component-\(HighlightTourStep.demonstrationComponentID)", anchor: .top)
                    case .addComponent: proxy.scrollTo("tour-addComponent", anchor: .top)
                    case .addScreen: proxy.scrollTo("tour-addScreen", anchor: .top)
                    case .welcome: proxy.scrollTo("components-top", anchor: .top)
                    default: break
                    }
                }
            }
        }
        .coordinateSpace(name: "components-scroll")
    }

    // MARK: - Card route

    private func openDetail(_ component: ComponentDefinition) {
        guard model.detailComponent == nil,
              let source = cardFrames[component.id], source.width > 8, source.height > 1 else {
            return
        }
        guard presentation.beginOpen(componentID: component.id,
                                     source: source,
                                     destination: detailHeaderFrame,
                                     query: model.query,
                                     onOnly: model.showOnOnly,
                                     scrollOffset: scrollOffset) else { return }
        if reduceMotion { presentation.settle() }
        model.selectedComponent = component.id
        model.detailComponent = component
        model.enablementNotice = ComponentEngine.shared.enablementReason(for: component.id) ?? ""
    }

    private func closeDetail() {
        guard !guides.isPresented else { return }
        guard let component = model.detailComponent else { return }
        let measured = cardFrames[component.id].flatMap {
            $0.width > 8 && $0.height > 1 ? $0 : nil
        }
        if presentation.session == nil {
            // Direct URL/deep-link details have no hero origin. Create the
            // settled route first, then reverse from the same semantic value.
            presentation.showSettled(componentID: component.id,
                                     destination: detailHeaderFrame,
                                     query: model.query,
                                     onOnly: model.showOnOnly,
                                     scrollOffset: scrollOffset)
        }
        guard measured != nil || presentation.session?.source != .zero else {
            // No trustworthy source exists: leave the route atomically rather
            // than animating toward a fabricated rectangle.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                model.detailComponent = nil
                model.selectedComponent = nil
            }
            return
        }
        presentation.beginClose(measuredSource: measured)
        if reduceMotion { presentation.settle() }
    }

    private func finishMorph(_ event: CardMorphPresentationModel.SettledEvent) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if event.endpoint == .opened {
                if let component = ComponentCatalog.definition(for: event.componentID) {
                    model.selectedComponent = component.id
                    model.detailComponent = component
                }
                if model.tab == "components" {
                    DispatchQueue.main.async {
                        guard presentation.phase == .detail,
                              presentation.session?.id == event.sessionID,
                              model.tab == "components",
                              model.detailComponent?.id == event.componentID,
                               !GuideCoordinator.shared.isPresented else { return }
                        ComponentPermissions.shared.presentRequirementsIfNeeded(
                            for: event.componentID,
                            route: event.sessionID,
                            isRouteCurrent: {
                                presentation.phase == .detail
                                    && presentation.session?.id == event.sessionID
                                    && model.detailComponent?.id == event.componentID
                                    && model.tab == "components"
                            })
                    }
                }
            } else {
                // Restore the catalog context the route was opened from only
                // after the hero has reached its original slot. The card then
                // appears in the same frame as the overlay disappears.
                model.query = event.returnQuery
                model.showOnOnly = event.returnOnOnly
                model.detailComponent = nil
                model.selectedComponent = nil
                presentation.commitClosed()
            }
        }
    }

    /// One type role for every section eyebrow: `ClamType.label(9.5)` at 1.0pt
    /// tracking. The count and the rule that closes the row carry the section's
    /// accent; every accent in `Theme` clears 4.5:1 on the window and 3:1 as a
    /// 1pt rule, so the tint is never the only difference.
    private func sectionLabel(_ title: String, count: Int, accent: Color) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(ClamType.label(9.5))
                .tracking(1.0)
                .foregroundStyle(Theme.textSecondary)
            Text(String(format: "%02d", count))
                .font(ClamType.mono(9.5, .medium))
                .foregroundStyle(accent)
                .monospacedDigit()
            Rectangle().fill(accent.opacity(0.8)).frame(height: 1)
        }
        .padding(.top, 2)
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            TextField("Find a component…", text: $model.query)
                .textFieldStyle(.plain).font(ClamType.body(13))
                .focused($searchFocused).accessibilityLabel("Search components")
            if !model.query.isEmpty {
                Button { withAnimation(motion) { model.query = "" } } label: {
                    Text("×").font(ClamType.body(14, .semibold)).foregroundStyle(Theme.textTertiary)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            } else {
                // Two keycaps rather than one inline hint: each key gets its
                // own bordered grey box so the shortcut reads at a glance.
                HStack(spacing: 5) {
                    keycap("⌘")
                    keycap("F")
                }
            }
        }
        .padding(.horizontal, 12).frame(width: 238, height: 36)
        .background(PixelShape(cut: 2).fill(Theme.sidebar))
        .overlay(PixelShape(cut: 2).strokeBorder(searchFocused ? Theme.gold.opacity(0.6) : Theme.stroke))
    }

    private func keycap(_ symbol: String) -> some View {
        Text(symbol)
            .font(ClamType.mono(13, .medium))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 22, height: 22)
            .background(PixelShape(cut: 2).fill(Theme.control))
            .overlay(PixelShape(cut: 2).strokeBorder(Theme.strokeHover))
            .accessibilityHidden(true)
    }

    private var chips: some View {
        HStack(spacing: 2) {
            filterButton("All", count: total, onOnly: false)
            filterButton("On", count: onCount, onOnly: true)
        }
        .padding(3)
        .background(PixelShape(cut: 3).fill(Theme.secondary))
        .overlay(PixelShape(cut: 3).strokeBorder(Theme.stroke))
        .fixedSize(horizontal: true, vertical: false)
    }

    private func filterButton(_ title: String, count: Int, onOnly: Bool) -> some View {
        let selected = model.showOnOnly == onOnly
        return Button {
            withAnimation(motion) { model.showOnOnly = onOnly }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(ClamType.body(13, .medium))
                    .foregroundStyle(selected ? Theme.ink : Theme.textSecondary)
                Text(String(format: "%02d", count))
                    .font(ClamType.mono(10.5, .medium))
                    .foregroundStyle(selected ? Theme.textSecondary : Theme.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background {
                if selected {
                    PixelShape(cut: 2)
                        .fill(Theme.chipHover)
                        .overlay(PixelShape(cut: 2).strokeBorder(Theme.stroke))
                        .matchedGeometryEffect(id: "filter-selection", in: filterIndicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(onOnly ? "On components, \(count)" : "All components, \(count)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ComponentSprite(componentID: "agentScreen", isOn: false)
            PixelText(text: model.query.isEmpty ? "A quiet workspace" : "No components found", pixel: 2)
            Text(model.query.isEmpty ? "Turn on a component in All to see it here." : "Try another name or clear your search.")
                .font(ClamType.body(12)).foregroundStyle(Theme.textSecondary)
            Button(model.query.isEmpty ? "Explore all components" : "Clear search") {
                withAnimation(motion) {
                    if model.query.isEmpty { model.showOnOnly = false }
                    else { model.query = "" }
                }
            }.buttonStyle(PixelButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 44)
    }
}

// Alias keeps the intent explicit; eager grids prevent lazy insertion flashes.
private struct VGrid<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View { ComponentGridLayout(spacing: spacing) { content() } }
}

// MARK: - Component card

struct ComponentCard: View {
    let component: ComponentDefinition
    let isOn: Bool
    var onToggle: () -> Void
    var onOpen: () -> Void

    @State private var hover = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accent: Color { Theme.accent(component.category) }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                // CardHeader: icon (leading) and the switch
                HStack(alignment: .center, spacing: 8) {
                    ComponentSprite(componentID: component.icon, isOn: isOn, isHovered: hover,
                                 size: ComponentCardMetrics.iconSize)

                    Spacer(minLength: 4)

                    // Reserve the switch's layout slot inside the button, but
                    // keep the real control as a sibling overlay. A control
                    // nested inside the card button let one gesture compete
                    // with the other and could open detail from a switch drag.
                    Color.clear
                        .frame(width: ComponentCardMetrics.switchWidth, height: 20)
                }
                .padding(.horizontal, ComponentCardMetrics.cardPadding)
                .padding(.top, ComponentCardMetrics.cardIconTop)

                // CardTitle + CardDescription
                VStack(alignment: .leading, spacing: 5) {
                    Text(component.name)
                        .font(ClamType.name(15))
                        .tracking(-0.1)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    Text(component.tagline)
                        .font(ClamType.body(12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ComponentCardMetrics.cardPadding)
                .padding(.top, 14)
                .padding(.bottom, 16)

                Spacer(minLength: 0)
            }
            .frame(minHeight: ComponentCardMetrics.cardMinHeight, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: ComponentCardMetrics.radius, style: .continuous)
                    .fill(hover ? Theme.cardHover : Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ComponentCardMetrics.radius, style: .continuous)
                    .strokeBorder(hover ? Theme.hoverOutline : Theme.stroke, lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .overlay(
                ComponentActivationStroke(
                    shape: RoundedRectangle(cornerRadius: ComponentCardMetrics.radius, style: .continuous),
                    isOn: isOn, color: accent.opacity(0.70))
            )
        }
        .buttonStyle(ComponentPressStyle(scales: false))
        .overlay(alignment: .topTrailing) {
            ClamSwitch(isOn: isOn, action: onToggle)
                .accessibilityLabel("Enable \(component.name)")
                .padding(.trailing, ComponentCardMetrics.cardPadding)
                .padding(.top, ComponentCardMetrics.cardSwitchTop)
        }
        // Focus must not masquerade as enablement. Neutral pixel brackets stay
        // legible for keyboard navigation without leaving a second gold outline
        // behind when the activation trace retracts.
        .overlay(
            ComponentFocusCorners()
                .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .square))
                .padding(-3)
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focused)
        .onHover { hover = $0 }
    }
}

private struct ComponentPressStyle: ButtonStyle {
    var scales = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion || !scales ? 1 : (configuration.isPressed ? 0.965 : 1))
            .brightness(configuration.isPressed ? 0.025 : 0)
            .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Switch

struct ClamSwitch: View {
    let isOn: Bool
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    @GestureState private var dragTranslation: CGFloat? = nil

    private let width: CGFloat = 40
    private let height: CGFloat = 20
    private let knob: CGFloat = 14
    private var travel: CGFloat { width - knob - 4 }
    private var knobX: CGFloat {
        min(travel, max(0, (isOn ? travel : 0) + (dragTranslation ?? 0)))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            PixelShape(cut: 2)
                .fill(isOn ? Theme.gold : (hover ? Theme.switchTrackHover : Theme.switchTrack))
                .overlay(PixelShape(cut: 2).strokeBorder(isOn ? Theme.goldSoft.opacity(0.9) : Theme.strokeHover, lineWidth: 1))
                .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: isOn)
                .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
            Rectangle()
                .fill(Theme.switchKnob)
                .frame(width: knob, height: knob)
                .overlay(Rectangle().strokeBorder(Theme.switchKnobBorder, lineWidth: 1))
                .offset(x: 2 + knobX)
                .animation(dragTranslation != nil ? nil : AppMotion.animation(.control, reduceMotion: reduceMotion), value: knobX)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { action() }
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in state = value.translation.width }
            .onEnded { value in
                let wanted = SwitchDragPolicy.desiredState(isOn: isOn,
                    translation: Double(value.translation.width), travel: Double(travel))
                if wanted != isOn { action() }
            })
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAction { action() }
    }
}

// MARK: - Icons

enum ComponentIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage {
        if let cached = cache[name] { return cached }
        if let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Icons"),
           let image = NSImage(contentsOf: url) {
            cache[name] = image
            return image
        }
        let fallback = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil) ?? NSImage()
        cache[name] = fallback
        return fallback
    }
}

// MARK: - Component detail

/// The one value a component's paragraph lets you change inline.
struct ComponentTunable {
    let key: String
    let label: String
    let fallback: Int
    let range: ClosedRange<Int>
    let step: Int
    let style: ValueChip.Style

    var binding: Binding<Int> {
        Binding(
            get: {
                let raw = UserDefaults.standard.object(forKey: key) as? Int ?? fallback
                return min(range.upperBound, max(range.lowerBound, raw))
            },
            set: { newValue in
                UserDefaults.standard.set(min(range.upperBound, max(range.lowerBound, newValue)), forKey: key)
            })
    }

    /// Settings use round steps (1, 5, 10, …), not a lower-bound offset
    /// (1, 6, 11, …). Keep both endpoints and the saved value selectable so
    /// starting a scrub cannot silently snap an existing setting.
    var domain: InlineValueDomain {
        let strideSize = max(1, step)
        let first = Int(ceil(Double(range.lowerBound) / Double(strideSize))) * strideSize
        let roundValues = Array(stride(from: first, through: range.upperBound, by: strideSize))
        return .explicit(roundValues + [range.lowerBound, range.upperBound, binding.wrappedValue])
    }

    /// A second (or third) number in the same sentence. Each token names its
    /// own setting, so one component can carry several independent values.
    static func forToken(_ token: String, componentID: String) -> ComponentTunable? {
        switch (componentID, token) {
        case ("finishWorkThenSleep", "{hours}"):
            return ComponentTunable(key: "finishWorkThenSleep.maxHours", label: "Longest stretch", fallback: 12,
                                    range: 1...24, step: 1, style: .hours)
        case ("finishJobsThenSleep", "{hours}"):
            return ComponentTunable(key: "finishJobsThenSleep.maxHours", label: "Longest stretch", fallback: 8,
                                    range: 1...24, step: 1, style: .hours)
        default:
            return token == "{value}" ? forComponent(componentID) : nil
        }
    }

    static func forComponent(_ id: String) -> ComponentTunable? {
        switch id {
        case "finishWorkThenSleep":
            return ComponentTunable(key: "finishWorkThenSleep.waitMinutes", label: "Wait limit", fallback: 15,
                                 range: 1...240, step: 5, style: .minutes)
        case "finishJobsThenSleep":
            return ComponentTunable(key: "finishJobsThenSleep.waitMinutes", label: "Wait limit", fallback: 2,
                                 range: 1...120, step: 1, style: .minutes)
        case "sleepWhenIdle":
            return ComponentTunable(key: "sleepWhenIdle.minutes", label: "Time before sleep", fallback: 15,
                                 range: 1...240, step: 5, style: .minutes)
        case "agentScreen":
            return ComponentTunable(key: "agentScreen.minutes", label: "Display off after", fallback: 2,
                                 range: 1...60, step: 1, style: .minutes)
        case "awakeWhileConnected":
            return ComponentTunable(key: "awakeWhileConnected.graceMinutes", label: "Time armed after the last connection", fallback: 10,
                                 range: 1...120, step: 5, style: .minutes)
        case "agentLight":
            return ComponentTunable(key: "agentLight.minutes", label: "Green for", fallback: 60,
                                 range: 15...720, step: 15, style: .minutes)
        case "fanBoost":
            return ComponentTunable(key: "fanBoost.percent", label: "Fan speed", fallback: 100,
                                 range: 30...100, step: 10, style: .percent)
        case "batteryBudget":
            return ComponentTunable(key: "batteryBudget.percent", label: "Disarm on low battery threshold", fallback: 15,
                                 range: 5...60, step: 5, style: .percent)
        case "cleaningLock":
            return ComponentTunable(key: "cleaningLock.seconds", label: "Lock for", fallback: 60,
                                 range: 15...300, step: 15, style: .seconds)
        case "sleepUntilReset":
            return ComponentTunable(key: "sleepUntilReset.idleMinutes", label: "Wait limit", fallback: 30,
                                 range: 5...240, step: 5, style: .minutes)
        default:
            return nil
        }
    }
}

/// Paragraph and options shown inside the wide detail page. Every token in
/// the sentence is a live control, so the explanation and the setting are the
/// same object rather than a paragraph plus a separate panel of sliders.
private struct ComponentDetailContent: View {
    let component: ComponentDefinition
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var guides = GuideCoordinator.shared
    /// Bumped after Restore Defaults so controls that read UserDefaults
    /// directly are rebuilt with the restored values.
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if guides.isPresented && component.id == HighlightTourStep.demonstrationComponentID {
                tourDetail
            } else {
            if let chips = inlineChips, !chips.isEmpty {
                InlineChipText(text: component.detail, chips: chips)
                    .font(ClamType.body(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.ink)
            } else {
                Text(component.detail.replacingOccurrences(of: "{value}", with: ""))
                    .font(ClamType.body(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if component.needsHelper, !helperInstalled {
                VStack(alignment: .leading, spacing: 4) {
                    Label(helperRequirementText, systemImage: "lock.shield")
                        .font(ClamType.body(11.5))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    if let refusal = ComponentEngine.shared.enablementReason(for: component.id),
                       !model.isOn(component.id) {
                        Text(refusal)
                            .font(ClamType.body(11))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            ComponentPermissionStatusView(componentID: component.id)
            if !model.enablementNotice.isEmpty {
                Text(model.enablementNotice)
                    .font(ClamType.body(11.5))
                    .foregroundStyle(Theme.goldSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ComponentOptions(component: component)

            if ComponentDefaults.isModified(component.id) {
                Button("Restore Defaults") {
                    ComponentDefaults.restore(component.id)
                    revision += 1
                }
                .buttonStyle(.plain)
                .font(ClamType.body(12, .medium))
                .foregroundStyle(Theme.textSecondary)
                .underline()
            }
            }
        }
        .onChange(of: revision) { _, _ in SettingsModel.shared.refresh() }
    }

    private var tourDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            InlineChipText(text: component.detail, chips: ["{value}": AnyView(
                InlineValueChip(value: $guides.demoMinutes,
                                domain: .explicit(Array(stride(from: 15, through: 720, by: 15))),
                                format: ValueChip.Style.minutes.inlineFormat,
                                accessibilityName: "Practice time")
                    .fixedSize()
                    .tourTarget("inlineOption").tourTarget("optionEditor")
            )])
            .font(ClamType.body(12.5)).foregroundStyle(Theme.ink)
            .tourTarget("componentDetail")
            Text("Practice only. This value isn't saved and the component stays as it was.")
                .font(ClamType.body(11.5)).foregroundStyle(Theme.textTertiary)
        }
    }

    /// Every inline control this component's sentence can carry.
    private var inlineChips: [String: AnyView]? {
        var chips: [String: AnyView] = [:]
        for token in ["{value}", "{hours}"] where component.detail.contains(token) {
            guard let tunable = ComponentTunable.forToken(token, componentID: component.id) else { continue }
            chips[token] = AnyView(
                InlineValueChip(value: tunable.binding,
                                domain: tunable.domain,
                                format: tunable.style.inlineFormat,
                                accessibilityName: tunable.style.accessibilityQuantity))
        }
        if component.detail.contains("{screen}") {
            let alwaysOn = component.id == "alwaysOnPluggedIn"
            let key = alwaysOn ? "alwaysOnPluggedIn.keepScreenOn" : "keepAwake.keepScreenOn"
            chips["{screen}"] = AnyView(InlineCycleChip(
                selection: boolChoice(key, fallback: !alwaysOn),
                options: [("on", true), ("off", false)]))
        }
        if component.detail.contains("{sound}") {
            // A two-state phrase changes in place, exactly like Password After
            // Close's display and timing chips; only real lists get a menu.
            chips["{sound}"] = AnyView(InlineCycleChip(
                selection: boolChoice("agentNotifications.sound", fallback: true),
                options: [("with sound", true), ("without sound", false)]))
        }
        if component.detail.contains("{drive}") {
            chips["{drive}"] = AnyView(InlineCycleChip(
                selection: boolChoice("ejectOnSleep.remount", fallback: true),
                options: [("come back", true), ("stay ejected", false)]))
        }
        if component.detail.contains("{display}") {
            chips["{display}"] = AnyView(InlineCycleChip(
                selection: boolChoice("passwordAfterClose.externalDisplay", fallback: false),
                options: [("with no display connected", false),
                          ("even with a display connected", true)]))
        }
        if component.detail.contains("{timing}") {
            chips["{timing}"] = AnyView(InlineCycleChip(
                selection: boolChoice("passwordAfterClose.immediate", fallback: true),
                options: [("at once", true), ("after the usual delay", false)]))
        }
        return chips.isEmpty ? nil : chips
    }

    private func boolChoice(_ key: String, fallback: Bool) -> Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback },
            set: { UserDefaults.standard.set($0, forKey: key) })
    }

    private var helperInstalled: Bool {
        if case .installed = HelperClient.shared.installState { return true }
        return false
    }

    private var helperRequirementText: String {
        "Needs the Wakely Helper. Choose Set Up; macOS asks for your administrator password once. No Apple ID is required."
    }
}

// MARK: - General

private struct GeneralPane: View {
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    @ObservedObject private var guides = GuideCoordinator.shared
    @ObservedObject private var appearance = AppAppearance.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var permissions = ComponentPermissions.shared
    @ObservedObject private var updates = UpdateManager.shared
    @State private var copiedDiagnostics = false
    @State private var helperCheckPending = true
    @FocusState private var gettingStartedFocused: Bool
    @Environment(\.wakelyPaneIsActive) private var paneIsActive

    private var helperStateTitle: String {
        if helperCheckPending { return "Checking helper…" }
        if permissions.helperReachable { return "Helper ready" }
        if permissions.helperNeedsApproval { return "Waiting for approval" }
        if permissions.helperInstalled { return "Installed, not responding" }
        return "One-time setup"
    }

    var body: some View {
        VStack(spacing: 0) {
        Color.clear.frame(height: 82).accessibilityHidden(true)
        ScrollViewReader { proxy in
        EdgeScrollView {
            VStack(alignment: .leading, spacing: 26) {
                section("APPEARANCE") {
                    PixelMenu(title: "Appearance", selection: $appearance.choice,
                              options: AppearanceChoice.allCases.map { (label: $0.title, value: $0) })
                        .padding(14)
                        .transaction { $0.animation = nil }
                }
                .id("tour-general").tourTarget("general")

                section("GETTING STARTED") {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("A tour of the real controls").font(ClamType.body(13, .semibold))
                            Text("Follow the highlights through a component, its options, creation tools, settings and the menu. Practice changes aren't saved.")
                                .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if guides.canResume {
                            Button("Start over") { guides.showOnboarding(restart: true) }
                        }
                        Button(guides.gettingStartedActionTitle) {
                            guides.showOnboarding(restart: !guides.canResume)
                        }
                        .focused($gettingStartedFocused)
                        .onChange(of: guides.returnFocusSerial) { _, _ in
                            guard guides.returnFocusID == "gettingStarted" else { return }
                            DispatchQueue.main.async {
                                if !guides.isPresented && SettingsModel.shared.tab == "general" {
                                    gettingStartedFocused = true
                                }
                            }
                        }
                    }.padding(14)
                }

                section("STARTUP") {
                    toggleRow("Open at login", isOn: $state.launchAtLogin)
                    divider
                    toggleRow("Check for updates automatically", isOn: $updates.automaticChecks)
                }

                section("UPDATES") {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(updateStatusTitle)
                                .font(ClamType.body(13, .semibold))
                            if !updateStatusDetail.isEmpty {
                                Text(updateStatusDetail)
                                    .font(ClamType.body(11.5))
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let installError = updates.installError {
                                Text(installError)
                                    .font(ClamType.body(11.5))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        if updates.installing {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Check for Updates") {
                                Task { await updates.checkForUpdates() }
                            }
                            .disabled(updates.status == .checking)
                            if case .available(_, let url) = updates.status {
                                Button("Update Now") {
                                    Task { await updates.installUpdate(from: url) }
                                }
                            }
                        }
                    }
                    .padding(14)
                }

                section("PRIVILEGED HELPER") {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(helperStateTitle)
                                .font(ClamType.body(13))
                                .fontWeight(.semibold)
                            Text("Every helper component shares this one installation. macOS asks for your administrator password once; no Apple ID is required.")
                                .font(ClamType.body(11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !permissions.message.isEmpty {
                                Text(permissions.message)
                                    .font(ClamType.body(11))
                                    .foregroundStyle(Theme.goldSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        if helperCheckPending || permissions.checking {
                            ProgressView().controlSize(.small)
                        } else if permissions.helperReachable {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.green)
                                .accessibilityLabel("Helper ready")
                        } else if permissions.helperNeedsApproval {
                            Button("Open Login Items") { permissions.openSettings(for: .helper) }
                        } else {
                            Image(systemName: "lock.shield")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.goldSoft)
                            Button(permissions.helperInstalled ? "Repair Helper…" : "Set Up Helper…") {
                                permissions.installHelperForAll()
                            }
                        }
                    }
                    .padding(14)
                }
                .task(id: paneIsActive) {
                    guard paneIsActive else { return }
                    await permissions.refresh()
                    guard !Task.isCancelled else { return }
                    helperCheckPending = false
                }

                section("SAFETY") {
                    // `section` already draws the panel; a second one inside it
                    // gave SAFETY a double border and a double shadow.
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("Disarm on low battery").font(ClamType.body(13, .semibold))
                            Spacer()
                            ClamSwitch(isOn: state.lowBatteryGuard) { state.lowBatteryGuard.toggle() }
                        }
                        Text("Disarms at 20% battery while unplugged. Thermal protection stays on regardless of this setting.")
                            .font(ClamType.body(11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }

                section("SUPPORT") {
                    // Top-aligned: the Copy button sits on the title's line
                    // instead of centring on the two-line block beneath it.
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Copy diagnostics for support").font(ClamType.body(13, .semibold))
                            Text("Copies the log you can paste anywhere. Nothing is sent.")
                                .font(ClamType.body(11.5))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        Button(copiedDiagnostics ? "Copied" : "Copy") { copyDiagnostics() }
                            .buttonStyle(PixelButtonStyle())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }

                section("DELETE WAKELY") {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Delete Wakely from this Mac")
                                .font(ClamType.body(13, .semibold))
                            Text("Removes the helper, watchdog, login items, macOS permissions, settings and data, then moves Wakely to the Trash.")
                                .font(ClamType.body(11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let deleteError {
                                Text(deleteError)
                                    .font(ClamType.body(11.5))
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 8)
                        Button(deleting ? "Deleting…" : "Delete Wakely…", role: .destructive) { confirmDelete = true }
                            .buttonStyle(PixelButtonStyle())
                            .disabled(deleting)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .alert("Delete Wakely completely?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) {
                        deleting = true
                        deleteError = nil
                        Task {
                            deleteError = await AppUninstaller.deleteEverything()
                            deleting = false
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Wakely restores the system settings it changed, removes its helper and permissions, and quits. macOS may ask for your administrator password.")
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 96)
        }
        .scrollIndicators(.hidden)
        .task(id: "\(guides.generation)-\(guides.progress.step)-\(guides.isPresented)") {
            guard guides.isPresented, guides.currentTourStep == .general || guides.currentTourStep == .finish else { return }
            await Task.yield()
            proxy.scrollTo("tour-general", anchor: .top)
        }
        .onChange(of: guides.returnFocusSerial) { _, _ in
            if !guides.isPresented && SettingsModel.shared.tab == "general" {
                proxy.scrollTo("GETTING STARTED", anchor: .center)
            }
        }
        }
        }
    }

    private var updateStatusTitle: String {
        switch updates.status {
        case .idle:
            return "Wakely \(updates.currentVersion)"
        case .checking:
            return "Checking for updates…"
        case .upToDate:
            return "Wakely \(updates.currentVersion) is up to date"
        case .available(let version, _):
            return "Wakely \(version) is available"
        case .failed:
            return "Update check failed"
        }
    }

    private var updateStatusDetail: String {
        switch updates.status {
        case .idle:
            return "Running Wakely \(updates.currentVersion). New releases are announced here and once at launch."
        case .checking:
            return ""
        case .upToDate:
            return "You're running the latest release."
        case .available:
            return "Download installs the signed update, then offers a restart."
        case .failed(let message):
            return message
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.horizontal, 14)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>, disabled: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(ClamType.body(13, .semibold))
                .foregroundStyle(disabled ? Theme.textTertiary : Theme.ink)
            Spacer()
            ClamSwitch(isOn: isOn.wrappedValue) { if !disabled { isOn.wrappedValue.toggle() } }
                .disabled(disabled)
                .opacity(disabled ? 0.4 : 1)
        }
        .padding(14)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(ClamType.label(9.5))
                .tracking(1.0)
                .foregroundStyle(Theme.section)
            VStack(spacing: 0) { content() }
                .pixelPanel(fill: Theme.card, border: Theme.stroke, cut: 4)
        }
        .id(title)
    }

    private func copyDiagnostics() {
        let url = Diagnostics.supportDirectory.appendingPathComponent("diagnostics.log")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "no diagnostics yet"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedDiagnostics = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedDiagnostics = false }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 0) {
        Color.clear.frame(height: 82).accessibilityHidden(true)
        EdgeScrollView {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: BrandIcon.appImage ?? NSImage())
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wakely").font(ClamType.name(16.1))
                    Text("Version \(AppVersion.current) · MIT licensed").font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            Text("Wakely is a free, MIT-licensed utility for Apple Silicon Macs. It keeps your Mac awake with the lid closed, so long downloads, renders, builds and agent sessions keep running while the machine stays shut.")
                .font(ClamType.body(12.5))
                .lineSpacing(2)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Label("Holds the power assertions that stop lid-close sleep", systemImage: "checkmark.seal")
                Label("Darkens the built-in display while a session is held", systemImage: "checkmark.seal")
                Label("Opt-in components for power, security, connections and agents", systemImage: "checkmark.seal")
                Label("Runs entirely on your Mac; no telemetry leaves the app", systemImage: "checkmark.seal")
            }
            .font(ClamType.body(12))
            .foregroundStyle(Theme.textSecondary)
            .padding(14)
            .pixelPanel(fill: Theme.card, border: Theme.stroke, cut: 4)
            Text("Source is MIT licensed: use it, change it, ship it. Licence notes ship alongside the code.")
                .font(ClamType.body(11))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 96)
        }
        }
    }
}


// MARK: - Per-component options

struct ComponentOptions: View {
    let component: ComponentDefinition
    @ObservedObject private var actionState = SettingsModel.shared

    @AppStorage("lidCloseSoundName") private var soundName = "shell"
    @AppStorage("batteryBudget.percent") private var budget = 15
    @AppStorage("sleepTimer.minutes") private var timerMinutes = 30
    @AppStorage("keepAwake.minutes") private var keepMinutes = 120
    @AppStorage("armOnSchedule.start") private var scheduleStart = "22:00"
    @AppStorage("armOnSchedule.end") private var scheduleEnd = "07:00"
    @AppStorage("armOnWiFi.ssid") private var ssid = ""
    @AppStorage("armWhileAppRuns.bundleID") private var appBundleID = ""
    @AppStorage("lidShortcuts.close") private var closeShortcut = ""
    @AppStorage("lidShortcuts.open") private var openShortcut = ""
    @AppStorage("fanBoost.percent") private var fanPercent = 100
    @AppStorage("agentLight.minutes") private var agentLightMinutes = 60
    @AppStorage("agentNotifications.sound") private var notifySound = true
    @AppStorage("agentNotifications.waiting") private var notifyWaiting = true
    @AppStorage("agentNotifications.finished") private var notifyFinished = true
    @AppStorage("ejectOnSleep.remount") private var remountDrives = true
    @AppStorage("finishWorkThenSleep.waitMinutes") private var finishWaitMinutes = 15
    @AppStorage("finishWorkThenSleep.maxHours") private var finishMaxHours = 12
    @AppStorage("sleepWhenIdle.minutes") private var idleMinutes = 15
    @AppStorage("agentScreen.minutes") private var screenMinutes = 2
    @AppStorage("sleepUntilReset.idleMinutes") private var resetIdleMinutes = 30
    @AppStorage("sleepUntilReset.waitingMinutes") private var resetWaitingMinutes = 15
    @AppStorage("finishJobsThenSleep.waitMinutes") private var jobsWaitMinutes = 2
    @AppStorage("finishJobsThenSleep.maxHours") private var jobsMaxHours = 8
    @AppStorage("awakeWhileConnected.graceMinutes") private var connectionGraceMinutes = 10
    @AppStorage("passwordAfterClose.externalDisplay") private var lockWithExternalDisplay = false
    @AppStorage("passwordAfterClose.immediate") private var lockImmediately = true

    @State private var lockSeconds = 60
    @State private var appName = ""
    @State private var scheduleDays = Set(UserDefaults.standard.array(forKey: "armOnSchedule.weekdays") as? [Int] ?? Array(1...7))
    @State private var selectedDriveIDs = Set(UserDefaults.standard.stringArray(forKey: "armWhenDriveConnects.volumeIDs") ?? [])
    @State private var availableDrives: [URL] = []
    @State private var protectedReason = ""
    @State private var protectedReady = false
    @State private var protectedBusy = false
    @State private var protectedLease = false
    @State private var resetAt = Date().addingTimeInterval(3600)
    @State private var detectedResets: [UsageLimitReset] = []
    @State private var availableShortcuts: [String] = []
    @State private var knownNetworks: [String] = []

    var body: some View {
        Group {
            switch component.id {
            case "lidCloseSound":
                row {
                    PixelMenu(title: "Sound", selection: $soundName,
                              options: CloseSoundPlayer.availableSounds.map { ($0.capitalized, $0) })
                    Button {
                        CloseSoundPlayer.shared.play(preview: true)
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2.fill")
                    }
                }
                .onChange(of: soundName) { _, _ in CloseSoundPlayer.shared.prepare() }
            case "batteryBudget":
                Text("Only time on battery counts; opening the lid resets it.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "sleepTimer":
                row {
                    PixelMenu(title: "Sleep after", selection: $timerMinutes,
                              options: [("15 minutes", 15), ("30 minutes", 30),
                                        ("1 hour", 60), ("2 hours", 120)])
                }
            case "sleepWhenIdle":
                Text("Counted only while nothing is downloading, copying, playing audio or using the CPU.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "keepAwake":
                row {
                    PixelMenu(title: "Stay awake for", selection: $keepMinutes,
                              options: [("Indefinitely", 0), ("1 hour", 60),
                                        ("2 hours", 120), ("4 hours", 240)])
                }
                .onChange(of: keepMinutes) { _, minutes in
                    guard ComponentEngine.shared.isEnabled("keepAwake") else { return }
                    ComponentEngine.shared.startKeepAwake(minutes: minutes == 0 ? nil : minutes,
                                                              source: .settings)
                }
            case "awakeWhileConnected":
                Text("Arms only while on the charger with the lid open.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "armOnSchedule":
                VStack(alignment: .leading, spacing: 8) {
                    row {
                        TextField("Start (HH:mm)", text: $scheduleStart).frame(width: 90)
                        Text("to").foregroundStyle(Theme.textSecondary)
                        TextField("End (HH:mm)", text: $scheduleEnd).frame(width: 90)
                        Spacer()
                    }
                    row {
                        ForEach(Array(Calendar.current.shortWeekdaySymbols.enumerated()), id: \.offset) { index, name in
                            Toggle(name, isOn: Binding(get: { scheduleDays.contains(index + 1) }, set: { selected in
                                if selected { scheduleDays.insert(index + 1) } else { scheduleDays.remove(index + 1) }
                                UserDefaults.standard.set(scheduleDays.sorted(), forKey: "armOnSchedule.weekdays")
                            }))
                            .toggleStyle(PixelCheckToggleStyle())
                        }
                    }
                    Text("Overnight schedules belong to the day they start. Requires charger power.")
                        .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                }
            case "armWhenDriveConnects":
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(availableDrives, id: \.absoluteString) { volume in
                        let id = driveID(volume)
                        Toggle(volume.lastPathComponent, isOn: Binding(get: { selectedDriveIDs.contains(id) }, set: { selected in
                            if selected { selectedDriveIDs.insert(id) } else { selectedDriveIDs.remove(id) }
                            UserDefaults.standard.set(selectedDriveIDs.sorted(), forKey: "armWhenDriveConnects.volumeIDs")
                        }))
                    }
                    if availableDrives.isEmpty { Text("Connect a drive to choose it.").foregroundStyle(Theme.textSecondary) }
                    Button("Refresh drives") { availableDrives = Volumes.external() }
                    Text("Only selected drives can arm Wakely. Requires charger power.")
                        .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                }
                .onAppear { availableDrives = Volumes.external() }
            case "armOnWiFi":
                VStack(alignment: .leading, spacing: 8) {
                    if !knownNetworks.isEmpty {
                        row {
                            // An SSID can be 32 characters; the field below
                            // still shows the full name once it is chosen.
                            PixelMenu(title: "Known network", selection: $ssid,
                                      options: knownNetworks.map { (label: menuLabel($0), value: $0) })
                        }
                    }
                    row {
                        TextField("Wi-Fi network name", text: $ssid)
                        Button("Use current") {
                            if let current = WiFi.currentSSID() { ssid = current }
                        }
                    }
                }
                .task { await loadKnownNetworks() }
            case "armWhileAppRuns":
                row {
                    Text(appBundleID.isEmpty ? "No app chosen" : ComponentSpec.appName(for: appBundleID))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Choose App…") { chooseApp() }
                }
            case "lidShortcuts":
                VStack(alignment: .leading, spacing: 8) {
                    if availableShortcuts.isEmpty {
                        // No list to pick from (Shortcuts app missing or empty),
                        // so fall back to typing the Shortcut's exact name.
                        row { TextField("Shortcut on close", text: $closeShortcut) }
                        row { TextField("Shortcut on open", text: $openShortcut) }
                    } else {
                        row {
                            PixelMenu(title: "On close", selection: $closeShortcut,
                                      options: shortcutOptions)
                        }
                        // The menu shortens a long name so the value cannot
                        // widen past the sheet; the full name stays in the
                        // tooltip and in the menu's own list.
                        row {
                            PixelMenu(title: "On open", selection: $openShortcut,
                                      options: shortcutOptions)
                        }
                    }
                    Text(availableShortcuts.isEmpty
                         ? "Type the exact name of the Shortcut to run on each event."
                         : "Pick one of your Shortcuts; “—” runs nothing.")
                        .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                }
                .task { await loadAvailableShortcuts() }
            case "passwordAfterClose":
                // The display and timing choices are the sentence's own chips.
                Text("Touch ID for unlocking returns as soon as you unlock again.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "fanBoost":
                Text("Applied only while the lid is closed and the Mac is working hard, then handed back when it idles.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "agentLight":
                Text("After the last agent finishes, the light keeps showing done for this long.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "finishWorkThenSleep":
                Text("While the lid is closed, your Mac stays awake until the agents finish, then sleeps.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "finishJobsThenSleep":
                Text("Counts downloads, exports and backups; other apps' jobs are not waited for.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "agentScreen":
                Text("The display stays black but on while an agent uses it.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "agentNotifications":
                VStack(alignment: .leading, spacing: 8) {
                    row {
                        Toggle("When an agent needs you", isOn: $notifyWaiting)
                        Spacer(minLength: 0)
                    }
                    row {
                        Toggle("When an agent finishes", isOn: $notifyFinished)
                        Spacer(minLength: 0)
                    }
                }
            case "ejectOnSleep":
                Text("Drives are still only ejected when nothing is using them and the lid is closed.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "cleaningLock":
                Text("Turn on the switch to lock the keyboard and pointer for the time above. Hold Escape for three seconds to unlock early. The switch turns off when the lock ends.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                if !actionState.cleaningLockMessage.isEmpty {
                    Text(actionState.cleaningLockMessage)
                        .font(ClamType.body(12)).foregroundStyle(Theme.goldSoft)
                        .accessibilityLabel(actionState.cleaningLockMessage)
                }
            case "sleepUntilReset":
                Text("Uses the shared Wakely Helper. No separate administrator prompt is needed; turn it on above and Wakely schedules the wake itself.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            case "sleepMeansSleep":
                Text("Uses the shared Wakely Helper to suppress battery Power Nap, proximity wake and Wake-on-LAN while enabled. Other scheduled wake events are left alone.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
            default:
                EmptyView()
            }
        }
    }

    private func row<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .font(ClamType.body(13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(PixelShape(cut: 3).fill(Theme.ink.opacity(0.05)))
    }

    /// `PixelMenu` sizes its value to fit (`fixedSize`), so an unbounded
    /// Shortcut name or SSID would push the row wider than the sheet. Keeping
    /// the head and the tail leaves the part that tells two similar names
    /// apart, and the ellipsis is the typographic one.
    private func menuLabel(_ value: String, limit: Int = 22) -> String {
        guard value.count > limit else { return value }
        return "\(value.prefix(limit - 8))…\(value.suffix(6))"
    }

    /// "—" means no Shortcut, so the stored value stays empty rather than
    /// carrying a placeholder name the engine would try to run.
    private var shortcutOptions: [(label: String, value: String)] {
        [(label: "—", value: "")] + availableShortcuts.map { (label: menuLabel($0), value: $0) }
    }

    /// Reads the installed Shortcuts once per appearance. Missing tool, no
    /// shortcuts or a non-zero exit all leave the typed fallback in place.
    @MainActor private func loadAvailableShortcuts() async {
        guard let text = await Self.toolOutput("/usr/bin/shortcuts", ["list"]) else { return }
        availableShortcuts = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Reads the saved Wi-Fi networks once per appearance; the header line and
    /// blank lines are dropped, and any failure leaves the field-only UI.
    @MainActor private func loadKnownNetworks() async {
        guard let text = await Self.toolOutput("/usr/sbin/networksetup",
                                               ["-listpreferredwirelessnetworks", "en0"]) else { return }
        var lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if let header = lines.first, header.hasSuffix(":") || header.lowercased().contains("preferred networks") {
            lines.removeFirst()
        }
        knownNetworks = lines.filter { !$0.isEmpty }
    }

    /// Runs a short read-only command off the main actor. Returns nil instead of
    /// throwing so the settings pane never fails loudly when a tool is absent.
    private nonisolated static func toolOutput(_ path: String, _ arguments: [String]) async -> String? {
        await Task.detached(priority: .userInitiated) { () async -> String? in
            guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do { try process.run() } catch { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }.value
    }

    /// Read-only scan of the provider transcripts; never touches the network.
    private func loadDetectedResets() {
        let reader = UsageResetReader(roots: .live())
        let now = Date()
        detectedResets = reader.read().filter { $0.resetsAt > now }
            .sorted { $0.resetsAt < $1.resetsAt }
        if let next = detectedResets.first?.resetsAt { resetAt = next }
    }

    @MainActor private func refreshProtectedCapability() async {
        let service = PrivilegedComponentService.shared
        let capability = await service.inspectCapability(for: component.id, resetDate: component.id == "sleepUntilReset" ? resetAt : nil)
        protectedReady = capability.ready
        protectedReason = capability.reason
        protectedLease = service.hasActiveLease(component.id)
    }

    private func runProtectedOperation(restoring: Bool) {
        protectedBusy = true
        Task { @MainActor in
            defer { protectedBusy = false }
            do {
                if restoring { try await PrivilegedComponentService.shared.restore(componentID: component.id) }
                else { _ = try await PrivilegedComponentService.shared.apply(componentID: component.id, resetDate: component.id == "sleepUntilReset" ? resetAt : nil) }
                await refreshProtectedCapability()
                protectedReason = restoring ? "Previous settings restored and verified." : "Protected change applied and verified. Restore it here when finished."
            } catch {
                protectedLease = PrivilegedComponentService.shared.hasActiveLease(component.id)
                protectedReason = error.localizedDescription
            }
        }
    }

    private func driveID(_ url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
            ?? url.standardizedFileURL.path
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           let bundle = Bundle(url: url)?.bundleIdentifier {
            appBundleID = bundle
            appName = url.deletingPathExtension().lastPathComponent
        }
    }
}


// MARK: - User components (from Components/components/<id>/)

struct CustomComponentCard: View {
    let component: ComponentSpec
    @ObservedObject private var store = ComponentStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                CustomComponentSprite(lines: component.iconLines, isOn: store.isEnabled(component.id), isHovered: hover)
                Spacer()
                ClamSwitch(isOn: store.isEnabled(component.id)) {
                    store.setEnabled(component.id, !store.isEnabled(component.id))
                }.accessibilityLabel("Enable \(component.name)")
            }
            .padding(.horizontal, 16).padding(.top, 16)
            Spacer(minLength: 10)
            Text(component.name).font(ClamType.name(14.5)).lineLimit(1).padding(.horizontal, 14)
            Text(component.tagline).font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.top, 3).padding(.bottom, 14)
        }
        .frame(minHeight: 150, alignment: .top).frame(maxWidth: .infinity)
        .background(PixelShape(cut: 4).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(PixelShape(cut: 4).strokeBorder(hover ? Theme.hoverOutline : Theme.stroke, lineWidth: 1))
        .overlay(ComponentActivationStroke(shape: PixelShape(cut: 4),
                                           isOn: store.isEnabled(component.id),
                                           color: Theme.gold.opacity(0.70)))
        .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Edit with Your Agent") { store.copyPrompt(store.editPrompt(for: component.id)) }
            Button("Reveal in Finder") { NSWorkspace.shared.open(component.directory) }
            Divider()
            Button("Remove", role: .destructive) { store.remove(component.id) }
        }
    }
}

/// Renders the SDK's 32x32 letter icons (".nudbsliw") into an image.
enum SpriteRenderer {
    private static let palette: [Character: NSColor] = [
        "n": NSColor(red: 0.10, green: 0.07, blue: 0.03, alpha: 1),
        "u": NSColor(red: 0.18, green: 0.13, blue: 0.06, alpha: 1),
        "d": NSColor(red: 0.31, green: 0.22, blue: 0.09, alpha: 1),
        "b": NSColor(red: 0.92, green: 0.64, blue: 0.10, alpha: 1),
        "s": NSColor(red: 0.98, green: 0.78, blue: 0.25, alpha: 1),
        "l": NSColor(red: 1.00, green: 0.90, blue: 0.55, alpha: 1),
        "i": NSColor(red: 1.00, green: 0.96, blue: 0.80, alpha: 1),
        "w": NSColor.white
    ]

    static func image(lines: [String], size: CGFloat) -> NSImage {
        let grid = lines.map { $0.split(separator: "|").last.map(String.init) ?? $0 }
            .filter { $0.count >= 32 }
            .prefix(32)
        guard !grid.isEmpty else { return NSImage() }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let cell = size / 32
        for (y, line) in grid.enumerated() {
            for (x, char) in line.enumerated() {
                guard let color = palette[char] else { continue }
                color.setFill()
                NSRect(x: CGFloat(x) * cell, y: size - CGFloat(y + 1) * cell,
                       width: cell, height: cell).fill()
            }
        }
        image.unlockFocus()
        return image
    }
}


// MARK: - Make your own

struct MakeYourOwnCard: View {
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: "plus").font(.system(size: 20, weight: .light))
                        .foregroundStyle(hover ? Theme.gold : Theme.textTertiary)
                        .frame(width: 56, height: 56)
                        .background(PixelShape(cut: 4).fill(Theme.ink.opacity(hover ? 0.09 : 0.05)))
                    Spacer()
                }.padding(.horizontal, 14).padding(.top, 14)
                Spacer(minLength: 10)
                Text("Make your own component").font(ClamType.name(14.5))
                    .foregroundStyle(Theme.ink).lineLimit(1).padding(.horizontal, 14)
                Text("Describe a component and an AI coding agent builds it.")
                    .font(ClamType.body(11.5)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 3).padding(.bottom, 14)
            }
            .frame(minHeight: 150, alignment: .top).frame(maxWidth: .infinity)
            .background(PixelShape(cut: 4).fill(hover ? Theme.cardHover : Theme.card.opacity(0.6)))
            .overlay(PixelShape(cut: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(hover ? Theme.gold.opacity(0.9) : Theme.strokeHover))
        }
        .buttonStyle(.plain)
        .focusable()
        .onHover { hover = $0 }
        .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
    }
}

/// The sheet hands one prompt to the user's own coding agent. The prompt is
/// shown rather than copied blind: read-only, selectable, and scrolling inside
/// a bordered well, so the user sees exactly what they are about to hand over.
private struct MakeYourOwnSheet: View {
    /// Height the scrolling body may occupy; the footer gets the rest.
    var bodyCap: CGFloat = SheetLayout.bodyCap(windowHeight: 560)
    var onClose: () -> Void = {}
    @ObservedObject private var store = ComponentStore.shared
    @State private var copied = false
    /// Cancels the pending "Copied" reset when the sheet closes or is copied again.
    @State private var copiedReset: DispatchWorkItem?
    @FocusState private var copyFocused: Bool
    /// Measured height of the body; 0 until the first layout pass.
    @State private var contentHeight: CGFloat = 0

    /// Visible height of the prompt well; the text past it scrolls.
    private let promptHeight: CGFloat = 180

    private var prompt: String { store.newComponentPrompt }

    /// Content-sized while it fits, capped when it does not, so the footer
    /// buttons stay on-window in a short window.
    private var bodyHeight: CGFloat {
        min(contentHeight > 0 ? contentHeight : bodyCap, bodyCap)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EdgeScrollView(topFade: 24, bottomFade: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Make your own component").font(ClamType.name(17.1))
                        // The three steps, in one line, so the area explains itself.
                        Text("Copy the prompt, give it to your agent, and the component appears in the Custom group.")
                            .font(ClamType.body(12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .tourTarget("addComponentForm")

                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Text("PROMPT")
                                .font(ClamType.label(9.5))
                                .tracking(1.0)
                                .foregroundStyle(Theme.section)
                            Spacer(minLength: 0)
                            Text("Read-only")
                                .font(ClamType.mono(9))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        EdgeScrollView(topFade: 24, bottomFade: 32) {
                            Text(prompt)
                                .font(ClamType.mono(11.5))
                                .lineSpacing(2)
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: promptHeight)
                        .scrollIndicators(.hidden)
                        .background(PixelShape(cut: 3).fill(Theme.secondary))
                        .overlay(PixelShape(cut: 3).strokeBorder(Theme.strokeHover))
                        .accessibilityLabel("Prompt to give your coding agent")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your agent may ask once to read Wakely's component folder. Allow it, then say what your component should do.")
                            .font(ClamType.body(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("New components start off. To change one later, right-click its card and choose Edit with Your Agent.")
                            .font(ClamType.body(11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .pixelPanel(fill: Theme.card, border: Theme.stroke, cut: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: SheetBodyHeight.self, value: proxy.size.height)
                })
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: bodyHeight)
            .onPreferenceChange(SheetBodyHeight.self) { contentHeight = $0 }

            HStack(spacing: 8) {
                Button("Reveal component folder") { NSWorkspace.shared.open(store.componentsFolder) }
                Spacer(minLength: 0)
                // Escape must close the sheet itself, not reach the window
                // behind it; the visible button owns that shortcut.
                Button("Cancel") { onClose() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy prompt") { copyPrompt() }
                    .buttonStyle(PixelButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .focused($copyFocused)
                Button("Done") { onClose() }
            }
            .padding(.top, 14)
        }
        .padding(SheetLayout.padding)
        .frame(width: 460)
        .pixelPanel(fill: Theme.window, border: Theme.strokeHover, cut: 4)
        .modifier(AppAppearanceModifier())
        .onExitCommand { onClose() }
        .onAppear { copyFocused = !GuideCoordinator.shared.isPresented }
        .onDisappear {
            copiedReset?.cancel()
            copiedReset = nil
        }
    }

    /// Same confirmation pattern as the diagnostics button: the label flips to
    /// "Copied", then returns on its own after two seconds.
    private func copyPrompt() {
        guard !GuideCoordinator.shared.isPresented else { return }
        store.copyPrompt(prompt)
        copiedReset?.cancel()
        copied = true
        let reset = DispatchWorkItem { copied = false }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }
}

// MARK: - Invalid custom component

struct InvalidComponentCard: View {
    let id: String
    let errors: [String]
    @ObservedObject private var store = ComponentStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .frame(width: 56, height: 56)
                    .background(PixelShape(cut: 4).fill(Color.orange.opacity(0.10)))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer(minLength: 10)

            Text(id)
                .font(ClamType.name(14.5))
                .lineLimit(1)
                .padding(.horizontal, 14)
            Text(errors.first ?? "This component has an error.")
                .font(ClamType.body(11.5))
                .foregroundStyle(Color.orange.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.top, 3)
                .padding(.bottom, 14)
        }
        .frame(minHeight: 150, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(PixelShape(cut: 4).fill(hover ? Theme.cardHover : Theme.card))
        .overlay(PixelShape(cut: 4)
            .strokeBorder(Color.orange.opacity(hover ? 0.6 : 0.3), lineWidth: 1))
        .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
        .onHover { hover = $0 }
        .contextMenu {
            Button("Copy Fix Prompt") { store.copyPrompt(store.fixPrompt(for: id)) }
            Button("Reveal in Finder") { NSWorkspace.shared.open(store.componentsDirectory.appendingPathComponent(id)) }
            Divider()
            Button("Remove", role: .destructive) { store.remove(id) }
        }
    }
}
