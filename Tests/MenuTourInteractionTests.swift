import AppKit
import SwiftUI
import CoreText

@main struct MenuTourInteractionTests {
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let fontDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Fonts/Pixel")
        for name in ["PixelOperator", "PixelOperator-Bold", "PixelOperator8", "PixelOperator8-Bold", "PixelOperatorMono", "PixelOperatorMono-Bold"] {
            let url = fontDirectory.appendingPathComponent(name + ".ttf")
            var error: Unmanaged<CFError>?
            precondition(CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error), "Register test pixel font: \(name)")
        }
        let snapshotDirectory = ProcessInfo.processInfo.environment["WAKELY_TOUR_TEST_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let snapshotDirectory {
            precondition(snapshotDirectory.path.hasPrefix("/"))
            try! FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        }
        let guide = GuideCoordinator.shared
        guide.dismiss()
        let root = NSMenu()
        func item(_ title: String, _ id: String) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: NSSelectorFromString("testAction:"), keyEquivalent: "")
            entry.identifier = .init(id)
            return entry
        }
        let arm = item("Arm Wakely", "tour.arm")
        root.addItem(arm)
        let keep = NSMenuItem(title: "Keep Awake With Lid Open", action: nil, keyEquivalent: "")
        keep.identifier = .init("tour.keepAwake")
        let lengths = NSMenu()
        for choice in KeepAwakeMenuPresentation.choices {
            let row = item(choice.title, "tour.duration.\(choice.minutes)")
            if choice.minutes == 120 { row.state = .on }
            lengths.addItem(row)
        }
        keep.submenu = lengths
        root.addItem(keep)
        for (name, id) in [("Components", "components"), ("Settings…", "settings"), ("About Wakely", "about"), ("Quit Wakely", "quit")] {
            root.addItem(item(name, "tour.\(id)"))
        }
        var performed = 0
        let view = GooMenuView(menu: root) { _ in performed += 1 }
        // Retained, never ordered or activated. A real backing context lets the
        // actual hosted SwiftUI footer composite into cacheDisplay captures.
        let snapshotWindow: NSWindow? = snapshotDirectory.map { _ in
            let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 320, height: 620), styleMask: [.borderless], backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.isOpaque = true
            window.isReleasedWhenClosed = false
            window.contentView = view
            return window
        }
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        func layout() {
            snapshotWindow?.setContentSize(view.preferredSize)
            view.frame.size = view.preferredSize
            view.layoutSubtreeIfNeeded()
        }
        for step in 8...12 {
            guide.previewOnboarding(step: step)
            view.syncHighlightedTour()
            layout()
            let visible = descendants(view).compactMap { $0 as? NSButton }.filter { !$0.isHidden && $0.title != "‹  Back" && ($0.title == "Arm Wakely" || $0.title == "Quit Wakely" || KeepAwakeMenuPresentation.choices.map(\.title).contains($0.title)) }
            for button in visible {
                button.performClick(nil)
                _ = button.accessibilityPerformPress()
            }
            view.activateFirst()
            view.keyDown(with: event)
            precondition(performed == 0, "Tour must not dispatch original model actions")
            let scroll = view.subviews.compactMap { $0 as? NSScrollView }.first!
            let footer = view.subviews.first { $0 is NSHostingView<HighlightTourCoach> }!
            precondition(view.bounds.contains(footer.frame), "Coach must fit the compact view")
            precondition(scroll.frame.maxY <= footer.frame.minY, "Coach must not cover the real rows")
            precondition(footer.frame.height >= 220 && scroll.frame.height > 0)
            if let snapshotDirectory {
                // Flush hosted layout without ordering the window or sending input.
                RunLoop.main.run(until: Date().addingTimeInterval(0.08))
                layout()
                footer.layoutSubtreeIfNeeded()
                let natural = footer.fittingSize
                print("snapshot step=\(step) footer=\(footer.frame.size) fitting=\(natural)")
                precondition(natural.height <= footer.bounds.height + 1, "Actual coach content must fit reserved footer")
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No cache bitmap") }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])!
                try! data.write(to: snapshotDirectory.appendingPathComponent("menu-step-\(step).png"))
                precondition(snapshotWindow?.isVisible == false, "Test must never order a window")
            }
            if step == 11 {
                precondition(view.debugSelectedTitles == ["2 hours"], "Tour retains only actual checkmark state")
                precondition(view.debugRowIcons.keys.contains("1 hour"), "Durations use actual submenu")
            } else {
                precondition(view.debugRowIcons.keys.contains("Arm Wakely"), "Other steps show original root")
            }
        }
        // Removing Keep Awake immediately omits its active step; rebuilding the
        // real menu drives normalization without a preview/go/next call.
        guide.previewOnboarding(step: 11)
        view.syncHighlightedTour()
        layout()
        precondition(guide.menuKeepAwakeAvailable == true)
        precondition(guide.currentTourStep.title == "Choose how long")
        root.removeItem(keep)
        ComponentEngine.shared.keepAwakeEnabled = false
        view.reload(menu: root)
        layout()
        precondition(guide.currentTourStep == .menuNavigation && guide.progress.step == 12)
        precondition(guide.menuKeepAwakeAvailable == false)
        precondition(guide.displayedStep == 11 && guide.displayedStepCount == 12)
        precondition(!guide.availableTourSteps.contains(.menuKeepAwake) && !guide.availableTourSteps.contains(.menuDurations))
        precondition(!view.debugRowIcons.keys.contains("1 hour"))
        precondition(HighlightTourCoach(compact: true).explanation == guide.currentTourStep.explanation)
        precondition(performed == 0)
        if let snapshotDirectory {
            RunLoop.main.run(until: Date().addingTimeInterval(0.08))
            layout()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(
                to: snapshotDirectory.appendingPathComponent("menu-disabled-during-step.png"))
        }
        ComponentEngine.shared.keepAwakeEnabled = true
        root.insertItem(keep, at: 1)
        view.reload(menu: root)
        layout()
        precondition(guide.currentTourStep == .menuNavigation && guide.progress.step == 12)
        precondition(guide.menuKeepAwakeAvailable == true && guide.displayedStepCount == 14)
        precondition(!view.debugRowIcons.keys.contains("1 hour"))
        guide.previous()
        view.syncHighlightedTour()
        layout()
        precondition(guide.currentTourStep == .menuDurations)
        precondition(view.debugRowIcons.keys.contains("1 hour"))
        precondition(view.debugSelectedTitles == ["2 hours"])
        precondition(guide.currentTourStep.title == "Choose how long")
        precondition(performed == 0)
        print("PASS: disable omits optional steps immediately; re-enable restores Back without rewinding or actions")

        // A live rebuild, absent optional component, and repeated step reversal.
        root.removeItem(keep)
        ComponentEngine.shared.keepAwakeEnabled = false
        for step in [11, 9, 12, 10, 11] {
            guide.previewOnboarding(step: step)
            view.reload(menu: root)
            view.syncHighlightedTour()
            layout()
            precondition(view.debugRowIcons.keys.contains("Components"))
            precondition(guide.progress.step == ((step == 10 || step == 11) ? 12 : step))
            precondition(guide.displayedStepCount == 12)
            precondition(performed == 0)
        }
        guide.go(to: 9)
        guide.next()
        view.syncHighlightedTour()
        precondition(guide.progress.step == 12)
        guide.previous()
        view.syncHighlightedTour()
        precondition(guide.progress.step == 9)
        guide.dismiss()
        view.syncHighlightedTour()
        layout()
        let armButton = descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "Arm Wakely" }!
        armButton.performClick(nil)
        precondition(performed == 1, "Dismiss restores original actions")
        precondition(view.subviews.first { $0 is NSHostingView<HighlightTourCoach> }!.isHidden)
        // A Settings-tour step must also block programmatic leaf activation.
        guide.previewOnboarding(step: 0)
        armButton.performClick(nil)
        precondition(performed == 1)
        guide.dismiss()
        print("MenuTourInteractionTests passed (real rows + actual coach; no engine linked)")
    }
}
