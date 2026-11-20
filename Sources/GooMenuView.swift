import AppKit
import QuartzCore
import SwiftUI
import Combine

/// A compact presentation of an existing menu. The host owns dismissal, action
/// dispatch, window placement and the transition into Settings.
///
/// Everything inside the panel sits on one 4pt grid: 8pt content padding, 32pt
/// rows, 9pt separator blocks, a 20pt leading text margin and a 20pt trailing
/// affordance margin. Rows are hit targets edge to edge, with rectangular
/// highlights inset 8pt on each side with a 4pt radius. Labels and chevrons share optical
/// edges. Text and chevrons use the same pixel face and the same baseline.
@MainActor
final class GooMenuView: NSView {
    var onSizeChange: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var preferredSize = NSSize(width: GooMenuMetrics.width,
                                            height: GooMenuMetrics.minHeight)

    private var tourFooter: NSHostingView<HighlightTourCoach>?
    private var guideObservation: AnyCancellable?
    private var syncingTour = false
    private var lastTourStep: HighlightTourStep?
    private var lastTourKeepAwakeAvailable: Bool?
    private var tourHeight: CGFloat { GuideCoordinator.shared.isMenuTour && GuideCoordinator.shared.isPresented ? 250 : 0 }

    /// Uses the original menu items and original buttons; only navigation and
    /// emphasis are tutorial-owned. No command is invoked to stage this page.
    func syncHighlightedTour() {
        guard !syncingTour else { return }
        syncingTour = true
        defer { syncingTour = false }
        let guide = GuideCoordinator.shared
        let active = guide.isPresented && guide.isMenuTour
        let available: Bool? = active ? modelMenu.items.contains(where: {
            $0.identifier?.rawValue == "tour.keepAwake" && $0.submenu != nil
        }) : nil
        if let available { guide.updateMenuKeepAwakeAvailability(available) }
        let nextStep: HighlightTourStep? = active ? guide.currentTourStep : nil
        let stepChanged = nextStep != lastTourStep || available != lastTourKeepAwakeAvailable
        lastTourStep = nextStep
        lastTourKeepAwakeAvailable = available
        cancelNavigationAnimation()
        path.removeAll()
        if active, guide.currentTourStep == .menuDurations,
           let keep = modelMenu.items.first(where: { $0.identifier?.rawValue == "tour.keepAwake" && $0.submenu != nil }) {
            path = [PathComponent(title: keep.title, occurrence: 0)]
        }
        if active && tourFooter == nil {
            let footer = NSHostingView(rootView: HighlightTourCoach(compact: true))
            tourFooter = footer
            addSubview(footer)
        }
        tourFooter?.isHidden = !active
        selectedIndex = nil
        reload(menu: modelMenu)
        if stepChanged { scrollToTop() }
        layoutSubtreeIfNeeded()
        // Live one-second menu refreshes must not pull the user away from Quit
        // or another lower row they deliberately scrolled into view.
        if stepChanged, let row = rows.first(where: { !$0.isHidden && $0.tourHighlighted }) { revealSelection(row) }
    }

    private func tourTargets() -> Set<String> {
        let guide = GuideCoordinator.shared
        guard guide.isPresented && guide.isMenuTour else { return [] }
        switch guide.currentTourStep {
        case .menuArm: return ["tour.arm"]
        case .menuKeepAwake, .menuDurations:
            guard modelMenu.items.contains(where: { $0.identifier?.rawValue == "tour.keepAwake" }) else { return [] }
            return guide.currentTourStep == .menuDurations
                ? Set(KeepAwakeMenuPresentation.choices.map { "tour.duration.\($0.minutes)" }) : ["tour.keepAwake"]
        case .menuNavigation: return ["tour.components", "tour.settings", "tour.about", "tour.quit"]
        default: return []
        }
    }

    private var modelMenu: NSMenu
    private let perform: (NSMenuItem) -> Void
    private let backRow = GooMenuRowButton(frame: .zero)
    private let scrollView = NSScrollView()
    private let document = GooMenuDocumentView()
    private var rows: [GooMenuRowButton] = []
    private var separators: [NSView] = []
    private var entries: [NSMenuItem] = []
    private var path: [PathComponent] = []
    private var selectedIndex: Int?
    private weak var hoveredRow: GooMenuRowButton?
    private var lastPointer: NSPoint?
    private var listHeight: CGFloat = 0
    private var reservesStateColumn = false
    private var navigationGeneration = 0
    private var navigationAnimating = false
    private var pageSignature: [String] = []
    private static let navigationAnimationKey = "submenu-navigation"

    /// Enabled only when the host panel has a real material backdrop. The
    /// default keeps the exact opaque backing required by borderless-window
    /// rendering and the existing pixel tests.
    var usesMaterial = false {
        didSet { if oldValue != usesMaterial { applyMaterialBacking() } }
    }

    private struct PathComponent {
        let title: String
        let occurrence: Int
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(menu: NSMenu, perform: @escaping (NSMenuItem) -> Void) {
        self.modelMenu = menu
        self.perform = perform
        super.init(frame: NSRect(x: 0, y: 0, width: GooMenuMetrics.width,
                                 height: GooMenuMetrics.minHeight))
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.backgroundColor = GooPalette.window.cgColor
        // The host owns the rounded silhouette; content stays square.
        layer?.cornerRadius = 0
        layer?.masksToBounds = true

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Wakely quick controls")
        setAccessibilityHelp("Arrow keys move through rows. Return chooses. Escape closes.")

        backRow.target = self
        backRow.action = #selector(goBack)
        backRow.title = "‹  Back"
        backRow.displayTitle = "Back"
        backRow.symbolName = "chevron.left"
        backRow.kind = .navigation
        backRow.onPointerChange = { [weak self] in self?.refreshPointer() }
        backRow.onPointerDown = { [weak self] in self?.beginPointerPress() }
        backRow.applyAccessibility(label: "Back", value: nil,
                                   help: "Returns to the previous menu.", role: .button)
        addSubview(backRow)

        scrollView.drawsBackground = false
        // Scrolling still works with the wheel/trackpad; no bar is drawn.
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .light
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.documentView = document
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsDidChange),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.setAccessibilityLabel("Menu items")
        addSubview(scrollView)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(accessibilityOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appearanceChanged),
            name: Notification.Name("wakelyAppearanceDidChange"), object: nil)
        reload(menu: menu)
        guideObservation = GuideCoordinator.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.syncHighlightedTour() }
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Rebinds the original items without replacing live buttons. Menu rebuilds
    /// may replace every NSMenuItem, so navigation is resolved by title/occurrence.
    func reload(menu: NSMenu) {
        reload(menu: menu, preservingNavigationAnimation: false)
    }

    private func reload(menu: NSMenu, preservingNavigationAnimation: Bool) {
        // A live refresh may replace every item. Never replay old captured rows
        // or leave their hit targets active against a newer action model.
        self.modelMenu = menu
        var current = menu
        var validPath: [PathComponent] = []
        for component in path {
            let matches = current.items.filter { $0.title == component.title && $0.submenu != nil }
            guard matches.indices.contains(component.occurrence),
                  let submenu = matches[component.occurrence].submenu else { break }
            validPath.append(component)
            current = submenu
        }
        path = validPath
        let nextEntries = current.items.filter { !$0.isHidden }
        let signature = nextEntries.map {
            "\($0.title)|\($0.isSeparatorItem)|\($0.isEnabled)|\($0.state.rawValue)|\($0.submenu != nil)|\($0.action.map(NSStringFromSelector) ?? "")"
        }
        if !preservingNavigationAnimation && signature != pageSignature {
            cancelNavigationAnimation()
        }
        pageSignature = signature
        entries = nextEntries
        if let index = selectedIndex,
           !entries.indices.contains(index) || entries[index].isSeparatorItem {
            selectedIndex = nil
        }

        let actionable = entries.filter { !$0.isSeparatorItem }.count
        while rows.count < actionable {
            let row = GooMenuRowButton(frame: .zero)
            row.target = self
            row.action = #selector(activateRow(_:))
            row.usesMaterial = usesMaterial
            row.onPointerChange = { [weak self] in self?.refreshPointer() }
            row.onPointerDown = { [weak self] in self?.beginPointerPress() }
            document.addSubview(row)
            row.refreshAppearance()
            rows.append(row)
        }
        let dividerCount = entries.filter(\.isSeparatorItem).count
        while separators.count < dividerCount {
            let divider = NSView()
            divider.wantsLayer = true
            effectiveAppearance.performAsCurrentDrawingAppearance {
                divider.layer?.backgroundColor = (usesMaterial
                    ? GooPalette.stroke.withAlphaComponent(0.55)
                    : GooPalette.stroke).cgColor
            }
            document.addSubview(divider)
            separators.append(divider)
        }
        // Keep live tracking areas intact during the one-second refresh.
        // Hiding/re-showing every row can discard mouse-exit events.
        for (index, row) in rows.enumerated() where row.isHidden != (index >= actionable) {
            row.isHidden = index >= actionable
        }
        for (index, divider) in separators.enumerated() where divider.isHidden != (index >= dividerCount) {
            divider.isHidden = index >= dividerCount
        }

        // The state marker is a trailing column; reserve it for the whole page
        // so no label shifts when an item happens to be on or mixed.
        reservesStateColumn = entries.contains { !$0.isSeparatorItem && $0.state != .off }

        var rowIndex = 0
        for (index, item) in entries.enumerated() where !item.isSeparatorItem {
            let row = rows[rowIndex]
            rowIndex += 1
            row.isHidden = false
            row.item = item
            let targets = tourTargets()
            row.tourHighlighted = targets.contains(item.identifier?.rawValue ?? "")
            row.alphaValue = tourHeight > 0 && !targets.isEmpty && !row.tourHighlighted ? 0.42 : 1
            row.tag = index
            let interactive = item.isEnabled && (item.action != nil || item.submenu != nil)
            row.isEnabled = interactive
            row.kind = GooMenuRowKind(item: item, interactive: interactive)
            row.title = item.title
            row.displayTitle = item.title
            // Agent rows mark desktop apps on their image; CLIs keep the terminal glyph.
            row.symbolName = item.image?.accessibilityDescription == "App" ? "macwindow"
                : MenuIconPolicy.symbolName(title: item.title, action: item.action, hasSubmenu: item.submenu != nil)
            row.hasChevron = interactive && item.submenu != nil
            row.itemState = item.state
            row.reservesStateColumn = reservesStateColumn
            row.keyboardHighlighted = selectedIndex == index
            // Visual tooltips are disabled; accessibility help remains below.
            row.toolTip = nil
            let accessible = accessibilityNameAndValue(for: item, interactive: interactive)
            row.applyAccessibility(label: accessible.name,
                                   value: accessible.value,
                                   help: accessibilityHelp(for: item, interactive: interactive),
                                   role: interactive ? .button : .staticText)
            row.needsDisplay = true
        }

        if let selected = selectedIndex,
           !rows.contains(where: { !$0.isHidden && $0.isEnabled && $0.tag == selected }) {
            selectedIndex = nil
        }

        backRow.isHidden = path.isEmpty
        backRow.title = "‹  Back"
        backRow.displayTitle = "Back"
        backRow.symbolName = "chevron.left"

        listHeight = GooMenuMetrics.contentTop + GooMenuMetrics.contentBottom
            + entries.reduce(CGFloat(0)) {
                $0 + ($1.isSeparatorItem ? GooMenuMetrics.separatorBlock : GooMenuMetrics.rowHeight)
            }
        let header = path.isEmpty ? 0 : GooMenuMetrics.backHeader
        let nextSize = NSSize(width: GooMenuMetrics.width,
                              height: min(GooMenuMetrics.maxHeight,
                                          max(GooMenuMetrics.minHeight, header + listHeight + tourHeight)))
        let changed = nextSize != preferredSize
        preferredSize = nextSize
        needsLayout = true
        if changed { onSizeChange?() }
        if !syncingTour && (tourHeight > 0 || tourFooter?.isHidden == false) { syncHighlightedTour() }
    }

    private func applyMaterialBacking() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (usesMaterial
                ? NSColor.clear
                : GooPalette.window).cgColor
            for divider in separators {
                divider.layer?.backgroundColor = (usesMaterial
                    ? GooPalette.stroke.withAlphaComponent(0.55)
                    : GooPalette.stroke).cgColor
            }
        }
        backRow.usesMaterial = usesMaterial
        for row in rows { row.usesMaterial = usesMaterial }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let header = path.isEmpty ? 0 : GooMenuMetrics.backHeader
        tourFooter?.frame = NSRect(x: 0, y: max(header, bounds.height - tourHeight), width: bounds.width, height: tourHeight)
        backRow.frame = NSRect(x: 0, y: GooMenuMetrics.backTop,
                               width: bounds.width, height: GooMenuMetrics.rowHeight)
        scrollView.frame = NSRect(x: 0, y: header, width: bounds.width,
                                  height: max(0, bounds.height - header - tourHeight))
        let documentWidth = scrollView.contentSize.width
        document.frame = NSRect(x: 0, y: 0, width: documentWidth, height: listHeight)

        let indent = path.isEmpty ? 0 : GooMenuMetrics.submenuIndent
        var y = GooMenuMetrics.contentTop
        var rowIndex = 0
        var dividerIndex = 0
        for item in entries {
            if item.isSeparatorItem {
                let divider = separators[dividerIndex]
                dividerIndex += 1
                divider.isHidden = false
                divider.frame = NSRect(x: GooMenuMetrics.labelInset + indent,
                                       y: y + (GooMenuMetrics.separatorBlock - 1) / 2,
                                       width: max(0, documentWidth
                                           - 2 * (GooMenuMetrics.labelInset + indent)),
                                       height: 1)
                y += GooMenuMetrics.separatorBlock
            } else {
                let row = rows[rowIndex]
                rowIndex += 1
                if row.textIndent != indent { row.textIndent = indent }
                row.frame = NSRect(x: 0, y: y, width: documentWidth,
                                   height: GooMenuMetrics.rowHeight)
                y += GooMenuMetrics.rowHeight
            }
        }
        updatePointer(at: window?.mouseLocationOutsideOfEventStream)
    }

    @objc private func clipBoundsDidChange() {
        updatePointer(at: window?.mouseLocationOutsideOfEventStream)
    }

    /// A restrained direction-aware arrival: the live model changes immediately,
    /// while only the incoming live page moves 10 pt with a short fade.
    /// Never capture the whole menu: resized bitmaps can replay stale rows.
    private func navigate(from direction: CATransitionSubtype, change: () -> Void) {
        cancelNavigationAnimation()
        selectedIndex = nil
        updatePointer(at: nil)
        displayIfNeeded()
        let animate = window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let generation = navigationGeneration
        change()
        reload(menu: modelMenu, preservingNavigationAnimation: true)
        scrollToTop()
        layoutSubtreeIfNeeded()
        displayIfNeeded()
        guard animate else { return }

        navigationAnimating = true
        let offset: CGFloat = direction == .fromRight ? 10 : -10
        let spring = CASpringAnimation(keyPath: "transform.translation.x")
        spring.fromValue = offset
        spring.toValue = 0
        spring.mass = 1
        spring.stiffness = 260
        spring.damping = 28
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 1
        fade.duration = 0.16
        // Back is stable navigation chrome, not part of the travelling list.
        // It must hover and accept Back immediately, including during arrival.
        for view in [scrollView] {
            view.wantsLayer = true
            // Explicit endpoints survive removal of either CA animation.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.layer?.opacity = 1
            view.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
            view.layer?.add(spring, forKey: Self.navigationAnimationKey)
            view.layer?.add(fade, forKey: "submenu-fade")
        }
        let settle = max(AppMotion.submenuDuration + 0.10, spring.settlingDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.navigationGeneration == generation else { return }
                self.navigationAnimating = false
                self.updatePointer(at: self.window?.mouseLocationOutsideOfEventStream)
            }
        }
    }

    /// No outgoing bitmap or duplicate view is retained during navigation.
    var isNavigationInFlight: Bool { navigationAnimating }

    var debugNavigationState: (isAnimating: Bool, generation: Int, snapshotCount: Int) {
        (navigationAnimating, navigationGeneration, 0)
    }

    func cancelNavigationAnimation() {
        navigationGeneration &+= 1
        navigationAnimating = false
        for view in [backRow, scrollView] {
            view.layer?.removeAnimation(forKey: Self.navigationAnimationKey)
            view.layer?.removeAnimation(forKey: "submenu-fade")
        }
        layer?.removeAnimation(forKey: Self.navigationAnimationKey)
    }

    @objc private func appearanceChanged() {
        // Refresh layer colors under the new appearance, not cached CGColors.
        cancelNavigationAnimation()
        applyMaterialBacking()
        backRow.refreshAppearance()
        for row in rows { row.refreshAppearance() }
        updatePointer(at: window?.mouseLocationOutsideOfEventStream)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged()
    }

    @objc private func accessibilityOptionsChanged() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            cancelNavigationAnimation()
            updatePointer(at: window?.mouseLocationOutsideOfEventStream)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The rendered rows are moving; clicking their final, invisible targets
        // would invoke the wrong command. Keyboard back can still interrupt.
        guard let hit = super.hitTest(point) else { return nil }
        if hit === backRow || hit.isDescendant(of: backRow) { return hit }
        return navigationAnimating ? self : hit
    }

    @objc private func goBack() {
        if GuideCoordinator.shared.isPresented { GuideCoordinator.shared.previous(); return }
        guard !path.isEmpty else { return }
        navigate(from: .fromLeft) { path.removeLast() }
    }

    @objc private func activateRow(_ sender: GooMenuRowButton) {
        // Even AXPress and keyboard selection are explanation-only in a tour.
        guard !GuideCoordinator.shared.isPresented,
              let item = sender.item, sender.isEnabled else { return }
        if item.submenu != nil {
            let preceding = entries.prefix(sender.tag).filter { $0.title == item.title && $0.submenu != nil }.count
            navigate(from: .fromRight) {
                path.append(PathComponent(title: item.title, occurrence: preceding))
            }
        } else {
            perform(item)
        }
    }

    /// One owner resolves pointer and keyboard highlights. Repainting just the
    /// newly entered button leaves old backing layers lit after a lost exit.
    func updatePointer(at point: NSPoint?, pointerEvent: Bool = false) {
        let moved = point != lastPointer
        lastPointer = point
        let candidates = [backRow] + rows
        let pointerCandidates = navigationAnimating ? [backRow] : candidates
        let next = point.flatMap { point in
            pointerCandidates.first {
                !$0.isHidden && $0.isEnabled
                    // AppKit visibleRect can extend beyond a non-clipping
                    // button's bounds. Without this intersection every row
                    // can claim the entire document as its hover region.
                    && $0.bounds.intersection($0.visibleRect)
                        .contains($0.convert(point, from: nil))
            }
        }
        if pointerEvent && moved {
            selectedIndex = nil
        }
        hoveredRow = next
        // The shared scan is authoritative. Row-local tracking areas can all
        // receive mouseEntered when the list scrolls or a submenu replaces the
        // rows, which previously lit two rows at once. A background refresh
        // must not steal an active keyboard selection.
        let keyboardOwnsHighlight = selectedIndex != nil && !pointerEvent
        for row in candidates {
            if keyboardOwnsHighlight {
                row.pointerHighlighted = false
                row.keyboardHighlighted = !row.isHidden && row !== backRow
                    && selectedIndex == row.tag
            } else {
                row.pointerHighlighted = (row === next)
                row.keyboardHighlighted = false
            }
        }
    }

    private func beginPointerPress() {
        selectedIndex = nil
        refreshPointer()
    }

    private func refreshPointer() {
        updatePointer(at: window?.mouseLocationOutsideOfEventStream, pointerEvent: true)
    }

    /// Read-only regression seam: the rendered active rows, not event hints.
    var debugHighlightedTitles: [String] {
        ([backRow] + rows).filter {
            !$0.isHidden && ($0.pointerHighlighted || $0.keyboardHighlighted)
        }.map(\.title)
    }

    var debugTourHighlightedTitles: [String] {
        rows.filter { !$0.isHidden && $0.tourHighlighted }.map { $0.title }
    }

    var debugSelectedTitles: [String] {
        rows.filter { !$0.isHidden && $0.itemState == .on }.map(\.title)
    }

    var debugHighlightInvalidations: Int { ([backRow] + rows).reduce(0) { $0 + $1.highlightInvalidations } }

    var debugRowIcons: [String: String] {
        Dictionary(rows.filter { !$0.isHidden }.compactMap { row in
            row.symbolName.map { (row.title, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }

    /// Opt-in keyboard focus; construction/reloading never changes first responder.
    /// Selects the first reachable row when nothing valid is selected, and keeps
    /// an existing selection instead of advancing it.
    func activateFirst() {
        window?.makeFirstResponder(self)
        if let selected = selectedIndex, selectableIndices.contains(selected) { return }
        selectedIndex = selectableIndices.first
        syncHighlight(reveal: true)
    }

    override func becomeFirstResponder() -> Bool {
        // Opening with the mouse must not also light the first keyboard row.
        super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Keyboard intent targets the current model, so finish its visual swap
        // before moving focus or activating an item.
        cancelNavigationAnimation()
        switch event.keyCode {
        case 53: onDismiss?()
        case 125: moveSelection(by: 1)
        case 126: moveSelection(by: -1)
        case 123 where !path.isEmpty: goBack()
        case 36, 76, 124: activateSelection()
        default: super.keyDown(with: event)
        }
    }

    private var selectableIndices: [Int] {
        rows.filter { !$0.isHidden && $0.isEnabled }.map(\.tag)
    }

    private func moveSelection(by delta: Int) {
        let indices = selectableIndices
        guard !indices.isEmpty else {
            selectedIndex = nil
            syncHighlight(reveal: false)
            return
        }
        let next: Int
        if let position = selectedIndex.flatMap({ indices.firstIndex(of: $0) }) {
            next = indices[(position + delta + indices.count) % indices.count]
        } else {
            next = delta > 0 ? indices[0] : indices[indices.count - 1]
        }
        selectedIndex = next
        syncHighlight(reveal: true)
    }

    private func syncHighlight(reveal: Bool) {
        for row in [backRow] + rows { row.pointerHighlighted = false }
        for row in rows where !row.isHidden {
            let active = row.tag == selectedIndex
            if row.keyboardHighlighted != active { row.keyboardHighlighted = active }
            if active && reveal { revealSelection(row) }
        }
    }

    private func activateSelection() {
        guard let selectedIndex,
              let row = rows.first(where: {
                  !$0.isHidden && $0.tag == selectedIndex && $0.isEnabled
              }) else { return }
        activateRow(row)
    }

    /// Keeps the focused row one 8pt content pad clear of the clip edges, so
    /// keyboard travel never parks a label under the deadline.
    private func revealSelection(_ row: GooMenuRowButton) {
        let clip = scrollView.contentView.bounds
        guard clip.height > 0, document.frame.height > clip.height else { return }
        var origin = clip.origin
        let pad = GooMenuMetrics.contentTop
        if row.frame.minY - pad < clip.minY {
            origin.y = row.frame.minY - pad
        } else if row.frame.maxY + pad > clip.maxY {
            origin.y = row.frame.maxY + pad - clip.height
        }
        let limit = max(0, document.frame.height - clip.height)
        origin.y = min(max(0, origin.y), limit)
        guard origin != clip.origin else { return }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Accessibility

    /// Name is what the row is; value is the state it carries. Agent summaries
    /// expose their counts as the value, and agent rows expose their state after
    /// the em dash rather than reading the whole decorated title.
    private func accessibilityNameAndValue(for item: NSMenuItem,
                                           interactive: Bool) -> (name: String, value: String?) {
        if !interactive {
            if let counts = agentCount(in: item.title) {
                return ("Agent status", counts)
            }
            return (item.title, nil)
        }
        if let parts = agentParts(item.title) {
            return (parts.name, parts.state)
        }
        if item.title == "Arm Wakely" { return (item.title, "Off") }
        if item.title.hasPrefix("Unarm") { return (item.title, "Armed") }
        if item.state == .on { return (item.title, "On") }
        if item.state == .mixed { return (item.title, "Mixed") }
        return (item.title, nil)
    }

    private func accessibilityHelp(for item: NSMenuItem, interactive: Bool) -> String? {
        guard interactive else { return nil }
        if item.submenu != nil { return "Opens a submenu." }
        return item.toolTip
    }

    private func agentCount(in title: String) -> String? {
        let lower = title.lowercased()
        let isSummary = lower.contains(" working")
            || lower.contains("waiting on you")
            || lower == "no agents running"
        return isSummary ? title : nil
    }

    private func agentParts(_ title: String) -> (name: String, state: String)? {
        guard let dash = title.range(of: " — ") else { return nil }
        let name = String(title[..<dash.lowerBound])
        let state = String(title[dash.upperBound...])
        guard !name.isEmpty, !state.isEmpty else { return nil }
        return (name, state)
    }
}

// MARK: - Metrics

/// One scale for the whole panel. Everything is a multiple of 4pt, and the
/// 32pt row preserves the compact pixel menu and a comfortable hit target.
private enum GooMenuMetrics {
    static let width: CGFloat = 320
    static let minHeight: CGFloat = 140
    static let maxHeight: CGFloat = 620
    static let rowHeight: CGFloat = 32
    static let separatorBlock: CGFloat = 9      // 4 above, 1pt rule, 4 below
    static let contentTop: CGFloat = 8
    static let contentBottom: CGFloat = 8
    static let highlightInset: CGFloat = 8
    // Concentric corners: outer 12pt radius minus the 8pt content inset.
    static let highlightRadius = max(0, GooShape.bodyCornerRadius - highlightInset)
    static let labelInset: CGFloat = 20
    static let trailingInset: CGFloat = 20
    static let labelChevronGap: CGFloat = 8
    static let stateSide: CGFloat = 12
    static let stateGap: CGFloat = 8
    static let submenuIndent: CGFloat = 8
    static let backTop: CGFloat = 8
    static let backHeader: CGFloat = 48         // 8 + 32 row + 8 gap
    static let focusBarWidth: CGFloat = 2
    static let focusBarHeight: CGFloat = 16
}

// MARK: - Palette

/// The existing `Theme` tokens, bridged once for AppKit drawing. The palette has
/// no dedicated danger token; `Theme.accent(.security)` is the app's orange
/// warning hue (the same family as `Color.orange` in Settings), so the one
/// irreversible row reuses it instead of inventing a colour.
private enum GooPalette {
    static var window: NSColor { NSColor(Theme.window) }
    static var gold: NSColor { NSColor(Theme.gold) }
    static var warning: NSColor { NSColor(Theme.accent(.security)) }
    static var ink: NSColor { NSColor(Theme.ink) }
    static var secondary: NSColor { NSColor(Theme.textSecondary) }
    static var tertiary: NSColor { NSColor(Theme.textTertiary) }
    static var stroke: NSColor { NSColor(Theme.stroke) }
    static var strokeHover: NSColor { NSColor(Theme.strokeHover) }
    static var cardHover: NSColor { NSColor(Theme.cardHover) }
    static var controlHover: NSColor { NSColor(Theme.controlHover) }
    static var cardHoverBorder: NSColor { NSColor(Theme.cardHoverBorder) }
    static var hoverOutline: NSColor { NSColor(Theme.hoverOutline) }
    static var selectedSurface: NSColor { NSColor(Theme.selectedSurface) }
}

// MARK: - Row kind

/// Hierarchy is carried by face weight and token colour, never by interaction:
/// the primary row stays gold, the destructive row uses the warning hue, and
/// ordinary actions recede to secondary text.
private enum GooMenuRowKind {
    case primary
    case destructive
    case standard
    case status
    case navigation

    init(item: NSMenuItem, interactive: Bool) {
        guard interactive else {
            self = .status
            return
        }
        let title = item.title
        if title == "Arm Wakely" || title.hasPrefix("Unarm") {
            self = .primary
        } else if title.hasPrefix("Quit") {
            self = .destructive
        } else {
            self = .standard
        }
    }

    var font: NSFont {
        switch self {
        case .primary, .destructive: return ClamType.bodyFont(12, .semibold)
        case .standard, .status, .navigation: return ClamType.bodyFont(12)
        }
    }

    var pressedFill: NSColor {
        switch self {
        case .primary: return GooPalette.gold
        case .destructive: return GooPalette.warning
        case .standard, .status, .navigation: return GooPalette.ink
        }
    }
}

// MARK: - Document

@MainActor
private final class GooMenuDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row

/// One full-width hit target with an inset, concentric rounded highlight.
/// The chevron and state marker are drawn,
/// never separate controls, so the entire band remains clickable.
@MainActor
private final class GooMenuRowButton: NSButton {
    var item: NSMenuItem?
    var tourHighlighted = false { didSet { if oldValue != tourHighlighted { needsDisplay = true } } }
    private(set) var highlightInvalidations = 0
    var symbolName: String? { didSet { if oldValue != symbolName { needsDisplay = true } } }
    var kind: GooMenuRowKind = .standard { didSet { if oldValue != kind { needsDisplay = true } } }
    var displayTitle = "" { didSet { if oldValue != displayTitle { needsDisplay = true } } }
    var hasChevron = false { didSet { if oldValue != hasChevron { needsDisplay = true } } }
    var itemState: NSControl.StateValue = .off { didSet { if oldValue != itemState { needsDisplay = true } } }
    var reservesStateColumn = false { didSet { if oldValue != reservesStateColumn { needsDisplay = true } } }
    var textIndent: CGFloat = 0 { didSet { if oldValue != textIndent { needsDisplay = true } } }
    var keyboardHighlighted = false {
        didSet {
            if oldValue != keyboardHighlighted { highlightInvalidations &+= 1; needsDisplay = true }
        }
    }
    var usesMaterial = false {
        didSet { if oldValue != usesMaterial { refreshAppearance() } }
    }
    var axLabel = ""
    var axValue: String?
    var axHelp: String?

    var onPointerChange: (() -> Void)?
    var onPointerDown: (() -> Void)?
    var pointerHighlighted = false {
        didSet { if oldValue != pointerHighlighted { highlightInvalidations &+= 1; needsDisplay = true } }
    }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var hoverTracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        alignment = .left
        focusRingType = .none
        // Isolate row invalidation from the silhouette's shared backing store.
        wantsLayer = true
        layer?.backgroundColor = GooPalette.window.cgColor
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) { nil }

    func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (usesMaterial
                ? NSColor.clear
                : GooPalette.window).cgColor
        }
        needsDisplay = true
    }

    /// The scroll area exposes each button's `NSButtonCell`, and that cell does
    /// not read the NSButton overrides below. Mirror the semantics onto both so
    /// assistive technology gets the same name, value and role either way.
    func applyAccessibility(label: String, value: String?, help: String?,
                            role: NSAccessibility.Role) {
        axLabel = label
        axValue = value
        axHelp = help
        guard let cell else { return }
        cell.setAccessibilityLabel(label)
        cell.setAccessibilityValue(value)
        cell.setAccessibilityHelp(help)
        cell.setAccessibilityRole(role)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    // The row owns its own highlight. The shared scan could resolve more than
    // one row when the document scrolled, which lit the whole list.
    override func mouseEntered(with event: NSEvent) {
        onPointerChange?()
    }

    override func mouseExited(with event: NSEvent) {
        onPointerChange?()
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerChange?()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onPointerDown?()
        // Draw the pressed fill before the cell's tracking loop takes over.
        isPressed = true
        display()
        super.mouseDown(with: event)
        isPressed = false
        needsDisplay = true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        isEnabled ? .button : .staticText
    }

    override func accessibilityLabel() -> String? {
        axLabel.isEmpty ? title : axLabel
    }

    override func accessibilityValue() -> Any? { axValue }
    override func accessibilityHelp() -> String? { axHelp }

    override func draw(_ dirtyRect: NSRect) {
        // Precedence: pressed > keyboard focus > hover > rest. A disabled row
        // draws no chrome at all, so nothing about it suggests a click.
        let showsPress = isEnabled && isPressed
        let showsFocus = tourHighlighted || (isEnabled && keyboardHighlighted)
        let showsHover = isEnabled && pointerHighlighted

        // AppKit may redraw only this row when hover changes. Without a
        // material backdrop, paint the base on every draw: a translucent
        // highlight alone clears a hole through the borderless backing store.
        // With glass, the parent material is the base and the row stays clear.
        if !usesMaterial {
            GooPalette.window.setFill()
            NSBezierPath(rect: bounds).fill()
        }

        var fill: NSColor?
        var text: NSColor
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch kind {
        case .primary: text = GooPalette.gold
        case .status: text = highContrast ? GooPalette.secondary : GooPalette.tertiary
        case .destructive, .standard, .navigation: text = GooPalette.ink
        }

        if showsPress {
            fill = kind.pressedFill
            text = GooPalette.window
        } else if showsFocus || showsHover {
            // Hover uses a neutral, clearly lifted surface. Focus adds its own
            // perimeter and leading bar below; it never borrows selection gold.
            fill = usesMaterial
                ? GooPalette.controlHover.withAlphaComponent(0.86)
                : GooPalette.controlHover
        }
        // Rest is chrome-free for every row: the primary row carries its weight
        // in gold type, so an outline here would compete with keyboard focus.

        let highlight = NSRect(x: bounds.minX + GooMenuMetrics.highlightInset,
                               y: bounds.minY,
                               width: max(0, bounds.width - GooMenuMetrics.highlightInset * 2),
                               height: bounds.height)
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: highlight,
                         xRadius: GooMenuMetrics.highlightRadius,
                         yRadius: GooMenuMetrics.highlightRadius).fill()
        }
        if showsFocus || showsHover {
            let border = showsFocus ? GooPalette.gold : GooPalette.hoverOutline
            border.setStroke()
            let path = NSBezierPath(roundedRect: highlight.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: GooMenuMetrics.highlightRadius,
                                    yRadius: GooMenuMetrics.highlightRadius)
            path.lineWidth = showsFocus ? 1.5 : 1
            path.stroke()
        }
        if showsFocus {
            GooPalette.gold.setFill()
            NSBezierPath(rect: NSRect(x: highlight.minX + 1,
                                      y: (bounds.height - GooMenuMetrics.focusBarHeight) / 2,
                                      width: GooMenuMetrics.focusBarWidth,
                                      height: GooMenuMetrics.focusBarHeight)).fill()
        }

        let font = kind.font
        let chevron = "›" as NSString
        let chevronWidth = hasChevron
            ? ceil(chevron.size(withAttributes: [.font: font]).width) : 0
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let top = floor((bounds.height - lineHeight) / 2)

        var rightEdge = bounds.width - GooMenuMetrics.trailingInset
        if hasChevron {
            rightEdge -= chevronWidth + GooMenuMetrics.labelChevronGap
        }
        var stateX: CGFloat = 0
        if reservesStateColumn {
            stateX = rightEdge - GooMenuMetrics.stateSide
            rightEdge = stateX - GooMenuMetrics.stateGap
        }
        let iconX = GooMenuMetrics.labelInset + textIndent
        let labelX = iconX + 24
        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) {
            // Fixed optical box: symbols do not move or scale on hover.
            let size = image.size
            let rect = NSRect(x: iconX + floor((16 - size.width) / 2),
                              y: floor((bounds.height - size.height) / 2),
                              width: size.width, height: size.height)
            let tinted = NSImage(size: size, flipped: false) { area in
                image.draw(in: area)
                text.setFill()
                area.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: rect)
        }
        let labelWidth = max(0, rightEdge - labelX)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: text,
            .paragraphStyle: paragraph
        ]
        NSAttributedString(string: displayTitle, attributes: attributes)
            .draw(with: NSRect(x: labelX, y: top, width: labelWidth, height: lineHeight),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        if reservesStateColumn, itemState != .off {
            let color = showsPress ? GooPalette.window : GooPalette.gold
            let side = GooMenuMetrics.stateSide
            let y = floor((bounds.height - side) / 2)
            if itemState == .on {
                color.setStroke()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: stateX + 1, y: y + 6))
                check.line(to: NSPoint(x: stateX + 5, y: y + 10))
                check.line(to: NSPoint(x: stateX + 11, y: y + 2))
                check.lineWidth = 1.5
                check.stroke()
            } else {
                color.setStroke()
                let ring = NSBezierPath(rect: NSRect(x: stateX + 0.5, y: y + 0.5,
                                                    width: side - 1, height: side - 1))
                ring.lineWidth = 1
                ring.stroke()
            }
        }

        if hasChevron {
            NSAttributedString(string: "›", attributes: [
                .font: font, .foregroundColor: text
            ]).draw(at: NSPoint(x: bounds.width - GooMenuMetrics.trailingInset - chevronWidth,
                                y: top))
        }
    }

    /// Four 1pt fills instead of a stroked rect: square corners, no half-pixel
    /// antialiasing, and the same edge on every row.
    private func drawBorder(_ color: NSColor) {
        color.setFill()
        let width: CGFloat = 1
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: width)).fill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - width,
                                  width: bounds.width, height: width)).fill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: bounds.height)).fill()
        NSBezierPath(rect: NSRect(x: bounds.width - width, y: 0,
                                  width: width, height: bounds.height)).fill()
    }
}
