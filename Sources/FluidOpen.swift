import AppKit
import QuartzCore

/// One window, one silhouette, three destinations. The compact menu is not an
/// NSMenu pop-up or a second window: it is the first state of the settings panel.
@MainActor
final class FluidOpen: NSObject {
    static let shared = FluidOpen()
    private var panel: FluidPanelWindow?
    private let canvas = NSView()
    private let glassBackdrop = GlassBackdropView(frame: .zero)
    private let compactGroup = GooContentGroup()
    private let settingsGroup = GooContentGroup()
    private let compactMask = CAShapeLayer()
    private let settingsMask = CAShapeLayer()
    private let chrome = GooChrome()
    private var menuView: GooMenuView?
    private var settingsController: NSViewController?
    private var anchorProvider: (() -> NSRect?)?
    private var layout: GooPanelLayout?
    private var coordinator = GooMotionCoordinator()
    private var displayLink: CADisplayLink?
    private var lastFrame = 0.0
    private var frameSamples = 0
    private var delayedFrames = 0
    private var maxFrameGap = 0.0
    private var maxPaintTime = 0.0
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var lastAnchorFrame: NSRect?
    private var currentBody = CGRect.zero
    // Height is another presentation track, not a second window animation.
    private var visibleScreen = CGRect.zero
    private var hasLayout = false

    var isCompactVisible: Bool { panel?.isVisible == true && coordinator.route == .compact }
    var needsMenuRefreshBeforeOpening: Bool { panel?.isVisible != true }
    var acceptsLiveMenuRefresh: Bool {
        isCompactVisible && coordinator.isSettled && menuView?.isNavigationInFlight != true
    }

    /// Read-only QA seam for an isolated panel screenshot. It never mutates
    /// settings or component state.
    var debugPanelWindow: NSWindow? { panel }

    func configure(menu: NSMenu, anchorProvider: @escaping () -> NSRect?,
                   perform: @escaping (NSMenuItem) -> Void) {
        self.anchorProvider = anchorProvider
        if let menuView { menuView.reload(menu: menu); return }
        let view = GooMenuView(menu: menu, perform: perform)
        view.onDismiss = { [weak self] in self?.dismiss() }
        view.onSizeChange = { [weak self] in self?.refreshLayout() }
        menuView = view
        compactGroup.addSubview(view)
    }

    func updateMenu(_ menu: NSMenu) { menuView?.reload(menu: menu) }

    /// Explicit, idempotent route for the real-menu leg of the user-started tour.
    func syncHighlightedTourMenu() {
        guard GuideCoordinator.shared.isPresented, GuideCoordinator.shared.isMenuTour else { return }
        menuView?.syncHighlightedTour()
        ensureWindow()
        coordinator.request(.compact)
        SettingsModel.shared.panelPresented = false
        SettingsModel.shared.panelSettled = false
        present()
    }

    func restoreSettingsAfterTour() {
        guard let content = settingsController, let anchorProvider else { return }
        menuView?.syncHighlightedTour()
        showSettings(content: content, anchorProvider: anchorProvider)
    }

    func toggleMenu() {
        menuView?.cancelNavigationAnimation()
        if coordinator.route != .hidden { ComponentPermissions.shared.panelWillHide() }
        ensureWindow()
        coordinator.toggle()
        SettingsModel.shared.panelPresented = coordinator.route == .settings
        SettingsModel.shared.panelSettled = false
        present()
    }

    func prepareSettings(content: NSViewController, anchorProvider: @escaping () -> NSRect?) {
        self.anchorProvider = anchorProvider
        ensureWindow()
        guard settingsController !== content else { return }
        settingsController?.view.removeFromSuperview()
        settingsController = content
        settingsGroup.addSubview(content.view)
        let started = CACurrentMediaTime()
        refreshLayout()
        content.view.layoutSubtreeIfNeeded()
        hideHostedScrollers(in: content.view)
        if let bitmap = content.view.bitmapImageRepForCachingDisplay(in: content.view.bounds) {
            content.view.cacheDisplay(in: content.view.bounds, to: bitmap)
        }
        if ProcessInfo.processInfo.environment["WAKELY_MOTION_DIAGNOSTICS"] == "1" {
            print(String(format: "motion.prepareSettings=%.2fms (before animation)", (CACurrentMediaTime() - started) * 1000))
        }
    }

    func showSettings(content: NSViewController, anchorProvider: @escaping () -> NSRect?) {
        menuView?.cancelNavigationAnimation()
        prepareSettings(content: content, anchorProvider: anchorProvider)
        if coordinator.route != .settings { SettingsModel.shared.panelSettled = false }
        SettingsModel.shared.panelPresented = true
        // Finish destination layout before the display link starts. The shell
        // animates a clip/translation, never the costly eager catalog layout.
        settingsController?.view.layoutSubtreeIfNeeded()
        coordinator.request(.settings)
        present()
    }

    func back() {
        menuView?.cancelNavigationAnimation()
        if GuideCoordinator.shared.isPresented {
            GuideCoordinator.shared.dismiss()
            return
        }
        if ComponentPermissions.shared.setupPresented {
            ComponentPermissions.shared.cancel()
            return
        }
        // The inner detail page owns Back before the panel route does. This is
        // what makes Escape during a card opening reverse the hero instead of
        // collapsing Settings back to the compact menu.
        if coordinator.route == .settings, SettingsModel.shared.detailComponent != nil {
            SettingsModel.shared.requestDetailBack()
            return
        }
        coordinator.back()
        SettingsModel.shared.panelPresented = coordinator.route == .settings
        SettingsModel.shared.panelSettled = false
        present()
    }

    func dismiss() {
        guard panel?.isVisible == true else { return }
        if GuideCoordinator.shared.isPresented { GuideCoordinator.shared.dismiss() }
        menuView?.cancelNavigationAnimation()
        ComponentPermissions.shared.panelWillHide()
        coordinator.request(.hidden)
        SettingsModel.shared.panelPresented = false
        SettingsModel.shared.panelSettled = false
        startAnimation()
    }

    func statusItemDidLayout() {
        let frame = anchorProvider?()
        guard frame != lastAnchorFrame else { return }
        lastAnchorFrame = frame
        if panel?.isVisible == true { refreshLayout() }
    }

    private func ensureWindow() {
        guard panel == nil else { return }
        let window = FluidPanelWindow(contentRect: .zero, styleMask: [.borderless],
                                      backing: .buffered, defer: false)
        window.title = "Wakely"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.animationBehavior = .none
        window.level = .floating
        window.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        window.tabbingMode = .disallowed
        window.acceptsMouseMovedEvents = true
        window.onBack = { [weak self] in self?.back() }
        window.onDismiss = { [weak self] in self?.dismiss() }
        window.onSettings = { (NSApp.delegate as? AppDelegate)?.openSettings() }
        window.onQuit = { (NSApp.delegate as? AppDelegate)?.quit() }
        canvas.wantsLayer = true
        canvas.autoresizingMask = [.width, .height]
        let noActions: [String: CAAction] = ["path": NSNull(), "bounds": NSNull(),
                                           "position": NSNull(), "opacity": NSNull()]
        for layer in [compactMask, settingsMask] { layer.actions = noActions }
        canvas.addSubview(glassBackdrop, positioned: .below, relativeTo: nil)
        for group in [compactGroup, settingsGroup] {
            group.wantsLayer = true
            group.autoresizingMask = []
            glassBackdrop.contentHost.addSubview(group)
        }
        compactGroup.layer?.mask = compactMask
        settingsGroup.layer?.mask = settingsMask
        chrome.onBack = { [weak self] in self?.back() }
        glassBackdrop.contentHost.addSubview(chrome)
        window.contentView = canvas
        panel = window
        installMonitors()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    private func present() {
        guard let panel else { return }
        let firstPresentation = !panel.isVisible
        refreshLayout()
        panel.title = coordinator.route == .settings ? "Wakely Settings" : "Wakely Quick Controls"
        if coordinator.route != .hidden {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if firstPresentation {
            // Commit the initial native material before starting its clock.
            // Never count window/IOSurface creation as elapsed spring time.
            panel.displayIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.panel?.isVisible == true else { return }
                self.startAnimation()
            }
        } else {
            startAnimation()
        }
    }

    private func refreshLayout() {
        guard let panel else { return }
        let rect = anchorProvider?()
        let screen = NSScreen.screens.first { screen in
            rect.map { screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
        } ?? NSScreen.main
        guard let screen else { return }
        let anchor = CGPoint(x: rect?.midX ?? screen.visibleFrame.midX,
                             y: screen.visibleFrame.maxY)
        visibleScreen = screen.visibleFrame
        // GooSpring's settling tolerances are normalized; keep this track in
        // menu-height units so a height change settles on the same timescale.
        coordinator.retargetCompactHeight(points: menuView?.preferredSize.height ?? 260)
        if !hasLayout || !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            coordinator.settleCompactHeight()
        }
        hasLayout = true
        // Reserve the largest menu once. Only the silhouette/content clip changes
        // height per frame; NSWindow has no competing frame animation.
        let next = GooPanelLayout(anchor: anchor, visibleScreen: visibleScreen,
                                 compactHeight: 620)
        layout = next
        if panel.frame != next.surface { panel.setFrame(next.surface, display: false) }
        let canvasFrame = NSRect(origin: .zero, size: next.surface.size)
        if canvas.frame != canvasFrame { canvas.frame = canvasFrame }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let compactFrame = local(next.compact, in: next)
        let settingsFrame = local(next.settings, in: next)
        if compactGroup.frame != compactFrame { compactGroup.frame = compactFrame }
        if settingsGroup.frame != settingsFrame { settingsGroup.frame = settingsFrame }
        if menuView?.frame != compactGroup.bounds { menuView?.frame = compactGroup.bounds }
        if settingsController?.view.frame != settingsGroup.bounds {
            settingsController?.view.frame = settingsGroup.bounds
        }
        CATransaction.commit()
        paint()
        if panel.isVisible { startAnimation() }
    }

    /// SwiftUI's hidden indicator policy does not suppress every overlay
    /// scroller in an AppKit-hosted hierarchy. Wakely intentionally has no
    /// visible scrollbar, so enforce the same contract on the hosting subtree.
    private func hideHostedScrollers(in view: NSView?) {
        guard let view else { return }
        if let scroll = view as? NSScrollView {
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.autohidesScrollers = true
        }
        for child in view.subviews { hideHostedScrollers(in: child) }
    }

    private func local(_ rect: CGRect, in layout: GooPanelLayout) -> CGRect {
        rect.offsetBy(dx: -layout.surface.minX, dy: -layout.surface.minY)
    }

    @objc private func accessibilityOptionsChanged() {
        // Material, contrast and motion all resolve from the same live display
        // notification. Rebuild the material before the next visual frame.
        paint()
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        settlePresentation()
    }

    private func settlePresentation() {
        coordinator.settle()
        menuView?.cancelNavigationAnimation()
        paint()
        finishIfSettled()
    }

    private func startAnimation() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            settlePresentation()
            return
        }
        guard displayLink == nil, let panel else { return }
        lastFrame = CACurrentMediaTime()
        frameSamples = 0; delayedFrames = 0; maxFrameGap = 0; maxPaintTime = 0
        let link = panel.displayLink(target: self, selector: #selector(frame(_:)))
        let maximumFPS = Float(max(1, panel.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximumFPS),
                                                        maximum: maximumFPS, preferred: maximumFPS)
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        // A callback queued behind orderOut/restart must not advance a newer
        // clock or order the reopened panel out.
        guard displayLink === link else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - lastFrame)
        lastFrame = now
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || elapsed > AppMotion.longFrameCutoff {
            settlePresentation()
            return
        }
        // Analytic integration is stable without discarding elapsed time.
        coordinator.advance(elapsed)
        let paintStart = CACurrentMediaTime()
        paint()
        maxPaintTime = max(maxPaintTime, CACurrentMediaTime() - paintStart)
        if frameSamples > 0 {
            maxFrameGap = max(maxFrameGap, elapsed)
            let budget = max(1.0 / 120.0, link.targetTimestamp - link.timestamp)
            if elapsed > budget * 2 { delayedFrames += 1 }
        }
        frameSamples += 1
        finishIfSettled()
    }

    private func finishIfSettled() {
        guard coordinator.isSettled else { return }
        if displayLink != nil, ProcessInfo.processInfo.environment["WAKELY_MOTION_DIAGNOSTICS"] == "1" {
            print(String(format: "motion.route=%@ frames=%d late(>2x)=%d maxGap=%.2fms maxPaint=%.2fms", String(describing: coordinator.route), frameSamples, delayedFrames, maxFrameGap * 1000, maxPaintTime * 1000))
        }
        displayLink?.invalidate()
        displayLink = nil
        if coordinator.route == .settings { SettingsModel.shared.panelSettled = true }
        if coordinator.route == .hidden {
            panel?.orderOut(nil)
            panel?.ignoresMouseEvents = false
        } else {
            panel?.title = coordinator.route == .settings ? "Wakely Settings" : "Wakely Quick Controls"
        }
    }

    private func paint() {
        guard let layout, let panel else { return }
        let presentation = GooPanelLayout(anchor: layout.anchor, visibleScreen: visibleScreen,
                                          compactHeight: coordinator.compactHeightPoints)
        let body = presentation.body(for: coordinator.motion)
        currentBody = body
        let localBody = local(body, in: layout)
        let apex = CGPoint(x: layout.anchor.x - layout.surface.minX,
                           y: layout.anchor.y - layout.surface.minY)
        let shape = GooShape(body: localBody, anchor: apex,
                             // The bridge must not run into the panel's own edges: the
                             // reference keeps a clear run of body top on either
                             // side of the neck. 30% each side leaves 40% as the
                             // bell, and never less than 36pt of flat edge.
                             flare: max(48, min(localBody.width * 0.22,
                                                localBody.width / 2 - 48)))
        let snapshot = coordinator.snapshot
        let expansion = CGFloat(snapshot.expansion)
        // No alpha ramp: a fading panel reads as a ghost that appears and
        // vanishes. It is on screen at full strength or hidden.
        let shown: CGFloat = snapshot.visibility > 0.001 ? 1 : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let compactFrame = local(presentation.compact, in: layout)
        if compactGroup.frame != compactFrame { compactGroup.frame = compactFrame }
        if menuView?.frame != compactGroup.bounds { menuView?.frame = compactGroup.bounds }
        if glassBackdrop.frame != canvas.bounds { glassBackdrop.frame = canvas.bounds }
        glassBackdrop.setShape(shape.path)
        // Keep the native material resident even at the initial tiny Goo nub;
        // window ordering, not material teardown, owns complete visibility.
        glassBackdrop.isHidden = false
        menuView?.usesMaterial = glassBackdrop.usesMaterial
        func clip(_ group: NSView, _ mask: CAShapeLayer) {
            var offset = CGAffineTransform(translationX: -group.frame.minX, y: -group.frame.minY)
            mask.frame = group.bounds
            mask.contentsScale = panel.backingScaleFactor
            mask.path = shape.bodyPath.copy(using: &offset)
        }
        clip(compactGroup, compactMask)
        clip(settingsGroup, settingsMask)
        let arrive = GooShape.smooth(CGFloat(snapshot.visibility), 0.18, 0.88)
        compactGroup.layer?.opacity = Float(arrive * (1 - GooShape.smooth(expansion, 0.05, 0.35)))
        settingsGroup.layer?.opacity = Float(arrive * GooShape.smooth(expansion, 0.18, 0.80))
        let hideCompact = expansion > 0.98 || shown < 0.01
        let hideSettings = expansion < 0.01 || shown < 0.01
        if compactGroup.isHidden != hideCompact { compactGroup.isHidden = hideCompact }
        if settingsGroup.isHidden != hideSettings { settingsGroup.isHidden = hideSettings }
        // Native hit testing ignores layer opacity/masks. Do not let an
        // invisible settings view eat a click intended for the small menu.
        compactGroup.acceptsInteraction = coordinator.route == .compact && expansion < 0.08 && arrive > 0.95
        settingsGroup.acceptsInteraction = coordinator.route == .settings && expansion > 0.92 && arrive > 0.95
        // Accessibility follows the same phase gate as pointer interaction:
        // a partially faded group is never a second semantic route.
        chrome.frame = CGRect(x: localBody.minX, y: localBody.maxY - 34,
                              width: localBody.width, height: 34)
        chrome.alphaValue = arrive * GooShape.smooth(expansion, 0.04, 0.24)
        chrome.isHidden = chrome.alphaValue < 0.01
        CATransaction.commit()
        updatePointerPolicy()
    }

    private func updatePointerPolicy(pointerEvent: Bool = false) {
        guard let panel, panel.isVisible else {
            menuView?.updatePointer(at: nil)
            return
        }
        let ignore = !currentBody.contains(NSEvent.mouseLocation)
        let point = !ignore && coordinator.route == .compact
            ? panel.convertPoint(fromScreen: NSEvent.mouseLocation) : nil
        menuView?.updatePointer(at: point, pointerEvent: pointerEvent)
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    private func outsideClick() {
        guard panel?.isVisible == true else { return }
        let mouse = NSEvent.mouseLocation
        if currentBody.contains(mouse) || anchorProvider?()?.contains(mouse) == true { return }
        dismiss()
    }

    private func installMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type != .mouseMoved { self?.outsideClick() }
                self?.updatePointerPolicy(pointerEvent: true)
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type != .mouseMoved { self?.outsideClick() }
                self?.updatePointerPolicy(pointerEvent: true)
            }
        }
    }
}

/// No drag handlers or resize grip: the only frame setter is status placement.
final class FluidPanelWindow: NSWindow {
    var onBack: (() -> Void)?
    var onDismiss: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ rect: NSRect, to screen: NSScreen?) -> NSRect { rect }
    override func performClose(_ sender: Any?) { onBack?() }
    override func close() { onBack?() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            if GuideCoordinator.shared.isPresented,
               ["q", ","].contains(event.charactersIgnoringModifiers?.lowercased() ?? "") { return true }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": onBack?(); return true
            case ",": onSettings?(); return true
            case "q": onQuit?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onBack?() } else { super.keyDown(with: event) }
    }
}

private final class GooContentGroup: NSView {
    var acceptsInteraction = false {
        didSet {
            if oldValue != acceptsInteraction { setAccessibilityHidden(!acceptsInteraction) }
        }
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityHidden(true)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsInteraction ? super.hitTest(point) : nil
    }
}

private final class GooChrome: NSView {
    var onBack: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        for index in 0..<3 {
            let button = NSButton(frame: NSRect(x: 14 + index * 21, y: 11, width: 13, height: 13))
            button.title = ""
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6.5
            button.layer?.backgroundColor = (index == 0 ? NSColor.systemRed : NSColor(white: 0.27, alpha: 1)).cgColor
            button.isEnabled = index == 0
            button.target = self
            button.action = #selector(goBack)
            button.toolTip = nil
            button.setAccessibilityLabel(index == 0 ? "Back to Quick Controls" : (index == 1 ? "Minimize unavailable" : "Zoom unavailable"))
            addSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func setBackAccessibilityLabel(_ label: String) {
        (subviews.first as? NSButton)?.setAccessibilityLabel(label)
    }
    @objc private func goBack() { onBack?() }
}
