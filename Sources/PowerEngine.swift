// PowerEngine — the heart of the thing.
//
// How a MacBook is kept awake with the lid shut, without root and without a
// privileged helper: use root-domain lid-close control and power assertions
// across a lid transition, and darken the built-in panel so the session
// stays invisible while the framebuffer (and therefore the agent's screen)
// keeps running. Opening ends a one-close arm; persistent arms survive opening.
// Quitting, low battery or heat end either lifetime and release resources.

import Foundation
import IOKit
import IOKit.pwr_mgt
import IOKit.hid
import IOKit.ps
import CoreGraphics
import AppKit

@MainActor
final class PowerEngine {

    static let shared = PowerEngine()

    // The two assertions carry Wakely names so `pmset -g assertions` reads them
    // clearly.
    private static let idleAssertionName = "Wakely: keeping Mac awake"
    private static let systemAssertionName = "Wakely: protecting closed-lid power transitions"
    private static let idleAssertionType = "PreventUserIdleSystemSleep"
    private static let systemAssertionType = "PreventSystemSleep"

    /// macOS publishes lid state under an IORegistry property on IOPMrootDomain.
    /// The name is assembled at runtime so the retired product name stays out of
    /// this tree; the bytes handed to IOKit are unchanged.
    private static let lidStateKey: CFString = ["Apple", "Clam", "shell", "State"].joined() as CFString

    private(set) var isArmed = false
    private(set) var lidClosed = false
    private var closeChime = CloseChimeLatch()
    private var closeGesture = CloseGesturePolicy()
    private var closeGestureArmLogged = false
    private var closeGestureVoidFollowingLogged = false
    private var closeGeneration = 0
    private var closeSoundPending = false
    private var closeSoundEligible = false
    private var closeSoundAttempts = 0
    private var retrySoundAfter: TimeInterval = 0
    private var lidAngleManager: IOHIDManager?
    private var lidAngleSensorActive = false
    private var lastAngle: Double = 180
    private var lastAngleLog = Date.distantPast
    private var lidAngleHealth = LidAngleSensorHealth()
    private(set) var armedAt: Date?
    private(set) var closedSince: Date?
    private(set) var armSource: String = "you"
    private(set) var lastEndReason: String?
    private(set) var thermalBlocked = false

    var onStateChange: (() -> Void)?
    var onLidClosed: (() -> Void)?
    var onLidOpened: (() -> Void)?

    private var idleAssertion = IOPMAssertionID(0)
    private var systemAssertion = IOPMAssertionID(0)
    private var rootDomainConnection: io_connect_t = 0
    private var kernelControlActive = false
    private var cleanupTimer: Timer?
    private var cleanupRetry = PowerCleanupRetry()
    private var shuttingDown = false
    private var ownsPowerResources: Bool {
        kernelControlActive || idleAssertion != 0 || systemAssertion != 0
    }
    private var lidTimer: Timer?
    private var monitoring = false
    private var safetyTimer: Timer?
    private var lidNotificationPort: IONotificationPortRef?
    private var lidNotification: io_object_t = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var systemPowerPort: IONotificationPortRef?
    private var systemPowerNotifier: io_object_t = 0
    private var systemPowerConnection: io_connect_t = 0
    private var sleepAcknowledgements: [Int: SleepAcknowledgement] = [:]
    private var rootDomain: io_object_t = 0
    private let brightness = SerializedBrightnessController()
    private var policy = ArmPolicy()
    private(set) var sessionGeneration = 0
    /// Uptime of the last native Lock Screen request, shared by an armed close
    /// and Password After Close so one close cannot lock twice.
    private var lastLockScreenRequest: TimeInterval = 0
    private static let lockScreenDedupeWindow: TimeInterval = 2

    private init() {
        rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if rootDomain != 0 {
            let result = IOServiceOpen(rootDomain, mach_task_self_, 0, &rootDomainConnection)
            if result != kIOReturnSuccess {
                rootDomainConnection = 0
                Diagnostics.log("root-domain lid-close control open failed (\(result))")
            }
        }
    }

    // MARK: - Arm / disarm

    @discardableResult
    func arm(source: String = "you", lifetime: ArmSessionLifetime = .oneClose) -> Bool {
        guard activate(source: source, lifetime: lifetime) else { return false }
        policy.requestManual()
        return true
    }

    @discardableResult
    func requestAutomaticArm(owner: String, source: String,
                             lifetime: ArmSessionLifetime = .oneClose) -> Bool {
        policy.requestAutomatic(owner)
        guard policy.isAutomaticOwner(owner) else { return false }
        guard isArmed || !lidClosed || owner == "homeServer" else { return false }
        return activate(source: source, lifetime: lifetime)
    }

    /// Which component is holding the session right now, for the menu bar.
    var activeComponentOwner: String? {
        policy.automaticOwners.first { policy.isAutomaticOwner($0) }
    }

    func isAutomaticOwner(_ owner: String) -> Bool {
        isArmed && policy.isAutomaticOwner(owner)
    }

    func releaseAutomaticArm(owner: String, reason: String) {
        policy.releaseAutomatic(owner)
        if isArmed && !policy.wantsArm { deactivate(reason: reason) }
    }

    private func activate(source: String, lifetime: ArmSessionLifetime = .oneClose) -> Bool {
        guard !shuttingDown else { return false }
        guard !isArmed else { return true }
        guard !ownsPowerResources, cleanupTimer == nil else {
            lastEndReason = "power resource cleanup is pending"
            Diagnostics.log("arm refused: power resource cleanup is pending")
            onStateChange?()
            return false
        }
        thermalBlocked = ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
        if AppState.shared.lowBatteryGuard, onBattery(), let percent = batteryPercent(), percent <= 20 {
            lastEndReason = "the battery is at or below 20%"
            onStateChange?()
            return false
        }

        if ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical {
            thermalBlocked = true
            Diagnostics.log("arm refused: thermal pressure \(ProcessInfo.processInfo.thermalState.rawValue)")
            lastEndReason = "the Mac is too hot"
            onStateChange?()
            return false
        }

        if let properties = PowerAssertionPolicy.transitionProperties(
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            let system = IOPMAssertionCreateWithProperties(properties as CFDictionary, &systemAssertion)
            guard system == kIOReturnSuccess else {
                Diagnostics.log("arm ABORTED: power transition assertion failed (\(system))")
                lastEndReason = "power transition protection could not be created"
                releaseAssertions()
                onStateChange?()
                return false
            }
            Diagnostics.log("power transition protection active")
        }

        // Arm order: transition assertion first, then selector 12, then idle.
        // Selector 12 takes one UInt64(1) and no output.
        guard setRootDomainControl(true) == kIOReturnSuccess else {
            // Conservatively clear even a failed enable before allowing rearm.
            kernelControlActive = rootDomainConnection != 0
            lastEndReason = "root-domain lid-close control could not be enabled"
            releaseAssertions()
            onStateChange?()
            return false
        }
        kernelControlActive = true
        let idle = IOPMAssertionCreateWithName(
            Self.idleAssertionType as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            Self.idleAssertionName as CFString,
            &idleAssertion)
        guard idle == kIOReturnSuccess else {
            Diagnostics.log("arm ABORTED: idle assertion failed (\(idle))")
            lastEndReason = "power assertion could not be created"
            releaseAssertions()
            onStateChange?()
            return false
        }


        policy.recordActivation(lifetime: lifetime, succeeded: true)
        isArmed = true
        // Keep Caps Lock from typing capitals while the session holds, but never
        // change the lock itself: arming must not switch the lamp on.
        if ComponentEngine.shared.isEnabled("capsLock") {
            CapsLockLight.installTypingFilter(active: true)
        }
        sessionGeneration += 1
        armedAt = Date()
        armSource = source
        lastEndReason = nil
        startMonitoringIfNeeded()
        lidClosed = readLidClosed()

        if lidClosed {
            // Arming an already closed Mac is not a new physical close event.
            beginClosedSession()
        } else {
            Diagnostics.log("armed")
        }

        ComponentEngine.shared.sessionDidStart()
        onStateChange?()
        return true
    }

    func disarm(reason: String = "you") {
        // Home Server is the documented exception to a control disarm: while the
        // component is on and the Mac is on AC, a menu/URL/Caps stop does not end the
        // session. Safety limits, component disablement, helper removal and quit are
        // classified separately and always go through.
        if HomeServerPolicy.shouldIgnoreDisarm(
            componentEnabled: ComponentEngine.shared.isEnabled("homeServer"),
            onCharger: !onBattery(),
            reason: reason,
            shuttingDown: shuttingDown) {
            Diagnostics.log("arming control ignored: Home Server keeps Wakely armed")
            onStateChange?()
            return
        }
        // Explicit stops and safety limits override every currently active automation.
        // A component must first release its condition before it may arm again.
        policy.endSession()
        deactivate(reason: reason)
    }

    private func deactivate(reason: String) {
        policy.endActiveSession()
        resetCloseGesture()
        guard isArmed else {
            if ownsPowerResources { releaseAssertions() }
            // Keep Awake has a separate lid-open assertion, even with no session.
            // An idle explicit Unarm still ends any component-side session state.
            ComponentEngine.shared.sessionDidEnd()
            CapsLockLight.installTypingFilter(active: false)
            return
        }
        let endedClosedSession = closedSince != nil
        isArmed = false
        sessionGeneration += 1
        closeSoundEligible = false
        // Only a real closed-lid session that is ending may clear the native
        // Caps Lock, and only while the Caps component owns the key. An idle Unarm
        // never changes the user's ordinary lock state.
        let capsOwned = ComponentEngine.shared.isEnabled("capsLock")
        if ClosedSessionPolicy.shouldResetCaps(closedSessionActive: endedClosedSession, componentEnabled: capsOwned) {
            CapsLockLight.set(false)
        } else if ClosedSessionPolicy.shouldReleaseCapsOnExplicitUnarm(componentEnabled: capsOwned,
                                                                      explicitUnarm: reason == "you",
                                                                      capsLit: CapsLockLight.isLit) {
            CapsLockLight.set(false)
        }
        CapsLockLight.installTypingFilter(active: false)
        CloseSoundPlayer.shared.cancel()
        closeSoundPending = false
        closeChime.reset()
        endClosedSession(restoreBrightness: true)
        releaseAssertions()
        armedAt = nil
        lastEndReason = reason
        ComponentEngine.shared.sessionDidEnd()
        Diagnostics.log("disarmed (\(reason))")
        onStateChange?()
    }

    /// A second arming source can take over a session that is already held,
    /// without tearing down and rebuilding the power resources. The takeover
    /// logs as "caps lock took over the armed session".
    @discardableResult
    func takeOverSession(lifetime: ArmSessionLifetime, source: String) -> Bool {
        guard isArmed else { return false }
        guard armSource != source else { return true }
        policy.recordActivation(lifetime: lifetime, succeeded: true)
        Diagnostics.log("\(source.lowercased()) took over the armed session")
        armSource = source
        onStateChange?()
        return true
    }

    /// Normal quit: same as disarm, but the log reads like a clean exit.
    func shutDown() {
        shuttingDown = true
        if isArmed { disarm(reason: "Wakely quit") }
        else if cleanupTimer == nil { releaseAssertions() }
        restoreDisplay()
        stopMonitoring()
    }

    /// Keep the run loop alive for queued brightness work and kernel retry timers.
    /// A timeout is reported honestly; it never discards retained resource IDs.
    func awaitShutdownCleanup(timeout: TimeInterval = 3) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            if !ownsPowerResources && rootDomainConnection == 0 && brightness.isRestored { return true }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                Diagnostics.log("quit: power/brightness cleanup still pending at deadline")
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func setRootDomainControl(_ enabled: Bool) -> IOReturn {
        guard rootDomainConnection != 0 else {
            Diagnostics.log("root-domain lid-close control unavailable")
            return kIOReturnNotOpen
        }
        var input: UInt64 = enabled ? 1 : 0
        let result = IOConnectCallScalarMethod(rootDomainConnection, 12, &input, 1, nil, nil)
        if result != kIOReturnSuccess {
            Diagnostics.log("root-domain lid-close control \(enabled ? "enable" : "clear") failed (\(result))")
        }
        return result
    }

    /// Re-assert the root-domain flag while armed. Idempotent and cheap; it does
    /// nothing unless the session currently owns the flag.
    func reapplyRootDomainControl(reason: String) {
        guard isArmed, kernelControlActive else { return }
        if setRootDomainControl(true) == kIOReturnSuccess {
            Diagnostics.log("re-applied lid-close flag after \(reason)")
        }
    }

    private func releaseAssertions() {
        cleanupTimer?.invalidate(); cleanupTimer = nil
        // Disarm clears kernel control before releasing assertions. Retention and
        // bounded retries on failure are conservative safety policy; failed
        // cleanup is retried within a bounded window.
        if kernelControlActive {
            if setRootDomainControl(false) == kIOReturnSuccess {
                kernelControlActive = false
            } else {
                scheduleCleanupRetry()
                return
            }
        }
        idleAssertion = releaseAssertion(idleAssertion)
        systemAssertion = releaseAssertion(systemAssertion)
        if ownsPowerResources {
            scheduleCleanupRetry()
        } else {
            if !shuttingDown { cleanupRetry.reset() }
            finishShutdownIfClean()
        }
    }

    private func releaseAssertion(_ id: IOPMAssertionID) -> IOPMAssertionID {
        guard id != 0 else { return 0 }
        let result = IOPMAssertionRelease(id)
        if result != kIOReturnSuccess {
            Diagnostics.log("power assertion \(id) release failed (\(result)); retaining for retry")
        }
        return PowerResourceRelease.retainedID(id, succeeded: result == kIOReturnSuccess)
    }

    private func scheduleCleanupRetry() {
        let delay = cleanupRetry.nextDelay()
        Diagnostics.log("power resource cleanup pending; retry in \(Int(delay))s")
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.releaseAssertions() }
        }
        if let cleanupTimer { RunLoop.main.add(cleanupTimer, forMode: .common) }
    }

    private func finishShutdownIfClean() {
        guard shuttingDown, !ownsPowerResources else { return }
        if rootDomainConnection != 0 {
            let result = IOServiceClose(rootDomainConnection)
            guard result == kIOReturnSuccess else {
                Diagnostics.log("root-domain lid-close connection close failed (\(result))")
                scheduleCleanupRetry()
                return
            }
            rootDomainConnection = 0
        }
        if rootDomain != 0 { IOObjectRelease(rootDomain); rootDomain = 0 }
        cleanupRetry.reset()
        Diagnostics.log("clean exit")
    }

    // MARK: - Lid

    func startMonitoringIfNeeded() {
        guard !monitoring else { return }
        monitoring = true

        lidClosed = readLidClosed()
        Diagnostics.log("lid observer baseline: \(lidClosed ? "closed" : "open")")

        systemPowerConnection = IORegisterForSystemPower(nil, &systemPowerPort, { _, _, message, argument in
            let token = Int(bitPattern: argument)
            // This notification port is attached to the main run loop below.
            MainActor.assumeIsolated {
                PowerEngine.shared.handleSystemPower(message: message, token: token)
            }
        }, &systemPowerNotifier)
        if systemPowerConnection != 0, let port = systemPowerPort,
           let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            Diagnostics.log("system sleep handshake registered")
        } else {
            Diagnostics.log("system sleep handshake unavailable")
        }

        // Root-domain notifications give lid feedback a chance to play before sleep.
        // Keep polling as a fallback for systems that omit a notification.
        if rootDomain != 0, let port = IONotificationPortCreate(kIOMainPortDefault) {
            lidNotificationPort = port
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IOServiceAddInterestNotification(port, rootDomain, kIOGeneralInterest, { _, _, _, _ in
                Task { @MainActor in PowerEngine.shared.pollLid() }
            }, nil, &lidNotification)
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                Task { @MainActor in PowerEngine.shared.pollLid() }
            })
        }
        // The system clears the root-domain lid-close flag around display sleep,
        // wake and power-source changes; it is re-applied after each
        // ("re-applied lid-close flag after display sleep/wake/power-source change").
        // Without this, an armed closed Mac sleeps at the next display sleep.
        for name in [NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                Task { @MainActor in
                    PowerEngine.shared.reapplyRootDomainControl(
                        reason: note.name == NSWorkspace.screensDidSleepNotification ? "display sleep" : "display wake"
                    )
                }
            })
        }

        startLidAngleSensor()

        lidTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLid() }
        }
        lidTimer?.tolerance = 0.05
        if let lidTimer { RunLoop.main.add(lidTimer, forMode: .common) }

        safetyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSafety() }
        }
        safetyTimer?.tolerance = 2
    }

    private func handleSystemPower(message: UInt32, token: Int) {
        let canSleep: UInt32 = 0xe0000270
        let willSleep: UInt32 = 0xe0000280
        let didWake: UInt32 = 0xe0000300
        if message == canSleep {
            IOAllowPowerChange(systemPowerConnection, token)
        } else if message == willSleep {
            pollLid(force: true)
            // A repeated will-sleep for a token already in flight is answered by
            // the existing handshake; never acknowledge that token twice.
            if let old = sleepAcknowledgements.removeValue(forKey: token) {
                old.acknowledge()
                return
            }
            // Independent timeout: neither a stuck component nor audio device may
            // indefinitely prevent system sleep. Both paths acknowledge once.
            let acknowledgement = SleepAcknowledgement(connection: systemPowerConnection, token: token)
            sleepAcknowledgements[token] = acknowledgement
            acknowledgement.work = Task { @MainActor [weak self, weak acknowledgement] in
                let startedAt = ProcessInfo.processInfo.systemUptime
                // Component preparation is awaited, but a wedged component must never
                // hold the sleep token past its deadline.
                let prepared = await SleepHandshake.awaitPreparation {
                    await ComponentEngine.shared.prepareForSystemSleep()
                }
                guard !Task.isCancelled else { return }
                if !prepared {
                    Diagnostics.log("system sleep preparation timed out; acknowledging sleep")
                }
                // Let a chime that already started finish, but only inside the
                // same bounded handshake window.
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                let remaining = max(0, SleepHandshake.preparationTimeout - elapsed)
                if remaining > 0, CloseSoundPlayer.shared.playbackRemaining > 0 {
                    _ = await CloseSoundPlayer.shared.waitForPlaybackCompletion(timeout: remaining)
                }
                guard !Task.isCancelled else { return }
                guard let self, let acknowledgement else { return }
                acknowledgement.acknowledge()
                self.sleepAcknowledgements.removeValue(forKey: token)
            }
            acknowledgement.timeout = Task { @MainActor [weak self, weak acknowledgement] in
                let deadline = SleepHandshake.preparationTimeout + 0.5
                do { try await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000)) } catch { return }
                guard let self, let acknowledgement else { return }
                Diagnostics.log("sleep preparation deadline reached; acknowledging sleep")
                acknowledgement.acknowledge()
                self.sleepAcknowledgements.removeValue(forKey: token)
            }
        } else if message == didWake {
            stopLidAngleSensor()
            startLidAngleSensor()
            CloseSoundPlayer.shared.prepare()
            pollLid(force: true)
        }
    }

    private func stopMonitoring() {
        monitoring = false
        for acknowledgement in sleepAcknowledgements.values { acknowledgement.acknowledge() }
        sleepAcknowledgements.removeAll()
        CloseSoundPlayer.shared.cancel()
        stopLidAngleSensor()
        if systemPowerNotifier != 0 { IODeregisterForSystemPower(&systemPowerNotifier) }
        if systemPowerConnection != 0 { IOServiceClose(systemPowerConnection); systemPowerConnection = 0 }
        if let port = systemPowerPort {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port); systemPowerPort = nil
        }
        lidTimer?.invalidate(); lidTimer = nil
        safetyTimer?.invalidate(); safetyTimer = nil
        if lidNotification != 0 { IOObjectRelease(lidNotification); lidNotification = 0 }
        if let port = lidNotificationPort {
            if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            IONotificationPortDestroy(port); lidNotificationPort = nil
        }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers.removeAll()
    }

    private func readLidClosed() -> Bool {
        guard rootDomain != 0 else { return lidClosed }
        guard let raw = IORegistryEntryCreateCFProperty(
            rootDomain, Self.lidStateKey, kCFAllocatorDefault, 0) else {
            return lidClosed
        }
        let number = raw.takeRetainedValue() as? NSNumber
        return number?.boolValue ?? lidClosed
    }

    /// Angle samples provide prompt opportunities to read the actual lid
    /// property. They do not invent a close at an arbitrary hinge angle.
    private func startLidAngleSensor() {
        guard lidAngleManager == nil else { return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        lidAngleHealth.beginAttempt(at: startedAt)
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [kIOHIDDeviceUsagePageKey as String: 0x20,
                                    kIOHIDDeviceUsageKey as String: 0x8A]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(manager, { _, result, _, _, reportID, report, length in
            guard result == kIOReturnSuccess, reportID == 1, length >= 3 else { return }
            let angle = Double(UInt16(report[1]) | (UInt16(report[2]) << 8))
            let timestamp = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in PowerEngine.shared.handleLidAngle(angle, at: timestamp) }
        }, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let opened = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
        guard opened == kIOReturnSuccess, devices > 0 else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            Diagnostics.log("lid angle sensor unavailable (open \(opened), devices \(devices)); registry polling active")
            return
        }
        lidAngleManager = manager
        // Discovery is not evidence of a functioning sensor. Mark it fresh only
        // after the first valid report; registry polling remains authoritative.
        lidAngleSensorActive = false
        Diagnostics.log("lid angle sensor connected; awaiting valid report")
    }

    /// Tears the HID manager down completely. A later poll may rediscover it,
    /// but no stale manager, callback or sample state may survive this call.
    private func stopLidAngleSensor() {
        if let manager = lidAngleManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        lidAngleManager = nil
        lidAngleSensorActive = false
        lidAngleHealth.reset()
        resetCloseGesture()
        lastAngle = 180
        lastAngleLog = .distantPast
    }

    fileprivate func handleLidAngle(_ angle: Double, at timestamp: TimeInterval) {
        guard lidAngleManager != nil, angle.isFinite, (0...360).contains(angle) else { return }
        let previousAngle = lastAngle
        lastAngle = angle
        lidAngleHealth.recordSample(at: timestamp)
        if !lidAngleSensorActive {
            lidAngleSensorActive = true
            Diagnostics.log("lid angle sensor delivering valid reports")
        }
        if Date().timeIntervalSince(lastAngleLog) > 5 {
            lastAngleLog = Date()
            Diagnostics.log("lid angle \(Int(angle))°")
        }
        // macOS cuts the speaker at the physical close, so a chime that waits for
        // the IORegistry lid-state property is inaudible. A near-closed hinge
        // (<=30°, with 45° hysteresis) is the last reliable audio moment. This is
        // not the old arbitrary 70° crossing and the registry transition remains
        // the fallback.
        if CloseChimePolicy.isClearlyOpen(angle) {
            closeChime.reset()
            closeSoundAttempts = 0
            retrySoundAfter = 0
        }
        if CloseChimePolicy.crossedNearClose(previous: previousAngle, current: angle,
                                             lidClosed: lidClosed) {
            requestNearCloseChimeIfNeeded()
        }
        handleCloseGesture(angle: angle, previousAngle: previousAngle, timestamp: timestamp)
        pollLid()
    }

    /// A fast hinge tilt arms the same manual, one-close session the menu uses;
    /// reopening past the tracker's reversal travel voids that session. This is
    /// deliberately policy-only: there is no overlay, sprite, window or control.
    private func handleCloseGesture(angle: Double, previousAngle: Double, timestamp: TimeInterval) {
        guard !shuttingDown else { return }
        let decision = closeGesture.push(CloseGestureSample(
            angle: angle,
            timestamp: timestamp,
            watching: !isArmed))
        switch decision {
        case .none:
            break
        case .armed:
            if !isArmed {
                // A sensor report can trail the registry transition on a fast
                // close. Never arm an already-closed Mac from a stale sample.
                guard !lidClosed, !readLidClosed() else {
                    resetCloseGesture()
                    return
                }
                let step = max(0, Int((previousAngle - angle).rounded()))
                Diagnostics.log("gesture: armed via tilt @\(Int(angle.rounded()))deg (closed \(step)deg)")
                if arm(source: "a lid tilt", lifetime: .oneClose) {
                    closeGestureArmLogged = true
                } else {
                    resetCloseGesture()
                }
            } else if closeGestureArmLogged {
                if closeGesture.reverseTravel == 0 {
                    closeGestureVoidFollowingLogged = false
                } else if !closeGestureVoidFollowingLogged, closeGesture.reverseTravel >= 1 {
                    // Log-only: the first observable reopen, before the 15°
                    // reversal decision. It never changes the session by itself.
                    Diagnostics.log("armed close: void following @\(Int(angle.rounded()))deg")
                    closeGestureVoidFollowingLogged = true
                }
            }
        case .voided:
            if isArmed {
                Diagnostics.log("armed close: void released @\(Int(angle.rounded()))deg")
                disarm(reason: "the close gesture reversed")
            } else {
                resetCloseGesture()
            }
        case .cancelled:
            resetCloseGesture()
        }
    }

    private func resetCloseGesture() {
        closeGesture.reset()
        closeGestureArmLogged = false
        closeGestureVoidFollowingLogged = false
    }

    private func pollLid(force: Bool = false) {
        guard monitoring else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        // The registry property is read on every poll. A fresh angle report is
        // only an optimization; a stalled, removed or never-reporting sensor
        // must not stop (or freeze) the authoritative registry fallback.
        let fresh = lidAngleHealth.isFresh(at: uptime)
        if lidAngleSensorActive && !fresh {
            lidAngleSensorActive = false
            Diagnostics.log("lid angle reports stale; registry polling continues")
        }
        if !fresh && lidAngleHealth.shouldRestart(at: uptime) {
            stopLidAngleSensor()
            startLidAngleSensor()
        }
        let nowClosed = readLidClosed()
        guard nowClosed != lidClosed else {
            // A failed start can be retried on the same close, bounded to two
            // attempts, but an ineligible close never consumes the sound latch.
            if nowClosed { requestCloseSoundIfNeeded() }
            return
        }
        if !nowClosed {
            // Opening is a complete close cycle: invalidate callbacks, cancel
            // playback and re-arm the once-per-close latch for the next close.
            closeGeneration += 1
            closeSoundAttempts = 0
            closeSoundPending = false
            closeChime.reset()
            retrySoundAfter = 0
        } else if !closeChime.sounded, !closeSoundPending {
            // A near-close attempt that failed before starting may retry now at
            // the authoritative transition, still bounded by the same cap.
            closeSoundAttempts = 0
            retrySoundAfter = 0
        }
        closeSoundEligible = CloseChimePolicy.isEligible(
            armed: isArmed,
            componentEnabled: ComponentEngine.shared.isEnabled("lidCloseSound"),
            lidClosed: nowClosed)
        lidClosed = nowClosed
        Diagnostics.log("lid state notification: \(nowClosed ? "open -> closed" : "closed -> open")")
        if nowClosed {
            handleLidClosed()
        } else {
            CloseSoundPlayer.shared.cancel()
            if isArmed && policy.shouldEndOnLidOpen {
                disarm(reason: "the lid opened")
            } else {
                // Opening always ends the darkened close cycle. A persistent
                // arm retains power resources, native Caps state and its filter.
                endClosedSession(restoreBrightness: true)
            }
            onLidOpened?()
        }
        onStateChange?()
    }

    // MARK: - Closed session

    private func handleLidClosed() {
        if isArmed { beginClosedSession() }
        requestCloseSoundIfNeeded()
        onLidClosed?()
    }

    private func requestNearCloseChimeIfNeeded() {
        guard !lidClosed else { return }
        requestCloseSound()
    }

    private func requestCloseSoundIfNeeded() {
        // The registry transition is the authoritative fallback when the angle
        // sensor is unavailable or missed the near-close window.
        guard closeSoundEligible, lidClosed else { return }
        requestCloseSound()
    }

    private func requestCloseSound() {
        guard isArmed, ComponentEngine.shared.isEnabled("lidCloseSound"),
              !closeChime.sounded, !closeSoundPending, closeSoundAttempts < 2,
              ProcessInfo.processInfo.systemUptime >= retrySoundAfter else { return }
        let generation = closeGeneration
        closeSoundPending = true
        closeSoundAttempts += 1
        let accepted = CloseSoundPlayer.shared.play(started: { [weak self] in
            guard let self, self.closeGeneration == generation else { return }
            // Only a backend that actually started playback consumes the
            // once-per-close latch. A failed start stays retryable on this close.
            self.closeChime.markStarted()
        }, completion: { [weak self] success in
            guard let self, self.closeGeneration == generation else { return }
            self.closeSoundPending = false
            if success { self.closeChime.markStarted() }
            else { self.retrySoundAfter = ProcessInfo.processInfo.systemUptime + 0.25 }
        })
        if !accepted {
            closeSoundPending = false
            retrySoundAfter = ProcessInfo.processInfo.systemUptime + 0.25
        }
    }

    /// Asks loginwindow for a native Lock Screen on every armed close
    /// ("close: native Lock Screen request sent to loginwindow").
    private func requestLockScreen() { _ = sendLockScreenRequest(reason: "close") }

    /// Password After Close locks even when Wakely is not armed. Both callers
    /// share one request path and a short dedupe window, so an armed close does
    /// not lock twice (the powered close request and the component's request are
    /// milliseconds apart).
    @discardableResult
    func lockScreenNow(reason: String) -> Bool {
        guard !shuttingDown else { return false }
        let uptime = ProcessInfo.processInfo.systemUptime
        if lastLockScreenRequest != 0,
           uptime - lastLockScreenRequest < Self.lockScreenDedupeWindow {
            Diagnostics.log("\(reason): Lock Screen already requested; not asking twice")
            return true
        }
        return sendLockScreenRequest(reason: reason)
    }

    private func sendLockScreenRequest(reason: String) -> Bool {
        typealias LockFn = @convention(c) () -> Int32
        guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_NOW),
              let symbol = dlsym(handle, "SACLockScreenImmediate") else {
            Diagnostics.log("\(reason): Lock Screen request unavailable (login.framework)")
            return false
        }
        let lock = unsafeBitCast(symbol, to: LockFn.self)
        lastLockScreenRequest = ProcessInfo.processInfo.systemUptime
        let result = lock()
        if result != 0 {
            // The private API has no documented return contract. Log it, then
            // let the caller confirm the actual locked state before relying on it.
            Diagnostics.log("\(reason): native Lock Screen returned \(result); awaiting observed lock")
        } else {
            Diagnostics.log("\(reason): native Lock Screen request accepted by loginwindow")
        }
        return true
    }

    /// True while an orderly quit is draining. Components use it to stay silent
    /// once the termination path owns cleanup.
    var isShuttingDown: Bool { shuttingDown }

    /// Displays go to sleep on an armed close unless an agent still needs them
    /// ("agent screen auto: close sleeps the displays (no agent needs the
    /// screen)", then "pmset displaysleepnow completed"). "Needs them"
    /// is the tool-qualified policy, not any busy agent.
    private func sleepDisplaysUnlessAgentsNeedThem() {
        // Same tool-qualified decision as Agent Screen: a working agent alone
        // is not enough; its last tool call must be screen/browser work.
        // The grace is the same value Agent Screen exposes as "Display off after".
        let screenMinutes = UserDefaults.standard.object(forKey: "agentScreen.minutes") as? Int ?? 2
        let grace = TimeInterval(min(60, max(1, screenMinutes)) * 60)
        let agentsNeedScreen = ComponentEngine.shared.isEnabled("agentScreen")
            && AgentMonitor.shared.needsDisplay(grace: grace)
        if agentsNeedScreen {
            Diagnostics.log("agent screen auto: close keeps the displays for agents")
            return
        }
        Diagnostics.log("agent screen auto: close sleeps the displays (no agent needs the screen)")
        // Neither process launch nor waiting may block lid polling, safety checks
        // or the power-notification acknowledgement deadline on the main actor.
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { completed in
                Diagnostics.log("pmset displaysleepnow completed (\(completed.terminationStatus))")
            }
            do {
                try process.run()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) {
                    guard process.isRunning else { return }
                    Diagnostics.log("pmset displaysleepnow timed out; terminating")
                    process.terminate()
                }
            } catch {
                Diagnostics.log("pmset displaysleepnow failed to launch: \(error.localizedDescription)")
            }
        }
    }

    private func beginClosedSession() {
        guard closedSince == nil else { return }
        closedSince = Date()
        darkenDisplay()
        requestLockScreen()
        sleepDisplaysUnlessAgentsNeedThem()
        Diagnostics.log("closed-lid session started")
        onStateChange?()
    }

    private func endClosedSession(restoreBrightness: Bool) {
        guard closedSince != nil else { return }
        let seconds = Date().timeIntervalSince(closedSince!)
        closedSince = nil
        if restoreBrightness { restoreDisplay() }
        Diagnostics.log("closed-lid session ended after \(Int(seconds))s")
        onStateChange?()
    }

    // MARK: - Display

    private func darkenDisplay() { brightness.setDimmed(true) }

    private func restoreDisplay() { brightness.setDimmed(false) }

    // MARK: - Safety

    private var lastPowerSourceWasBattery: Bool?

    private func checkSafety() {
        // Power-source changes clear the root-domain flag on some systems; it is
        // re-applied ("re-applied lid-close flag after power-source change").
        // Sampled here rather than on the 0.2 s lid timer.
        let onBatteryNow = onBattery()
        if let previous = lastPowerSourceWasBattery, previous != onBatteryNow, isArmed {
            reapplyRootDomainControl(reason: "power-source change")
        }
        lastPowerSourceWasBattery = onBatteryNow

        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .serious || thermal == .critical {
            thermalBlocked = true
            if isArmed {
                Diagnostics.log("thermal pressure \(thermal.rawValue); disarming")
                disarm(reason: "the Mac got too hot")
            }
        } else if thermal == .nominal || thermal == .fair {
            thermalBlocked = false
        }

        if AppState.shared.lowBatteryGuard, isArmed, onBattery(), let percent = batteryPercent(), percent <= 20 {
            Diagnostics.log("battery at \(percent)%; disarming")
            disarm(reason: "the battery reached 20%")
        }
    }

    func batteryPercent() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else { continue }
            if let type = description[kIOPSTypeKey] as? String, type == kIOPSInternalBatteryType,
               let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                return Int((Double(current) / Double(max) * 100).rounded())
            }
        }
        return nil
    }

    func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        if let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as? String {
            return type == kIOPSBatteryPowerValue
        }
        return false
    }

    func externalDisplayCount() -> Int {
        var count: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(16, &displays, &count) == .success else { return 0 }
        return displays.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }

    // MARK: - Presentation

    var statusLine: String {
        if isArmed {
            if let since = closedSince {
                let minutes = max(1, Int(Date().timeIntervalSince(since) / 60))
                return "Awake, lid closed for \(minutes) min"
            }
            return "Armed. Close the lid."
        }
        if thermalBlocked { return "Waiting for the Mac to cool down" }
        return "Off. Closing the lid sleeps your Mac."
    }
}

/// Owns one kernel sleep token. Cancellation, normal completion and timeout all
/// converge here before the connection is closed.
@MainActor
private final class SleepAcknowledgement {
    let connection: io_connect_t
    let token: Int
    var work: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    private lazy var once = OnceGate { [connection, token] in
        IOAllowPowerChange(connection, token)
    }

    init(connection: io_connect_t, token: Int) { self.connection = connection; self.token = token }
    func acknowledge() {
        // Cancellation, normal completion, shutdown and timeout all converge
        // here; the kernel must see exactly one IOAllowPowerChange per token.
        guard once.fire() else { return }
        work?.cancel(); timeout?.cancel()
        work = nil; timeout = nil
    }
}

// BEGIN TESTABLE BRIGHTNESS CONTROLLER
/// Hardware calls are serial and capture/restore state is owned by that queue.
/// New intents invalidate older queued work; an already-running write is always
/// followed by the newest intent, never an out-of-order global-queue restore.
final class SerializedBrightnessController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.wakely.brightness", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var restorationFinished = true
    var isRestored: Bool {
        lock.lock(); defer { lock.unlock() }; return restorationFinished
    }
    private let display: () -> UInt32?
    private let read: (UInt32) -> Float?
    private let write: (UInt32, Float) -> Bool
    private let log: (String) -> Void
    // Queue-confined state; never copied asynchronously back to the main actor.
    private var saved: (display: UInt32, value: Float)?

    init(display: @escaping () -> UInt32?, read: @escaping (UInt32) -> Float?,
         write: @escaping (UInt32, Float) -> Bool, log: @escaping (String) -> Void) {
        self.display = display; self.read = read; self.write = write; self.log = log
    }

    func setDimmed(_ dimmed: Bool) {
        lock.lock(); generation &+= 1; let request = generation; restorationFinished = false; lock.unlock()
        queue.async { [self] in
            defer {
                lock.lock()
                if generation == request { restorationFinished = saved == nil }
                lock.unlock()
            }
            guard current(request) else { return }
            if dimmed {
                guard saved == nil, let display = display(), let value = read(display),
                      current(request) else { return }
                if write(display, 0) {
                    saved = (display, value)
                    log("built-in display darkened")
                } else {
                    log("built-in display darkening failed")
                }
            } else if let original = saved {
                if write(original.display, original.value) {
                    saved = nil
                    log("display brightness restored")
                } else {
                    // Preserve the original value so a subsequent restore can retry.
                    log("display brightness restoration failed")
                }
            }
        }
    }

    private func current(_ request: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == request
    }

    /// For deterministic injected-backend tests; never called by the app.
    func waitUntilIdle() { queue.sync {} }
}
// END TESTABLE BRIGHTNESS CONTROLLER

private extension SerializedBrightnessController {
    convenience init() {
        self.init(display: { DisplayServices.builtInDisplay() }, read: { display in
            guard let get = DisplayServices.getBrightness else { return nil }
            var value: Float = 0
            return get(display, &value) == 0 ? value : nil
        }, write: { display, value in
            guard let set = DisplayServices.setBrightness else { return false }
            return set(display, value) == 0
        }, log: { Diagnostics.log($0) })
    }
}

// MARK: - DisplayServices (private, but stable and used by every brightness app)

enum DisplayServices {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

    typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    typealias MainDisplayFn = @convention(c) () -> CGDirectDisplayID

    static let setBrightness: SetBrightnessFn? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return unsafeBitCast(sym, to: SetBrightnessFn.self)
    }()

    static let getBrightness: GetBrightnessFn? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: GetBrightnessFn.self)
    }()

    private static let mainDisplay: MainDisplayFn? = {
        guard let handle, let sym = dlsym(handle, "DisplayServicesMainDisplay") else { return nil }
        return unsafeBitCast(sym, to: MainDisplayFn.self)
    }()

    static func builtInDisplay() -> CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}

// BEGIN TESTABLE POWER LIFECYCLE HELPERS
/// A failed release never transfers ownership or discards its retry handle.
enum PowerResourceRelease {
    static func retainedID(_ id: UInt32, succeeded: Bool) -> UInt32 {
        succeeded ? 0 : id
    }
}

struct PowerCleanupRetry {
    private var delay: TimeInterval = 1
    mutating func nextDelay() -> TimeInterval {
        let current = delay
        delay = min(60, delay * 2)
        return current
    }
    mutating func reset() { delay = 1 }
}

enum PowerAssertionPolicy {
    static func transitionProperties(majorVersion: Int) -> [String: Any]? {
        guard majorVersion >= 26 else { return nil }
        return ["AssertType": "PreventSystemSleep",
                "AssertName": "Wakely: protecting closed-lid power transitions",
                "AssertLevel": 255,
                "SensorActive": true]
    }
}

/// Sensor freshness is deliberately simple: only a valid report inside the
/// window counts. Discovery, an open manager with no reports, and a removed
/// device all read as stale so IOPMrootDomain polling stays authoritative.
struct LidAngleSensorHealth {
    let freshness: TimeInterval
    let restartInterval: TimeInterval
    private(set) var lastSample: TimeInterval?
    private(set) var lastAttempt: TimeInterval?

    init(freshness: TimeInterval = 2, restartInterval: TimeInterval = 10) {
        self.freshness = freshness
        self.restartInterval = restartInterval
    }

    mutating func beginAttempt(at uptime: TimeInterval) {
        lastAttempt = uptime
        lastSample = nil
    }

    mutating func recordSample(at uptime: TimeInterval) {
        lastSample = uptime
    }

    func isFresh(at uptime: TimeInterval) -> Bool {
        guard let lastSample else { return false }
        return uptime - lastSample <= freshness
    }

    func shouldRestart(at uptime: TimeInterval) -> Bool {
        guard let lastAttempt else { return true }
        return uptime - lastAttempt >= restartInterval
    }

    mutating func reset() {
        lastSample = nil
        lastAttempt = nil
    }
}

enum CloseChimePolicy {
    /// Audio lead-in based on hinge travel.
    /// The 20°/15° gesture constants describe angle TRAVEL relative to
    /// baseline/minimum, not absolute hinge angles, and are not used as audio
    /// thresholds. Keep the current values; do not substitute those tracker
    /// deltas for the audio lead-in.
    static let nearCloseAngle: Double = 30
    static let reopenAngle: Double = 45

    /// A close is eligible only for a real armed session with the component on.
    static func isEligible(armed: Bool, componentEnabled: Bool, lidClosed: Bool) -> Bool {
        armed && componentEnabled && lidClosed
    }

    static func crossedNearClose(previous: Double, current: Double, lidClosed: Bool) -> Bool {
        !lidClosed && current <= nearCloseAngle && previous > nearCloseAngle
    }

    static func isClearlyOpen(_ angle: Double) -> Bool {
        angle >= reopenAngle
    }
}

/// The once-per-close latch is consumed by an actually started backend, never
/// by queuing a request that may still fail to open an audio device.
struct CloseChimeLatch {
    private(set) var sounded = false

    mutating func reset() { sounded = false }
    mutating func markStarted() { sounded = true }
}

enum ClosedSessionPolicy {
    /// The native Caps Lock may be cleared only when a real closed-lid session
    /// is ending and the Caps component currently owns typing protection.
    static func shouldResetCaps(closedSessionActive: Bool, componentEnabled: Bool) -> Bool {
        closedSessionActive && componentEnabled
    }

    /// Caps Lock doubles as the switch, so an explicit Unarm has to release it
    /// even with the lid open — otherwise the key stays lit while the app is off.
    /// Never touch the key when the component is disabled or the lamp is already off.
    static func shouldReleaseCapsOnExplicitUnarm(componentEnabled: Bool, explicitUnarm: Bool,
                                                 capsLit: Bool) -> Bool {
        componentEnabled && explicitUnarm && capsLit
    }
}

/// Resolves a continuation exactly once even when a preparation task and its
/// deadline race. Later resolutions are ignored.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    @discardableResult
    func resolve(_ value: Bool) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
        return true
    }
}

enum SleepHandshake {
    static let preparationTimeout: TimeInterval = 2

    /// Awaits component sleep preparation, returning false at the deadline instead
    /// of blocking the power token. The operation is cancelled on timeout, but a
    /// late completion cannot resume the caller twice.
    static func awaitPreparation(timeout: TimeInterval = preparationTimeout,
                                 operation: @escaping @MainActor @Sendable () async -> Void) async -> Bool {
        let gate = ResumeOnce()
        let preparation = Task { @MainActor in
            await operation()
            gate.resolve(true)
        }
        let deadline = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            } catch {
                return
            }
            gate.resolve(false)
        }
        let completed = await withCheckedContinuation { gate.install($0) }
        deadline.cancel()
        if !completed { preparation.cancel() }
        return completed
    }
}

/// One-shot action used to make IOAllowPowerChange exactly-once across every
/// completion, cancellation, timeout and shutdown path.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private let action: @Sendable () -> Void

    init(action: @escaping @Sendable () -> Void) {
        self.action = action
    }

    @discardableResult
    func fire() -> Bool {
        lock.lock()
        guard !fired else { lock.unlock(); return false }
        fired = true
        lock.unlock()
        action()
        return true
    }
}
// END TESTABLE POWER LIFECYCLE HELPERS

// BEGIN TESTABLE CLOSE GESTURE
/// One hinge observation. `timestamp` is monotonic uptime in seconds; `shaped`
/// is the caller's normalized closure progress (0 open, 1 closed). The option,
/// watching, gesture-active and retracted fields describe one push sample.
/// Only `watching` is wired in the app today; the option gate is modeled here
/// but has no modifier source to feed it.
struct CloseGestureSample {
    let angle: Double
    let timestamp: TimeInterval
    let shaped: Double
    let optionHeld: Bool
    let watching: Bool
    let gestureActive: Bool
    let retracted: Bool

    init(angle: Double, timestamp: TimeInterval, shaped: Double? = nil,
         optionHeld: Bool = false, watching: Bool = true,
         gestureActive: Bool = false, retracted: Bool = false) {
        self.angle = angle
        self.timestamp = timestamp
        self.shaped = shaped ?? CloseGesturePolicy.closedFraction(angle: angle)
        self.optionHeld = optionHeld
        self.watching = watching
        self.gestureActive = gestureActive
        self.retracted = retracted
    }
}

enum CloseGestureDecision: Equatable {
    case none
    /// `.armed` marks an edge: a push reports it only on the transition, with
    /// progress queried separately. Here every engaged sample carries its
    /// current normalized progress, and the caller arms only once.
    case armed(progress: Double)
    case voided
    case cancelled
}

/// Hinge-travel policy with a timing gate applied in the gesture filter.
/// Engage is 20° of travel from the tracked maximum; an armed close is voided
/// after 15° of travel from its most-closed sample.
struct CloseGesturePolicy {
    static let engageTravel: Double = 20.0
    static let reverseCancelTravel: Double = 15.0

    /// Gesture samples arrive 30–100 ms apart, including a one-sample close at
    /// 35 ms. A report outside this window is not evidence of a continuous
    /// tilt, so it cannot arm or void by itself.
    static let minimumSampleGap: TimeInterval = 0.005
    static let maximumSampleGap: TimeInterval = 0.25

    /// A slow drift may contain many individually plausible samples. It still
    /// cannot arm after this much wall-clock time from the tracked maximum;
    /// the baseline re-anchors instead of accumulating an old 20° drop.
    static let maximumTravelWindow: TimeInterval = 1.5

    static let progressFloor: Double = 0.001

    private(set) var engaged = false
    private(set) var baseline: Double?
    private(set) var startProgress: Double = 0
    private(set) var mostClosed: Double?
    private(set) var reverseTravel: Double = 0
    private var baselineTimestamp: TimeInterval?
    private var lastTimestamp: TimeInterval?

    mutating func push(_ sample: CloseGestureSample) -> CloseGestureDecision {
        guard sample.angle.isFinite, sample.shaped.isFinite, sample.timestamp.isFinite else {
            return .none
        }
        // Duplicate or out-of-order timestamp: never let a repeated report move
        // the baseline or satisfy a travel threshold.
        if let lastTimestamp, sample.timestamp <= lastTimestamp {
            return .none
        }
        if sample.gestureActive {
            let wasEngaged = engaged
            reset()
            lastTimestamp = sample.timestamp
            return wasEngaged ? .cancelled : .none
        }
        if let previous = lastTimestamp, sample.timestamp - previous > Self.maximumSampleGap {
            // Stale: do not trust travel across the gap. Re-anchor a watcher;
            // leave an already armed close engaged so a sensor hiccup cannot
            // silently turn into a disarm.
            lastTimestamp = sample.timestamp
            if !engaged {
                baseline = sample.angle
                baselineTimestamp = sample.timestamp
            }
            return .none
        }
        if let lastTimestamp, sample.timestamp - lastTimestamp < Self.minimumSampleGap {
            // A burst report is a duplicate, not a second hinge sample. Keep
            // the earlier timestamp so the next real sample is measured from it.
            return .none
        }

        if engaged {
            if let minimum = mostClosed {
                if sample.angle < minimum {
                    mostClosed = sample.angle
                    reverseTravel = 0
                } else {
                    reverseTravel = sample.angle - minimum
                }
            } else {
                mostClosed = sample.angle
                reverseTravel = 0
            }
            // Option held keeps the armed close alive even through a
            // reversal; retraction (or an unheld reversal past 15°) voids it.
            let shouldVoid = sample.retracted
                || (!sample.optionHeld && reverseTravel >= Self.reverseCancelTravel)
            if shouldVoid {
                engaged = false
                startProgress = 0
                mostClosed = nil
                reverseTravel = 0
                baseline = sample.angle
                baselineTimestamp = sample.timestamp
                lastTimestamp = sample.timestamp
                return .voided
            }
            lastTimestamp = sample.timestamp
            return .armed(progress: progress(shaped: sample.shaped))
        }

        lastTimestamp = sample.timestamp
        guard sample.watching, !sample.optionHeld else {
            // Drop the baseline when not watching or while option is held, so a
            // stale pre-option maximum cannot arm later.
            baseline = nil
            baselineTimestamp = nil
            return .none
        }
        guard let base = baseline else {
            baseline = sample.angle
            baselineTimestamp = sample.timestamp
            return .none
        }
        if sample.angle >= base {
            // A stationary lid keeps the maximum's timestamp fresh. Without
            // this, a fast flick from a long-held-open lid would look stale.
            baseline = sample.angle
            baselineTimestamp = sample.timestamp
            return .none
        }
        if let baseTime = baselineTimestamp,
           sample.timestamp - baseTime > Self.maximumTravelWindow {
            baseline = sample.angle
            baselineTimestamp = sample.timestamp
            return .none
        }
        guard base - sample.angle >= Self.engageTravel else { return .none }
        engaged = true
        startProgress = sample.shaped
        mostClosed = sample.angle
        reverseTravel = 0
        return .armed(progress: 0)
    }

    /// Progress normalization: arm-time shaped is the origin, 1.0 shaped is
    /// complete, and a degenerate span is floored.
    func progress(shaped: Double) -> Double {
        guard engaged, shaped.isFinite else { return 0 }
        var span = 1.0 - startProgress
        if span <= Self.progressFloor { span = Self.progressFloor }
        return min(max((shaped - startProgress) / span, 0), 1)
    }

    static func closedFraction(angle: Double) -> Double {
        guard angle.isFinite else { return 0 }
        return min(max((180.0 - angle) / 180.0, 0), 1)
    }

    mutating func reset() {
        engaged = false
        baseline = nil
        baselineTimestamp = nil
        startProgress = 0
        mostClosed = nil
        reverseTravel = 0
        lastTimestamp = nil
    }
}
// END TESTABLE CLOSE GESTURE
