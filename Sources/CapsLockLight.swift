// Caps Lock owns the keyboard switch only while its component is enabled.
import Foundation
import IOKit
import IOKit.hid
import AppKit
import Carbon

/// Pure lifecycle decisions, separated from HID/TCC so they can be tested safely.
struct CapsLockFilterPolicy {
    private(set) var watching = false
    private(set) var requested = false
    private(set) var secureInput = false
    private(set) var restoreAfterSecureInput = false

    var shouldFilter: Bool { watching && requested && !secureInput }

    mutating func start() { watching = true }
    mutating func stop() {
        watching = false
        requested = false
        secureInput = false
        restoreAfterSecureInput = false
    }
    mutating func request(_ active: Bool) {
        requested = watching && active
        if !requested { restoreAfterSecureInput = false }
    }

    /// Returns a native lock-state change, if one is required. Secure password
    /// entry must never depend on a modifying event tap receiving secure events.
    mutating func updateSecureInput(_ secure: Bool, capsOn: Bool) -> Bool? {
        guard watching else { return nil }
        if secure {
            secureInput = true
            if requested && capsOn {
                restoreAfterSecureInput = true
                return false
            }
            return nil
        }
        guard secureInput else { return nil }
        secureInput = false
        let restore = requested && restoreAfterSecureInput && !capsOn
        restoreAfterSecureInput = false
        return restore ? true : nil
    }
}

@MainActor
enum CapsLockLight {
    private static var connection: io_connect_t = 0
    private static var filter: CFMachPort?
    private static var filterSource: CFRunLoopSource?
    private static var watcher: Timer?
    private static var policy = CapsLockFilterPolicy()
    private static var lastObserved = false
    private(set) static var lastKnown = false
    private static var ignoreUntil = Date.distantPast
    private static var lastTapAttempt = Date.distantPast
    private static var loggedMissingTrust = false
    static var onCapsLockChange: ((Bool) -> Void)?

    private static func systemConnection() -> io_connect_t {
        if connection != 0 { return connection }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect)
        guard result == kIOReturnSuccess else { return 0 }
        connection = connect
        return connect
    }

    /// Enable component watching, independently from the lifetime of a session.
    /// Does not change Caps Lock and does not request any permissions.
    @discardableResult
    static func startWatching() -> Bool {
        guard !policy.watching else { return true }
        policy.start()
        lastObserved = isLit
        lastKnown = lastObserved
        ignoreUntil = .distantPast
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in poll() }
        }
        watcher = timer
        RunLoop.main.add(timer, forMode: .common)
        Diagnostics.log("caps lock switch watching (currently \(lastObserved ? "on" : "off"))")
        return true
    }

    /// Disable the component without altering the user's ordinary Caps Lock state.
    static func stopWatching() {
        watcher?.invalidate()
        watcher = nil
        policy.stop()
        destroyTypingFilter()
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
        ignoreUntil = .distantPast
        lastTapAttempt = .distantPast
        loggedMissingTrust = false
        Diagnostics.log("caps lock switch stopped")
    }

    private static func poll() {
        guard policy.watching else { return }
        let secure = IsSecureEventInputEnabled()
        let state = isLit
        if let target = policy.updateSecureInput(secure, capsOn: state) {
            // Keep the switch watcher from interpreting password protection as
            // a user request to disarm/rearm the power engine.
            _ = writeLockState(target)
        }
        reconcileTypingFilter()
        let actual = isLit
        if secure || Date() < ignoreUntil {
            lastObserved = actual
            lastKnown = actual
            return
        }
        guard actual != lastObserved else { return }
        lastObserved = actual
        lastKnown = actual
        onCapsLockChange?(actual)
    }

    static func reportTrust() {
        Diagnostics.log("accessibility trusted=\(AXIsProcessTrusted()) (caps lock typing filter)")
    }

    static var isLit: Bool {
        var locked = false
        let connect = systemConnection()
        if connect != 0,
           IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &locked) == kIOReturnSuccess {
            return locked
        }
        return CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
    }

    /// A disabled component must never change the user's lock state.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard policy.watching else {
            Diagnostics.log("caps lock change skipped: component is off")
            return false
        }
        return writeLockState(on)
    }

    @discardableResult
    private static func writeLockState(_ on: Bool) -> Bool {
        let connect = systemConnection()
        guard connect != 0 else {
            Diagnostics.log("caps lock unavailable: no IOHIDSystem connection")
            return false
        }
        let result = IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), on)
        var actual = !on
        let read = IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &actual)
        let verified = result == kIOReturnSuccess && read == kIOReturnSuccess && actual == on
        if verified {
            lastKnown = actual
            lastObserved = actual
            ignoreUntil = Date().addingTimeInterval(0.2)
        }
        Diagnostics.log("caps lock native requested=\(on) set=\(result) read=\(read) actual=\(actual) verified=\(verified)")
        return verified
    }

    /// Pause/resume session typing protection without stopping component watching.
    /// Missing Accessibility is reported once, never opened or prompted here.
    @discardableResult
    static func installTypingFilter(active: Bool) -> Bool {
        policy.request(active)
        if policy.watching {
            if let target = policy.updateSecureInput(IsSecureEventInputEnabled(), capsOn: isLit) {
                _ = writeLockState(target)
            }
        }
        reconcileTypingFilter()
        return !active || (policy.shouldFilter && filter.map { CGEvent.tapIsEnabled(tap: $0) } == true)
    }

    private static func reconcileTypingFilter() {
        guard policy.shouldFilter else {
            destroyTypingFilter()
            return
        }
        guard AXIsProcessTrusted() else {
            destroyTypingFilter()
            if !loggedMissingTrust {
                loggedMissingTrust = true
                Diagnostics.log("caps lock typing filter unavailable: Accessibility not granted")
            }
            return
        }
        loggedMissingTrust = false
        if let tap = filter {
            if !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Retry after grants/recovery without rapidly attempting tap creation.
        guard Date().timeIntervalSince(lastTapAttempt) >= 1 else { return }
        lastTapAttempt = Date()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, _ in
            // The source is attached exclusively to the main run loop. Do not
            // modify an event if the platform unexpectedly invokes us elsewhere.
            guard Thread.isMainThread else { return Unmanaged.passUnretained(event) }
            return MainActor.assumeIsolated {
                CapsLockLight.handleEvent(type: type, event: event)
            }
        }, userInfo: nil) else { return }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return
        }
        filter = tap
        filterSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Diagnostics.log("caps lock typing filter active")
    }

    private static func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if policy.shouldFilter && !IsSecureEventInputEnabled(), let tap = filter {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard policy.shouldFilter, !IsSecureEventInputEnabled(), type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }
        event.flags.remove(.maskAlphaShift)
        return Unmanaged.passUnretained(event)
    }

    private static func destroyTypingFilter() {
        if let tap = filter { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = filterSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        if let tap = filter { CFMachPortInvalidate(tap) }
        let hadFilter = filter != nil
        filterSource = nil
        filter = nil
        if hadFilter { Diagnostics.log("caps lock typing filter removed") }
    }
}
