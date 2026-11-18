import AppKit

/// CFMachPort is not Sendable. The cleaning-lock deadline only disables the tap
/// from another queue; the tap is retained by this controller for its lifetime,
/// so the box does not add unsynchronised access to it.
private final class UncheckedEventTap: @unchecked Sendable {
    let port: CFMachPort
    init(_ port: CFMachPort) { self.port = port }
}

/// Input is blocked only after a working event tap exists. A separate-queue
/// deadline disables that tap even if the main run loop becomes unresponsive.
@MainActor
final class CleaningLockController {
    static let shared = CleaningLockController()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var panels: [NSPanel] = []
    private var labels: [NSTextField] = []
    private var timer: Timer?
    private var deadline: Date?
    private var escapeSince: Date?
    private var generation = UUID()
    private(set) var failureReason = ""
    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    @discardableResult
    func begin(seconds: Int) -> Bool {
        end()
        failureReason = ""
        guard AXIsProcessTrusted() else {
            failureReason = "Accessibility access is missing or was revoked. Open Set Up, allow Wakely, then turn the switch on again. Your keyboard is not locked."
            Diagnostics.log("cleaning lock unavailable: Accessibility permission required")
            return false
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                   .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                   .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel,
                                   CGEventType(rawValue: 14)!] // NX_SYSDEFINED (media keys)
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                let controller = Unmanaged<CleaningLockController>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    controller.end()
                    return Unmanaged.passUnretained(event)
                }
                if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                    if type == .keyDown { controller.escapeSince = controller.escapeSince ?? Date() }
                    if type == .keyUp { controller.escapeSince = nil }
                }
                return nil
            }
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            failureReason = "macOS refused the input blocker. Check Accessibility access for this copy of Wakely and relaunch it if macOS requests it. Your keyboard is not locked."
            Diagnostics.log("cleaning lock unavailable: cannot install input blocker")
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        let duration = max(1, min(300, seconds))
        deadline = Date().addingTimeInterval(Double(duration))
        generation = UUID()
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            let label = NSTextField(labelWithString: "Cleaning Lock — \(duration)s\nHold Esc for 3 seconds to finish")
            label.textColor = .white; label.alignment = .center
            label.font = .systemFont(ofSize: 28, weight: .medium)
            label.frame = NSRect(x: 0, y: screen.frame.height / 2 - 50, width: screen.frame.width, height: 100)
            panel.contentView?.addSubview(label)
            panel.orderFrontRegardless()
            panels.append(panel); labels.append(label)
        }
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            failureReason = "The input blocker did not become active. Your keyboard is not locked. Check Accessibility access and try again."
            end()
            return false
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated { CleaningLockController.shared.tick() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        let token = generation
        // CFMachPort is a CoreFoundation object, not Sendable. The tap outlives
        // this closure and is only disabled here, so carry it in an explicitly
        // unchecked box rather than importing the whole component preconcurrently.
        let boxedTap = UncheckedEventTap(port)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Double(duration) + 0.25) {
            CGEvent.tapEnable(tap: boxedTap.port, enable: false)
            Task { @MainActor in
                if CleaningLockController.shared.generation == token { CleaningLockController.shared.end() }
            }
        }
        return true
    }

    private func tick() {
        guard let deadline else { end(); return }
        let remaining = deadline.timeIntervalSinceNow
        if let escapeSince, Date().timeIntervalSince(escapeSince) >= 3 { end(); return }
        // Do not cancel because a browser or Finder is still the frontmost app:
        // the cover panels are intentionally nonactivating, so Wakely may never
        // be frontmost while the lock is doing exactly what it should.
        if remaining <= 0 { end(); return }
        for label in labels { label.stringValue = "Cleaning Lock — \(Int(ceil(remaining)))s\nHold Esc for 3 seconds to finish" }
    }

    func end() {
        let hadTap = tap != nil
        timer?.invalidate(); timer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; deadline = nil; escapeSince = nil
        for panel in panels { panel.orderOut(nil); panel.close() }
        panels = []; labels = []
        if hadTap {
            Task { @MainActor in
                // A new lock may have started since this asynchronous cleanup.
                guard self.tap == nil else { return }
                if ComponentEngine.shared.isEnabled("cleaningLock") {
                    ComponentEngine.shared.setEnabled("cleaningLock", false)
                }
                SettingsModel.shared.cleaningLockMessage = "Input is unlocked."
            }
        }
    }
}
