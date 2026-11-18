import AppKit

@main struct GooMenuTests {
    @MainActor static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons($0) }
    }
    @MainActor static func button(_ view: NSView, containing title: String) -> NSButton {
        guard let button = buttons(view).first(where: { !$0.isHidden && ($0.title.contains(title) || $0.attributedTitle.string.contains(title)) }) else {
            fatalError("Missing button: \(title)")
        }
        return button
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        precondition(MenuIconPolicy.symbolName(title: "Localized settings", action: NSSelectorFromString("openSettings"), hasSubmenu: false) == "gearshape")
        precondition(MenuIconPolicy.symbolName(title: "Keep Awake With Lid Open", action: nil, hasSubmenu: true) == "sun.max")
        precondition(MenuIconPolicy.symbolName(title: "Indefinitely", action: NSSelectorFromString("startKeepAwake:"), hasSubmenu: false) == "infinity")
        precondition(MenuIconPolicy.symbolName(title: "Status", action: nil, hasSubmenu: false) == nil)
        // Arm/unarm are distinct from each other and from Quit's power symbol.
        for (title, selector, symbol) in [
            ("Arm Wakely", "armFromMenu", "shield.lefthalf.filled"),
            ("Unarm", "disarmFromMenu", "shield.slash"),
            ("Unarm Wakely", "disarmFromMenu", "shield.slash"),
            ("Quit Wakely", "quit", "power"),
        ] {
            let action = NSSelectorFromString(selector)
            precondition(MenuIconPolicy.symbolName(title: title, action: action, hasSubmenu: false) == symbol)
            precondition(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                         "Menu symbol must be supported locally: \(symbol)")
            let menu = NSMenu()
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menu.addItem(item)
            var performed: NSMenuItem?
            let iconView = GooMenuView(menu: menu) { performed = $0 }
            precondition(iconView.debugRowIcons[title] == symbol)
            let row = button(iconView, containing: title)
            precondition(row.accessibilityLabel() == title, "Decorative icons must preserve AX labels")
            let expectedValue = title == "Arm Wakely" ? "Off" : (title.hasPrefix("Unarm") ? "Armed" : nil)
            precondition(row.accessibilityValue() as? String == expectedValue,
                         "Decorative icons must preserve AX state values")
            row.performClick(nil)
            precondition(performed === item && item.action == action,
                         "Decorative icons must preserve the original menu action")
        }
        let stateRoot = NSMenu()
        let stateKeep = NSMenuItem(title: "Keep Awake With Lid Open", action: nil, keyEquivalent: "")
        let stateSubmenu = NSMenu()
        let checked = NSMenuItem(title: "2 hours", action: NSSelectorFromString("testHour:"), keyEquivalent: "")
        checked.state = .on
        let unchecked = NSMenuItem(title: "1 hour", action: NSSelectorFromString("testHour:"), keyEquivalent: "")
        stateSubmenu.addItem(checked)
        stateSubmenu.addItem(unchecked)
        stateKeep.submenu = stateSubmenu
        stateRoot.addItem(stateKeep)
        let stateView = GooMenuView(menu: stateRoot) { _ in }
        stateView.frame.size = stateView.preferredSize
        stateView.layoutSubtreeIfNeeded()
        button(stateView, containing: "Keep Awake").performClick(nil)
        stateView.layoutSubtreeIfNeeded()
        precondition(stateView.debugSelectedTitles == ["2 hours"],
                     "Persistent Keep Awake choice must render as a checkmark, not hover")
        let root = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: NSSelectorFromString("testSettings:"), keyEquivalent: ",")
        let keep = NSMenuItem(title: "Keep Awake With Lid Open", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let hour = NSMenuItem(title: "1 hour", action: NSSelectorFromString("testHour:"), keyEquivalent: "")
        hour.representedObject = NSNumber(value: 60)
        submenu.addItem(hour)
        keep.submenu = submenu
        root.addItem(settings)
        root.addItem(keep)
        var performed: NSMenuItem?
        var sizeChanges = 0
        var dismissed = false
        let view = GooMenuView(menu: root) { performed = $0 }
        view.onSizeChange = { sizeChanges += 1 }
        view.onDismiss = { dismissed = true }
        view.frame.size = view.preferredSize
        view.layoutSubtreeIfNeeded()
        precondition(view.preferredSize.width == 320, "Restored compact menu width")
        button(view, containing: "Settings").performClick(nil)
        precondition(performed === settings, "Action uses original item")
        button(view, containing: "Keep Awake").performClick(nil)
        view.layoutSubtreeIfNeeded()
        precondition(button(view, containing: "Back").frame.height == 32,
                     "Back retains compact row height")
        precondition(button(view, containing: "1 hour").frame.height == 32,
                     "Action rows retain compact row height")
        precondition(view.subviews.compactMap { $0 as? NSScrollView }.first?.frame.minY == 48,
                     "Submenu list starts below the compact 48pt back header")
        button(view, containing: "1 hour").performClick(nil)
        precondition(performed === hour, "Submenu uses original item")
        precondition((performed?.representedObject as? NSNumber)?.intValue == 60)
        // Rebuilding the model must not drop the user's inline submenu path.
        let replacement = NSMenu()
        let replacementKeep = NSMenuItem(title: "Keep Awake With Lid Open", action: nil, keyEquivalent: "")
        let replacementSubmenu = NSMenu()
        replacementSubmenu.addItem(NSMenuItem(title: "2 hours", action: NSSelectorFromString("testHour:"), keyEquivalent: ""))
        replacementKeep.submenu = replacementSubmenu
        replacement.addItem(replacementKeep)
        view.reload(menu: replacement)
        view.layoutSubtreeIfNeeded()
        _ = button(view, containing: "2 hours")
        button(view, containing: "Back").performClick(nil)
        view.layoutSubtreeIfNeeded()
        _ = button(view, containing: "Keep Awake")
        precondition(!buttons(view).contains(where: { $0.title == "×" }), "No compact close/header control")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                      isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        precondition(dismissed)
        // Header-free short menus now share the 140pt minimum. Force a real
        // height change rather than assuming submenu navigation changes it.
        for index in 0..<8 {
            replacement.addItem(NSMenuItem(title: "Control \(index)", action: NSSelectorFromString("testHour:"), keyEquivalent: ""))
        }
        view.reload(menu: replacement)
        precondition(view.preferredSize.height > 140)
        precondition(sizeChanges > 0)
        // Hover redraws must paint an opaque base, not punch a translucent
        // row-shaped hole through the borderless panel. Check both gutters too.
        view.layoutSubtreeIfNeeded()
        let row = button(view, containing: "Keep Awake")
        let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
                                          modifierFlags: [], timestamp: 0,
                                          windowNumber: 0, context: nil,
                                          eventNumber: 0, trackingNumber: 0,
                                          userData: nil)!
        let mouse = NSEvent.mouseLocation
        let window = NSWindow(contentRect: NSRect(x: mouse.x + 100, y: mouse.y + 100,
                                                  width: 320, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        func center(_ button: NSButton) -> NSPoint {
            button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        }
        view.updatePointer(at: center(row), pointerEvent: true)
        precondition(view.debugHighlightedTitles == [row.title])
        // Shell animation synchronizes pointer ownership at display cadence.
        // An unchanged sample must not invalidate every row at 60/120 Hz.
        let invalidations = view.debugHighlightInvalidations
        for _ in 0..<120 { view.updatePointer(at: center(row)) }
        precondition(view.debugHighlightInvalidations == invalidations,
                     "Stationary pointer samples must not invalidate stable menu rows")
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                      pixelsWide: Int(row.bounds.width),
                                      pixelsHigh: Int(row.bounds.height),
                                      bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                      bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            row.draw(row.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        let left = bitmap.colorAt(x: 3, y: 3)!
        let middle = bitmap.colorAt(x: 12, y: 3)!
        let right = bitmap.colorAt(x: Int(row.bounds.width) - 4, y: 3)!
        precondition(left.alphaComponent > 0.99 && middle.alphaComponent > 0.99
                     && right.alphaComponent > 0.99, "Hover row must stay opaque")
        precondition(middle.redComponent > left.redComponent + 0.02,
                     "Highlight must start inside the left gutter")
        precondition(abs(left.redComponent - right.redComponent) < 0.01,
                     "Both side gutters must retain the panel background")
        let corner = bitmap.colorAt(x: 8, y: 0)!
        let topEdge = bitmap.colorAt(x: 16, y: 0)!
        precondition(abs(corner.redComponent - left.redComponent) < 0.015,
                     "Rounded highlight corner must reveal the panel background")
        precondition(topEdge.redComponent > corner.redComponent + 0.02,
                     "Rounded highlight must retain a straight top edge")
        precondition(GooShape.bodyCornerRadius == 12, "Outer radius contract")
        // Even a stale enter event must not highlight a row after the pointer
        // has left. Attach to a window placed away from the real pointer;
        // this does not show a window or move the user's mouse.
        let other = button(view, containing: "Control 0")
        for _ in 0..<20 {
            view.updatePointer(at: center(row), pointerEvent: true)
            precondition(view.debugHighlightedTitles == [row.title])
            view.updatePointer(at: center(other), pointerEvent: true)
            precondition(view.debugHighlightedTitles == [other.title],
                         "Entering B must clear A even with no exit event: \(view.debugHighlightedTitles), B frame=\(other.frame), visible=\(other.visibleRect), center=\(center(other))")
            view.updatePointer(at: nil, pointerEvent: true)
            precondition(view.debugHighlightedTitles.isEmpty)
        }
        view.activateFirst()
        precondition(view.debugHighlightedTitles.count == 1)
        let focusedRow = buttons(view).first {
            !$0.isHidden && view.debugHighlightedTitles.contains($0.title)
        }!
        let focusBitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(focusedRow.bounds.width),
                                           pixelsHigh: Int(focusedRow.bounds.height),
                                           bitsPerSample: 8, samplesPerPixel: 4,
                                           hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                           bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: focusBitmap)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            focusedRow.draw(focusedRow.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        let focusBar = focusBitmap.colorAt(x: 10, y: Int(focusedRow.bounds.height / 2))!
        precondition(focusBar.redComponent > 0.65 && focusBar.greenComponent > 0.45,
                     "Keyboard focus must draw its own gold leading bar")
        view.updatePointer(at: center(other), pointerEvent: true)
        precondition(view.debugHighlightedTitles == [other.title],
                     "Pointer must replace keyboard highlight, not add another")
        view.activateFirst()
        let keyboardSelection = view.debugHighlightedTitles
        view.updatePointer(at: center(other))
        precondition(view.debugHighlightedTitles == keyboardSelection,
                     "Background refresh must not steal keyboard navigation")
        view.updatePointer(at: nil, pointerEvent: true)
        for _ in 0..<5 {
            view.reload(menu: replacement)
            view.layoutSubtreeIfNeeded()
        }
        row.mouseEntered(with: hover) // Deliberately stale tracking notification.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            row.draw(row.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
        let cleared = bitmap.colorAt(x: 12, y: 3)!
        precondition(abs(cleared.redComponent - left.redComponent) < 0.01,
                     "Pointer outside row must clear stale hover after refreshes")
        precondition(row.wantsLayer, "Rows must have independent backing layers")
        // Exercise the actual visible-window CA path, not just hidden-view navigation.
        // This is a disposable test window, never the installed application.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func pump(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func drawRow(_ button: NSButton) -> NSBitmapImageRep {
            let image = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(button.bounds.width), pixelsHigh: Int(button.bounds.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: image)
            NSColor.clear.setFill()
            button.bounds.fill(using: .copy)
            NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                button.draw(button.bounds)
            }
            NSGraphicsContext.restoreGraphicsState()
            return image
        }
        func assertBackHover(material: Bool) {
            let back = button(view, containing: "Back")
            let originalFrame = back.frame
            precondition((back.layer?.animationKeys() ?? []).isEmpty,
                         "Back must remain stationary while submenu rows arrive")
            let point = center(back)
            // hitTest takes SUPERview coordinates; this flipped contentView's
            // local Y is not the window/theme-frame Y.
            let hitPoint = view.superview?.convert(point, from: nil) ?? point
            precondition(view.hitTest(hitPoint) === back,
                         "Back must be an immediate hit target, even during arrival")
            view.updatePointer(at: nil, pointerEvent: true)
            let rest = drawRow(back)
            view.updatePointer(at: point, pointerEvent: true)
            precondition(view.debugHighlightedTitles == [back.title],
                         "Back owns the single hover immediately, without waiting for cleanup")
            precondition(back.frame == originalFrame, "Hover must never move Back")
            let lit = drawRow(back)
            let gutter = lit.colorAt(x: 3, y: 3)!
            let farGutter = lit.colorAt(x: Int(back.bounds.width) - 4, y: 3)!
            let inset = lit.colorAt(x: 12, y: 3)!
            let corner = lit.colorAt(x: 8, y: 0)!
            let edge = lit.colorAt(x: 16, y: 0)!
            if material {
                precondition(rest.colorAt(x: 12, y: 3)!.alphaComponent < 0.01)
                precondition(gutter.alphaComponent < 0.01 && farGutter.alphaComponent < 0.01,
                             "Material Back hover leaves both 8pt gutters transparent")
                precondition(inset.alphaComponent > 0.05,
                             "Material Back must paint its inset hover immediately")
                precondition(corner.alphaComponent < 0.01 && edge.alphaComponent > 0.05,
                             "Material Back uses the same rounded inset geometry as action rows")
            } else {
                precondition(gutter.alphaComponent > 0.99 && inset.alphaComponent > 0.99
                             && farGutter.alphaComponent > 0.99,
                             "Opaque Back hover must not punch blank holes")
                precondition(abs(gutter.redComponent - farGutter.redComponent) < 0.01)
                precondition(inset.redComponent > rest.colorAt(x: 12, y: 3)!.redComponent + 0.02,
                             "Opaque Back gets the full action-row inset hover")
                precondition(abs(corner.redComponent - gutter.redComponent) < 0.015
                             && edge.redComponent > corner.redComponent + 0.02,
                             "Opaque Back uses the same corner radius and gutters as action rows")
            }
            view.updatePointer(at: nil, pointerEvent: true)
            precondition(view.debugHighlightedTitles.isEmpty, "Back hover exits without a stale highlight")
        }
        button(view, containing: "Keep Awake").performClick(nil)
        view.layoutSubtreeIfNeeded()
        assertBackHover(material: false)
        let generation = view.debugNavigationState.generation
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        precondition(view.debugNavigationState.isAnimating == animates)
        precondition(view.debugRowIcons["2 hours"] == "clock")
        precondition(view.debugNavigationState.snapshotCount == 0)
        view.reload(menu: replacement)
        precondition(view.debugNavigationState.generation == generation,
                     "Unchanged timer refresh must not cancel navigation")
        pump(0.20)
        assertBackHover(material: false)
        precondition(view.debugNavigationState.snapshotCount == 0,
                     "Old root rows must not reappear after the short fade")
        precondition(button(view, containing: "2 hours").title == "2 hours")
        precondition(!buttons(view).contains { !$0.isHidden && $0.title == "Keep Awake With Lid Open" })
        pump(1.0)
        precondition(!view.debugNavigationState.isAnimating)
        precondition(view.debugNavigationState.snapshotCount == 0)
        assertBackHover(material: false)
        // Repeat in material mode: Back must hover before the list has settled,
        // and its transparent gutters must not become opaque patches.
        button(view, containing: "Back").performClick(nil)
        view.usesMaterial = true
        button(view, containing: "Keep Awake").performClick(nil)
        view.layoutSubtreeIfNeeded()
        assertBackHover(material: true)
        let materialGeneration = view.debugNavigationState.generation
        view.usesMaterial = true // Host repeats this every presentation frame.
        precondition(view.debugNavigationState.generation == materialGeneration)
        pump(0.20)
        assertBackHover(material: true)
        pump(1.0)
        precondition(!view.debugNavigationState.isAnimating)
        assertBackHover(material: true)
        view.usesMaterial = false
        // Rapid back/forward invalidates old cleanup; latest page remains live.
        for _ in 0..<3 {
            button(view, containing: "Back").performClick(nil)
            button(view, containing: "Keep Awake").performClick(nil)
            view.reload(menu: replacement)
        }
        pump(0.20)
        precondition(view.debugNavigationState.snapshotCount == 0)
        let live = button(view, containing: "2 hours")
        live.performClick(nil)
        precondition(performed === replacementSubmenu.items[0], "Refresh rebinds original action model")
        pump(1.0)
        precondition(!view.debugNavigationState.isAnimating)
        NotificationCenter.default.post(name: Notification.Name("wakelyAppearanceDidChange"), object: nil)
        precondition(view.debugRowIcons["2 hours"] == "clock")
        precondition(button(view, containing: "2 hours").toolTip == nil)
        window.orderOut(nil)
        print("PASS: menu actions, refresh, opaque inset hover, visible navigation, icons, and stale-hover cleanup")
    }
}
