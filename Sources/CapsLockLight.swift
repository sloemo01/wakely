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
        Diagnostics.log("caps lock switch stopped")
    }

    private static func poll() {
        guard policy.watching else { return }
        let secure = IsSecureEventInputEnabled()
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
        Diagnostics.log("accessibility trusted=\(AXIsProcessTrusted())")
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

    /// Caps Lock is an ordinary key. The light is the indicator and the key
    /// still types in caps, so no key events are filtered. This clears a tap
    /// left behind by a build that did filter them.
    @discardableResult
    static func installTypingFilter(active: Bool) -> Bool {
        policy.request(false)
        destroyTypingFilter()
        return true
    }

    private static func reconcileTypingFilter() {
        destroyTypingFilter()
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
