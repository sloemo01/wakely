// ComponentBehaviors — what each component actually does.
//
// Everything here runs with no root. The components that genuinely need the
// privileged helper (SMC fans, pmset settings, NVRAM boot flags) are marked as
// needing it in the catalog. `ProtectedComponents` below is the only path that
// touches that helper: it gates enablement on a live capability probe, applies
// session-scoped settings on close, and restores them on open/end/disable/quit.
// Sleep Until Reset (sleepUntilReset) is wired to SleepUntilResetController:
// the helper owns one wake per known reset and the controller reconciles that
// set. Sleep Means Sleep (sleepMeansSleep) leases the supported battery wake
// sources through the same helper and restores them when disabled.

import Foundation
import AppKit
import IOKit
import IOKit.pwr_mgt
import CoreAudio
import AudioToolbox
import DiskArbitration
import Network
import CoreWLAN

/// Brücke from the app's persisted Home Server rearm budget to the component hold.
/// The launch path owns the budget (HomeServerRearmBudget + UserDefaults); the
/// condition hold must not arm around it on the very next tick, or a crash loop
/// would bypass the limit the launch path just enforced. The default allows
/// arming so a test or a build without the bridge behaves as before.
@MainActor
enum HomeServerAutomation {
    static var automaticArmAllowed: @MainActor () -> Bool = { true }
}

@MainActor
final class ComponentEngine {
    static let shared = ComponentEngine()

    private var timer: Timer?
    private var idleSince: Date?
    private var quietSince: Date?
    private var workingSince: Date?
    private var graceStarted: [String: Date] = [:]
    private var keepAwakeCompleted = false
    private var observedSessionGeneration = -1
    private var sleepDeadline: Date?
    private var pendingSleep: Task<Void, Never>?
    private var networkBusy = false
    private var batteryPolicy = ClosedBatteryBudget()
    private var wifiGrace = ConditionGrace()
    private var remoteGrace = ConditionGrace()
    private var agentSnapshot = BoundedWorkSnapshot()
    private var jobsSnapshot = BoundedWorkSnapshot()
    /// Last AgentMonitor.finishedThreads snapshot already accounted for. The
    /// monitor replaces that array on every scan, so an identical value means
    /// "already handled", and a new busy->idle turn always shows up as a change.
    private var lastFinishedSnapshot: [AgentThread] = []
    private var notifiedWaitingAgents: Set<String> = []
    private var agentFinishHookInstalled = false
    private var keepAwakeAssertion = IOPMAssertionID(0)
    /// System sleep and display sleep are independent IOPM assertions.
    private var keepAwakeDisplayAssertion = IOPMAssertionID(0)
    private var alwaysOnDisplayAssertion = IOPMAssertionID(0)
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sleepPreparedForThisSleep = false
    private var sleepPreparationTask: Task<Void, Never>?
    private var preserveFadeOnSessionEnd = false
    private var keepAwakeIndefinite = false
    /// True when an explicit menu request set the active duration. It must not
    /// be overridden by the saved default on the next tick.
    private var keepAwakeRequested = false
    /// Original requested duration for the live presentation, not inferred
    /// from the remaining deadline. nil with requested=true means indefinite.
    private var keepAwakeRequestedMinutes: Int?
    private var keepAwakeSource: KeepAwakeSource = .none
    private var idleMayRearm = false
    private var idleHadActivity = false
    private var agentScreenIdleSince: Date?
    private var displayAssertion = IOPMAssertionID(0)
    private var displayAsserted = false
    private var keyboardTap: CFMachPort?
    private var keyboardLockUntil: Date?
    private var bagCheckTimer: Timer?
    private var bagCheckNotified = false
    private var capsArmedLast = false
    private var savedMute: Audio.MuteSnapshot?
    private var mutedByUs = false
    private var bluetoothWasOn = true
    private var bluetoothChangedByUs = false
    private var bluetoothOffAt: Date?
    private var networkBaseline: UInt64 = 0
    private var lastNetworkActivity = Date()
    private var keepAwakeDeadline: Date?
    private var lastLidClosed = false
    private var quietCloseTask: Task<Void, Never>?
    /// Protected-component enables wait for a live helper capability probe; these
    /// ids were requested and are still being decided.
    private var pendingProtectedEnablement = PendingComponentEnablement()

    private init() {}

    // MARK: - Enablement

    var enabledIDs: Set<String> {
        get {
            if let stored = UserDefaults.standard.stringArray(forKey: "enabledComponentIDs") {
                return Set(stored)
            }
            let defaults = ["agentScreen", "agentStatus", "lidCloseSound", "capsLock", "alwaysOnPluggedIn"]
            UserDefaults.standard.set(defaults, forKey: "enabledComponentIDs")
            return Set(defaults)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: "enabledComponentIDs") }
    }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    /// The last refusal for a protected component, for the settings UI. A missing
    /// entry means no refusal was recorded in this run.
    var lastEnablementReason: [String: String] { ProtectedComponents.shared.lastEnablementReason }

    func enablementReason(for id: String) -> String? { lastEnablementReason[id] }

    func setEnabled(_ id: String, _ on: Bool) {
        if ComponentPermissions.shared.interceptEnable(id, on: on) { return }
        if !on { pendingProtectedEnablement.cancel(id) }
        guard let definition = ComponentCatalog.definition(for: id), isEnabled(id) != on else { return }
        // A protected component is enabled only after the helper answers with a
        // capability for the operation it needs. The toggle stays off while the
        // probe runs, and a refusal is recorded instead of faked.
        if on, ProtectedComponentPolicy.isProtected(id), id != "homeServer" {
            guard let token = pendingProtectedEnablement.begin(id) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let allowed = await ProtectedComponents.shared.gateEnablement(id)
                // A user who turned the component back off while the probe ran wins.
                guard self.pendingProtectedEnablement.consume(id, token: token) else { return }
                guard allowed else { return }
                self.commitProtectedEnablement(id)
            }
            return
        }
        // Sleep Until Reset needs the helper for its owned wakes but has no
        // protected power setting to gate: the controller verifies reachability
        // and stays inert without it. Every other helper-needing component still
        // refuses to enable without its protected capability gate.
        let wakeOwner = id == SleepUntilResetController.componentID
        guard !on || !definition.needsHelper || wakeOwner else {
            ProtectedComponents.shared.recordRefusal(id, ComponentCapabilityPolicy.capability(for: id).reason)
            return
        }
        applyComponentState(id, on)
    }

    /// Commit an enable that already passed the permission window. This path
    /// deliberately does not re-enter `interceptEnable` (which would bounce the
    /// request back into the same window forever) and it awaits the protected
    /// capability gate before reporting success.
    func enableAfterPermissionGrant(_ id: String) async {
        guard let definition = ComponentCatalog.definition(for: id), !isEnabled(id) else { return }
        if ProtectedComponentPolicy.isProtected(id), id != "homeServer" {
            guard let token = pendingProtectedEnablement.begin(id) else { return }
            let allowed = await ProtectedComponents.shared.gateEnablement(id)
            guard pendingProtectedEnablement.consume(id, token: token), allowed else { return }
            commitProtectedEnablement(id)
            return
        }
        let wakeOwner = id == SleepUntilResetController.componentID
        guard !definition.needsHelper || wakeOwner else { return }
        if wakeOwner {
            let capability = await HelperClient.shared.capability(.scheduleWake)
            guard capability.supported else {
                ProtectedComponents.shared.recordRefusal(id, capability.reason)
                return
            }
        }
        applyComponentState(id, true)
    }

    /// Called only by ProtectedComponents after the capability gate passed.
    func commitProtectedEnablement(_ id: String) {
        guard let definition = ComponentCatalog.definition(for: id),
              ProtectedComponentPolicy.isProtected(id), !isEnabled(id) else { return }
        applyComponentState(id, true)
        if ProtectedComponentPolicy.scope(of: id) == .persistent {
            ProtectedComponents.shared.applyPersistent()
        }
    }

    private func applyComponentState(_ id: String, _ on: Bool) {
        var ids = enabledIDs
        if on { ids.insert(id) } else { ids.remove(id) }
        enabledIDs = ids
        if !on {
            // Restore before teardown: the helper still remembers the saved
            // values, and a disable must put them back while it is reachable.
            if ProtectedComponentPolicy.isProtected(id) {
                ProtectedComponents.shared.restore(component: id, reason: "component disabled")
            }
            teardown(id)
        }
        if id == "keepAwake" {
            keepAwakeCompleted = false
            keepAwakeDeadline = nil
            keepAwakeIndefinite = false
            keepAwakeRequested = false
        }
        if id == SleepUntilResetController.componentID, on {
            SleepUntilResetController.shared.start()
        }
        if id == "capsLock", on {
            // Watch the key for the component's lifetime; the typing filter is an
            // arm-time protection layered on top of that.
            _ = CapsLockLight.startWatching()
            _ = CapsLockLight.installTypingFilter(active: PowerEngine.shared.isArmed)
        }
        if id == "agentNotifications" {
            // Adopt whatever the monitor already saw so turning the component on
            // never replays a finish or a wait that happened while it was off.
            lastFinishedSnapshot = AgentMonitor.shared.finishedThreads
            notifiedWaitingAgents = Set(AgentMonitor.shared.threads.filter(\.waiting).map(\.id))
        }
        if id == "finishWorkThenSleep" { agentSnapshot.reset() }
        if id == "finishJobsThenSleep" { jobsSnapshot.reset() }
        if id == "lidCloseSound" {
            CloseSoundPlayer.shared.isEnabled = on
            if on { CloseSoundPlayer.shared.prepare() }
        }
        SettingsModel.shared.refresh()
        if on, id == "cleaningLock" {
            let seconds = UserDefaults.standard.object(forKey: "cleaningLock.seconds") as? Int ?? 60
            beginCleaningLock(seconds: min(300, max(15, seconds)))
            // An armed Mac refuses the lock and turns the component back off
            // (already logged); don't follow that with a false "on".
            guard isEnabled(id) else { return }
        }
        if on { tick() }
        // The login item and Home Server's launch/restore policy are the only
        // built-in observers of enablement. Publish for exactly the three
        // restart-sensitive ids so a custom component that happens to share another
        // built-in id is not reset by an unrelated toggle.
        if HomeServerPolicy.loginItemComponentIDs.contains(id) {
            NotificationCenter.default.post(name: .componentEnablementChanged, object: id)
        }
        // Wakely says nothing when you flip a component yourself: you are
        // looking at it. Notifications belong to components acting on their own.
        Diagnostics.log("component \(id) \(on ? "on" : "off")")
    }

    // MARK: - Lifecycle

    func start() {
        timer?.invalidate()
        // Read the live registration state first: a daemon installed through the
        // administrator fallback lives in /Library/LaunchDaemons, which the
        // SMAppService status alone does not report.
        HelperClient.shared.refreshInstallState()
        // A protected component survives a relaunch only when the helper is still
        // installed: the enable decision was already gated, and the session path
        // checks reachability again before every apply. Everything else that
        // needs the helper stays off, exactly as before.
        enabledIDs = enabledIDs.filter { id in
            // Cleaning Lock is a timed action, never a persisted launch action.
            guard id != "cleaningLock" else { return false }
            guard let definition = ComponentCatalog.definition(for: id) else { return false }
            if id == "homeServer" { return true }
            guard ProtectedComponentPolicy.isProtected(id)
                    || id == SleepUntilResetController.componentID else { return true }
            if case .installed = HelperClient.shared.installState { return true }
            return false
        }
        CloseSoundPlayer.shared.isEnabled = isEnabled("lidCloseSound")
        CloseSoundPlayer.shared.prepare()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if isEnabled("capsLock") {
            _ = CapsLockLight.startWatching()
            _ = CapsLockLight.installTypingFilter(active: PowerEngine.shared.isArmed)
        }
        installAgentFinishHook()
        if isEnabled("agentNotifications") {
            // Never replay transitions that completed before this run started.
            lastFinishedSnapshot = AgentMonitor.shared.finishedThreads
            notifiedWaitingAgents = Set(AgentMonitor.shared.threads.filter(\.waiting).map(\.id))
        }
        if workspaceObservers.isEmpty {
            for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
                workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                    Task { @MainActor in
                        if note.name == NSWorkspace.willSleepNotification {
                            // Fallback for a Mac whose system-power handshake is
                            // unavailable; the handshake path awaits the same
                            // preparation task, so this cannot double-apply.
                            await self.prepareForSystemSleep()
                        } else {
                            self.sleepPreparedForThisSleep = false
                            self.restoreBluetooth()
                            Audio.cancelFade(restore: true)
                            // A wake is a Password After Close restore trigger
                            // only when the screen is provably unlocked.
                            PasswordAfterCloseController.shared.lidDidWake()
                            // Sleep Until Reset reacts after the system has
                            // already woken; it never creates a wake itself.
                            SleepUntilResetController.shared.didWake()
                            // Eject on Sleep: bring back the drives the user
                            // asked to keep only while closed.
                            Volumes.remountEjectedIfWanted()
                        }
                    }
                })
            }
        }
        tick()
        // A component that survives a relaunch needs its controller resumed: no
        // toggle notification fires for it.
        if isEnabled(SleepUntilResetController.componentID) {
            SleepUntilResetController.shared.start()
        }
        // Crash safety: adopt or clean up helper leases saved by a previous run.
        // Runs after the enabled list is known and never blocks startup.
        Task { @MainActor in await ProtectedComponents.shared.bootstrap() }
        Diagnostics.log("component engine started with \(enabledIDs.count) components on")
    }

    func stop() {
        pendingProtectedEnablement.cancelAll()
        // Quit is a Password After Close restore trigger. Ask before the component
        // teardown, so the existing termination drain can wait for the helper
        // and the phase is persisted if the reply never arrives.
        PasswordAfterCloseController.shared.didQuit()
        SleepUntilResetController.shared.didQuit()
        timer?.invalidate(); timer = nil
        pendingSleep?.cancel(); pendingSleep = nil
        bagCheckTimer?.invalidate(); bagCheckTimer = nil
        // Session-scoped protected settings go back now; persistent ones
        // (homeServer, stayOffWhenOpened) deliberately survive a quit.
        ProtectedComponents.shared.beginShutdown()
        ProtectedComponents.shared.restoreSessionScoped(reason: "app quit")
        for id in enabledIDs { teardown(id) }
        // Quitting must not leave Bluetooth off if the component itself was
        // disabled mid-preparation or its teardown did not run.
        restoreBluetooth()
        sleepPreparedForThisSleep = false
        sleepPreparationTask?.cancel(); sleepPreparationTask = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        Audio.cancelFade(restore: true)
    }

    func awaitShutdownRestoration(timeout: TimeInterval) async -> Bool {
        await ProtectedComponents.shared.awaitShutdownRestoration(timeout: timeout)
    }

    private func teardown(_ id: String) {
        PowerEngine.shared.releaseAutomaticArm(owner: id, reason: "component disabled")
        graceStarted.removeValue(forKey: id)
        switch id {
        case "keepAwake": endKeepAwake(); keepAwakeCompleted = false
        case "alwaysOnPluggedIn":
            if alwaysOnDisplayAssertion != 0 { IOPMAssertionRelease(alwaysOnDisplayAssertion) }
            alwaysOnDisplayAssertion = 0
        case "batteryBudget": batteryPolicy.reset()
        case "sleepWhenIdle":
            idleSince = nil
            idleMayRearm = false
            idleHadActivity = false
        case "sleepTimer": sleepDeadline = nil; pendingSleep?.cancel(); pendingSleep = nil; Audio.cancelFade(restore: true)
        case "bagCheck": bagCheckTimer?.invalidate(); bagCheckTimer = nil; bagCheckNotified = false
        case "agentScreen": releaseDisplayAssertion()
        case "quietClose":
            quietCloseTask?.cancel(); quietCloseTask = nil
            restoreQuietClose()
        case "bluetoothOffWhileClosed": restoreBluetooth()
        case "cleaningLock": endCleaningLock()
        case "passwordAfterClose": PasswordAfterCloseController.shared.didDisable()
        case "sleepUntilReset": SleepUntilResetController.shared.didDisable()
        case "capsLock": CapsLockLight.stopWatching()
        case "armOnWiFi": wifiGrace.reset()
        case "awakeWhileConnected": remoteGrace.reset()
        case "finishWorkThenSleep": agentSnapshot.reset()
        case "finishJobsThenSleep": jobsSnapshot.reset()
        default: break
        }
    }

    // MARK: - Tick

    private func tick() {
        let engine = PowerEngine.shared
        let env = Environment(engine: engine)
        let agents = AgentMonitor.shared

        if observedSessionGeneration != engine.sessionGeneration {
            observedSessionGeneration = engine.sessionGeneration
            idleSince = nil
            batteryPolicy.reset()
            sleepDeadline = nil
            if engine.isArmed { sessionDidStart() }
            UserDefaults.standard.removeObject(forKey: "sleepTimer.deadline")
        }
        networkBusy = Network.busy()
        // Ticks only run while awake. A sleep request that the system never
        // completed must not leave the radio off until the next wake.
        if bluetoothChangedByUs, let requested = bluetoothOffAt,
           Date().timeIntervalSince(requested) > 10 {
            Diagnostics.log("bluetooth: no system sleep followed the request; restoring")
            restoreBluetooth()
        }
        if engine.isArmed { restoreBluetooth() }
        updateKeepAwake(engine: engine)

        // Agent-facing components
        if isEnabled("agentScreen") { agentScreen(agents: agents, engine: engine) }
        if isEnabled("agentNotifications") { agentNotifications(agents: agents) }

        // Sleep Until Reset owns its own replan timer and wake path; the tick
        // deliberately does nothing for it, so an unreachable helper or absent
        // reset data is never mistaken for a scheduled wake.

        reconcileAutomaticHolds(engine: engine, env: env, agents: agents)
        updateAlwaysOnDisplay(env: env)
        if isEnabled("batteryBudget") { batteryBudget(engine: engine) }
        if isEnabled("sleepWhenIdle") { sleepWhenIdle(engine: engine, agents: agents) }
        if isEnabled("sleepTimer") { sleepTimer(engine: engine) }

        // Lid transitions are delivered immediately by PowerEngine, not a second poll.
        if isEnabled("bagCheck") { bagCheck(engine: engine, env: env) }
        if isEnabled("cleaningLock") { cleaningLockTick() }

        if isEnabled("lowPowerWhileClosed") || isEnabled("fanBoost") || isEnabled("passwordAfterClose") {
            // Idempotent recovery: if the helper was unreachable or a component was
            // enabled mid-session, this applies only what is still missing.
            if engine.isArmed, engine.lidClosed { ProtectedComponents.shared.sessionDidStart() }
        }
        if isEnabled("homeServer") || isEnabled("stayOffWhenOpened") || isEnabled("sleepMeansSleep") {
            // Persistent settings are not tied to a session; retry them while
            // their component is enabled (the cooldown prevents tick spam).
            ProtectedComponents.shared.applyPersistent()
        }

        // The close-time hand-back is driven by the lock observer; this tick
        // retries a late turn-off only while the close still stands.
        PasswordAfterCloseController.shared.tick()
    }

    /// Called immediately by the power engine. Does not change Caps Lock or arm.
    func sessionDidEnd() {
        // Password After Close stays off until the next unlock or an explicit
        // quit/disable; a session ending is not one of its restore triggers.
        ProtectedComponents.shared.restoreSessionScoped(reason: "session ended",
                                                     excluding: ["passwordAfterClose"])
        endKeepAwake()
        restoreQuietClose()
        if !preserveFadeOnSessionEnd { Audio.cancelFade(restore: true) }
        batteryPolicy.reset()
    }

    var isKeepingAwake: Bool { keepAwakeAssertion != 0 }

    var keepAwakeSnapshot: KeepAwakeSnapshot {
        KeepAwakeSnapshot(
            active: isKeepingAwake,
            durationMinutes: keepAwakeRequestedMinutes,
            durationKnown: keepAwakeRequested || keepAwakeSource == .savedDefault,
            source: keepAwakeSource,
            deadline: keepAwakeDeadline,
            lastMenuMinutes: UserDefaults.standard.object(forKey: "keepAwake.lastMenuMinutes") as? Int)
    }

    func startKeepAwake(minutes: Int? = nil, source: KeepAwakeSource = .menu) {
        keepAwakeCompleted = false
        keepAwakeRequested = true
        keepAwakeRequestedMinutes = minutes
        keepAwakeSource = source
        keepAwakeIndefinite = minutes == nil
        keepAwakeDeadline = minutes.map { Date().addingTimeInterval(Double(max(1, $0)) * 60) }
        if source == .menu {
            UserDefaults.standard.set(minutes ?? 0, forKey: "keepAwake.lastMenuMinutes")
        }
        updateKeepAwake(engine: PowerEngine.shared, explicit: true)
    }
    func stopKeepAwake() { endKeepAwake() }

    func sessionDidStart() {
        CleaningLockController.shared.end()
        // A new session is a new sleep cycle; the next sleep prepares again.
        sleepPreparedForThisSleep = false
        restoreBluetooth()
        Audio.cancelFade(restore: true)
        ProtectedComponents.shared.sessionDidStart()
    }

    private func endKeepAwake() {
        if keepAwakeAssertion != 0 { IOPMAssertionRelease(keepAwakeAssertion) }
        if keepAwakeDisplayAssertion != 0 { IOPMAssertionRelease(keepAwakeDisplayAssertion) }
        keepAwakeAssertion = 0
        keepAwakeDisplayAssertion = 0
        keepAwakeDeadline = nil
        keepAwakeIndefinite = false
        keepAwakeRequested = false
        keepAwakeRequestedMinutes = nil
        keepAwakeSource = .none
        keepAwakeCompleted = true
    }

    /// Always On While Plugged In can hold the display awake independently of
    /// its system-sleep hold. Default off preserves the existing behaviour:
    /// the Mac stays available, but the screen may sleep normally.
    private func updateAlwaysOnDisplay(env: Environment) {
        let wanted = isEnabled("alwaysOnPluggedIn") && env.onCharger
            && (UserDefaults.standard.object(forKey: "alwaysOnPluggedIn.keepScreenOn") as? Bool ?? false)
        if wanted {
            if alwaysOnDisplayAssertion == 0 {
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Wakely: Always On display" as CFString,
                    &alwaysOnDisplayAssertion)
                if result != kIOReturnSuccess {
                    alwaysOnDisplayAssertion = 0
                    Diagnostics.log("Always On display assertion failed: \(result)")
                }
            }
        } else if alwaysOnDisplayAssertion != 0 {
            IOPMAssertionRelease(alwaysOnDisplayAssertion)
            alwaysOnDisplayAssertion = 0
        }
    }

    private func updateKeepAwake(engine: PowerEngine, explicit: Bool = false) {
        guard (isEnabled("keepAwake") || explicit), !keepAwakeCompleted, !engine.lidClosed else {
            if keepAwakeAssertion != 0 { endKeepAwake() }
            return
        }
        if let until = keepAwakeDeadline, Date() >= until { endKeepAwake(); return }
        if keepAwakeAssertion == 0 {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "Wakely: lid-open Keep Awake" as CFString, &keepAwakeAssertion)
            guard result == kIOReturnSuccess else { keepAwakeAssertion = 0; Diagnostics.log("Keep Awake assertion failed: \(result)"); return }
            if !keepAwakeRequested {
                let minutes = UserDefaults.standard.object(forKey: "keepAwake.minutes") as? Int ?? 120
                keepAwakeSource = .savedDefault
                keepAwakeRequestedMinutes = minutes <= 0 ? nil : minutes
                if minutes <= 0 {
                    keepAwakeIndefinite = true
                    keepAwakeDeadline = nil
                } else {
                    keepAwakeDeadline = Date().addingTimeInterval(Double(max(1, minutes)) * 60)
                }
            }
        }
        // Keep the display awake only while the user asked for it. Checked on
        // every tick so the sentence toggle takes effect without restarting the
        // hold; releasing it lets the screen sleep while the Mac stays awake.
        let wantsScreen = UserDefaults.standard.object(forKey: "keepAwake.keepScreenOn") as? Bool ?? true
        if wantsScreen {
            if keepAwakeDisplayAssertion == 0 {
                let result = IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    "Wakely: lid-open Keep Awake display" as CFString,
                    &keepAwakeDisplayAssertion)
                if result != kIOReturnSuccess {
                    keepAwakeDisplayAssertion = 0
                    Diagnostics.log("Keep Awake display assertion failed: \(result)")
                }
            }
        } else if keepAwakeDisplayAssertion != 0 {
            IOPMAssertionRelease(keepAwakeDisplayAssertion)
            keepAwakeDisplayAssertion = 0
        }
    }

    private func restoreQuietClose() {
        quietCloseTask?.cancel(); quietCloseTask = nil
        guard mutedByUs, let savedMute else { return }
        if Audio.setMuted(savedMute.muted, device: savedMute.device) {
            mutedByUs = false
            self.savedMute = nil
        } else {
            Diagnostics.log("quiet close: previous output mute restore failed; retained for retry")
        }
    }

    private func restoreBluetooth() {
        guard bluetoothChangedByUs else { return }
        Bluetooth.setPower(bluetoothWasOn)
        if Bluetooth.powerState() == bluetoothWasOn {
            bluetoothChangedByUs = false
            bluetoothOffAt = nil
            Diagnostics.log("bluetooth previous state restored")
        } else {
            Diagnostics.log("bluetooth restore requested but not confirmed; retaining ownership for retry")
        }
    }

    /// Called from the actual system-sleep handshake, not merely a lid movement.
    /// The caller awaits completion (and owns the system's acknowledgement).
    /// One preparation per sleep: a second caller awaits the in-flight work
    /// instead of applying it twice, and a late caller after completion waits
    /// for the next wake (which resets the flag).
    func prepareForSystemSleep() async {
        if sleepPreparedForThisSleep { return }
        if let task = sleepPreparationTask { await task.value; return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareOnceForSystemSleep()
        }
        sleepPreparationTask = task
        await task.value
        sleepPreparationTask = nil
    }

    private func prepareOnceForSystemSleep() async {
        let engine = PowerEngine.shared
        let context = SleepSafetyContext(lidClosed: engine.lidClosed, armed: engine.isArmed,
                                         externalDisplay: DisplayTopology.hasExternalDisplay)
        // A lid-open sleep, an armed session, or an external display is not a
        // closed-lid sleep: leave Bluetooth and mounted drives alone.
        guard context.permitsPeripheralChanges else {
            Diagnostics.log("sleep preparation skipped: lidClosed=\(context.lidClosed) armed=\(context.armed) externalDisplay=\(context.externalDisplay)")
            return
        }
        sleepPreparedForThisSleep = true
        if isEnabled("bluetoothOffWhileClosed") {
            if Bluetooth.isControllable, let priorPower = Bluetooth.powerState() {
                bluetoothWasOn = priorPower
                if bluetoothWasOn {
                    // The IOKit/IOBluetooth call reports no verifiable completion,
                    // so this records a request to restore, not proof it went off.
                    Bluetooth.setPower(false)
                    bluetoothChangedByUs = true
                    bluetoothOffAt = Date()
                    Diagnostics.log("bluetooth off requested for system sleep; restore scheduled for wake")
                }
            } else {
                Diagnostics.log("bluetooth off skipped: IOBluetooth power control is unavailable")
            }
        }
        if isEnabled("ejectOnSleep") {
            let selected = Set(UserDefaults.standard.stringArray(forKey: "armWhenDriveConnects.volumeIDs") ?? [])
            let failures = await Volumes.ejectForSleep(excluding: selected)
            if !failures.isEmpty {
                Notifier.post(title: "Eject on Sleep", body: "Could not eject: " + failures.joined(separator: ", "))
            }
        }
    }

    private var suppressNotifications = false


    @MainActor
    private struct Environment {
        let lidClosed: Bool
        let onCharger: Bool
        let battery: Int?
        let agentsWorking: Int
        init(engine: PowerEngine) {
            lidClosed = engine.lidClosed
            onCharger = !engine.onBattery()
            battery = engine.batteryPercent()
            agentsWorking = AgentMonitor.shared.workingCount
        }
    }

    // MARK: - Agents

    /// One user-facing timing window from `UserDefaults`. The settings pane owns
    /// the stored value; a missing key falls back to the documented default and
    /// anything out of range is clamped, so a duration is never zero or negative.
    private func intSetting(_ key: String, default def: Int, in range: ClosedRange<Int>) -> Int {
        let stored = UserDefaults.standard.object(forKey: key) as? Int ?? def
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private func agentScreen(agents: AgentMonitor, engine: PowerEngine) {
        // OSS policy: hold the display only for an explicitly working thread
        // whose last tool call is screen/browser work, active or completed
        // within the grace below. General "busy", waiting, unknown work, and
        // terminal-only work do not keep the panel awake.
        //
        // The policy supplies the grace after the last screen/browser call; the
        // user owns that window through `agentScreen.minutes` (default two
        // minutes). Only a short release delay is needed here to avoid flapping
        // between ticks: keeping the full grace here as well would double the
        // user-visible "two minutes after they stop" delay.
        let releaseDelay: TimeInterval = 10
        let displayGrace = TimeInterval(intSetting("agentScreen.minutes", default: 2, in: 1...60) * 60)
        let holdDisplay = engine.isArmed && agents.needsDisplay(grace: displayGrace)
        if holdDisplay && !displayAsserted {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleDisplaySleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Wakely: keeping the screen usable for agents" as CFString, &id)
            if result == kIOReturnSuccess {
                displayAssertion = id
                displayAsserted = true
                Diagnostics.log("agent screen: display assertion held")
                wakeDisplayForAgents()
            }
        }
        if holdDisplay { agentScreenIdleSince = nil }
        else if displayAsserted {
            agentScreenIdleSince = agentScreenIdleSince ?? Date()
            if Date().timeIntervalSince(agentScreenIdleSince!) >= releaseDelay { releaseDisplayAssertion() }
        }
    }

    /// The assertion only stops idle sleep: a display that already slept
    /// (an armed close while no agent needed it) stays dark, and screenshots
    /// come back black, until user activity wakes it.
    private func wakeDisplayForAgents() {
        var activity = IOPMAssertionID(0)
        let result = IOPMAssertionDeclareUserActivity(
            "Wakely: waking the screen for agents" as CFString, kIOPMUserActiveLocal, &activity)
        guard result == kIOReturnSuccess else {
            Diagnostics.log("agent screen: display wake failed (\(result))")
            return
        }
        IOPMAssertionRelease(activity)
        Diagnostics.log("agent screen: display woken")
    }

    private func releaseDisplayAssertion() {
        if displayAsserted { IOPMAssertionRelease(displayAssertion) }
        displayAsserted = false
        displayAssertion = 0
    }

    /// Per-agent transitions, not aggregate count deltas: one count going up
    /// while another goes down is not evidence that anything finished, and a
    /// count can never say which agent's window is already in front.
    /// Sound is a per-user choice; absent means on.
    private var soundForNotifications: Bool {
        UserDefaults.standard.object(forKey: "agentNotifications.sound") as? Bool ?? true
    }

    private func agentNotifications(agents: AgentMonitor) {
        consumeFinished(agents.finishedThreads)
        for thread in agents.threads where thread.waiting && !notifiedWaitingAgents.contains(thread.id) {
            notifiedWaitingAgents.insert(thread.id)
            guard !AgentPresence.isFrontmost(thread: thread) else {
                Diagnostics.log("agent notification suppressed: the agent's app or terminal is frontmost")
                continue
            }
            guard UserDefaults.standard.object(forKey: "agentNotifications.waiting") as? Bool ?? true else { continue }
            Notifier.post(title: "\(thread.provider) needs you", body: "It is waiting for your approval.",
                          sound: soundForNotifications)
        }
        // A thread that stops waiting may notify again on a later wait; one that
        // disappears simply leaves the set.
        notifiedWaitingAgents.formIntersection(Set(agents.threads.filter(\.waiting).map(\.id)))
    }

    /// AgentMonitor replaces finishedThreads with every completed scan and calls
    /// onFinished once for a non-empty busy->idle set. Recording the snapshot is
    /// idempotent, so the callback and the tick can both call this safely.
    private func consumeFinished(_ finished: [AgentThread]) {
        guard finished != lastFinishedSnapshot else { return }
        lastFinishedSnapshot = finished
        guard isEnabled("agentNotifications") else { return }
        for thread in finished {
            guard !AgentPresence.isFrontmost(thread: thread) else {
                Diagnostics.log("agent finish notification suppressed: the agent's app or terminal is frontmost")
                continue
            }
            guard UserDefaults.standard.object(forKey: "agentNotifications.finished") as? Bool ?? true else { continue }
            Notifier.post(title: "\(thread.provider) finished", body: "It finished its work.",
                          sound: soundForNotifications)
        }
    }

    /// Chained, so another caller of onFinished is preserved rather than
    /// replaced. The callback is the prompt path; the tick polls the same
    /// snapshot for the case where a later caller owns the closure again.
    private func installAgentFinishHook() {
        guard !agentFinishHookInstalled else { return }
        agentFinishHookInstalled = true
        let previous = AgentMonitor.shared.onFinished
        AgentMonitor.shared.onFinished = { [weak self] finished in
            previous?(finished)
            Task { @MainActor [weak self] in self?.consumeFinished(finished) }
        }
    }

    // Every active condition owns a separate claim. Releasing one never ends
    // another component's claim or a manually armed session.
    private func hold(_ id: String, while condition: Bool, engine: PowerEngine, grace: TimeInterval = 0) {
        guard isEnabled(id) else { return }
        // Home Server's always-on hold must obey the persisted launch rearm
        // budget; otherwise the tick would arm immediately after a budget-
        // limited launch and the crash-loop limit would mean nothing.
        if id == "homeServer", !HomeServerAutomation.automaticArmAllowed() { return }
        var active = condition
        if condition {
            graceStarted.removeValue(forKey: id)
        } else if grace > 0 && engine.isAutomaticOwner(id) {
            let since = graceStarted[id] ?? Date()
            graceStarted[id] = since
            active = Date().timeIntervalSince(since) < grace
        }
        if active {
            let wasArmed = engine.isArmed
            // Always On While Plugged In arms by itself and stays armed even when
            // the lid opens. Home Server makes the same always-on promise, so
            // both owners are persistent. Every other condition stays one-close.
            let lifetime: ArmSessionLifetime = (id == "alwaysOnPluggedIn" || id == "homeServer")
                ? .persistent : .oneClose
            if engine.requestAutomaticArm(owner: id,
                                          source: ComponentCatalog.definition(for: id)?.name ?? id,
                                          lifetime: lifetime), !wasArmed {
                Diagnostics.log("component \(id) armed the session")
                if !suppressNotifications {
                    Notifier.post(title: ComponentCatalog.definition(for: id)?.name ?? "Wakely",
                                  body: "Wakely armed. You can close the lid.")
                }
            }
        } else {
            graceStarted.removeValue(forKey: id)
            engine.releaseAutomaticArm(owner: id, reason: "\(ComponentCatalog.definition(for: id)?.name ?? id) let go")
        }
    }

    private func reconcileAutomaticHolds(engine: PowerEngine, env: Environment, agents: AgentMonitor) {
        let now = Date()
        // Process presence is not work: idle and unknown CLIs remain in the
        // monitor after a turn ends. Only explicit busy states may start or
        // prolong the finish-work cohort.
        let currentAgents = Set(agents.threads.filter { $0.working || $0.waiting }.map(\.id))
        let waitingAgents = Set(agents.threads.filter(\.waiting).map(\.id))
        if isEnabled("finishWorkThenSleep") {
            if agentSnapshot.started == nil, !currentAgents.isEmpty { agentSnapshot.begin(ids: currentAgents, now: now) }
            // The session cap and the waiter window are the user's settings;
            // the defaults keep the old four-hour / fifteen-minute behaviour.
            let maximum = TimeInterval(intSetting("finishWorkThenSleep.maxHours", default: 12, in: 1...24) * 3600)
            let waitingMaximum = TimeInterval(intSetting("finishWorkThenSleep.waitMinutes", default: 15, in: 1...240) * 60)
            let active = agentSnapshot.active(current: currentAgents, waiting: waitingAgents, now: now,
                                               maximum: maximum, waitingMaximum: waitingMaximum)
            let expired = agentSnapshot.started.map { now.timeIntervalSince($0) >= maximum } ?? false
            hold("finishWorkThenSleep", while: active, engine: engine, grace: expired ? 0 : 180)
        }
        hold("alwaysOnPluggedIn", while: env.onCharger, engine: engine)
        hold("homeServer", while: env.onCharger, engine: engine)
        // The grace after the last remote session drops is the user's setting;
        // the default keeps the old ten-minute behaviour.
        let remoteSeconds = TimeInterval(intSetting("awakeWhileConnected.graceMinutes", default: 10, in: 1...120) * 60)
        let connected = remoteGrace.active(SSH.activeSessions() > 0, now: now, seconds: remoteSeconds, eligible: env.onCharger)
        hold("awakeWhileConnected", while: connected, engine: engine)
        let bundle = UserDefaults.standard.string(forKey: "armWhileAppRuns.bundleID") ?? ""
        hold("armWhileAppRuns", while: !bundle.isEmpty && NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundle }, engine: engine)
        let wanted = UserDefaults.standard.string(forKey: "armOnWiFi.ssid") ?? ""
        if isEnabled("armOnWiFi") {
            let present = WiFi.currentSSID() == wanted
            let active = wifiGrace.active(present, now: now, seconds: 60, eligible: env.onCharger && !wanted.isEmpty)
            hold("armOnWiFi", while: active, engine: engine)
        }
        let start = UserDefaults.standard.string(forKey: "armOnSchedule.start") ?? "22:00"
        let end = UserDefaults.standard.string(forKey: "armOnSchedule.end") ?? "07:00"
        let days = UserDefaults.standard.array(forKey: "armOnSchedule.weekdays") as? [Int] ?? Array(1...7)
        hold("armOnSchedule", while: env.onCharger && ComponentSchedulePolicy.contains(now: now, start: start, end: end, weekdays: days), engine: engine)
        if isEnabled("armWhenDriveConnects") {
            let selected = Set(UserDefaults.standard.stringArray(forKey: "armWhenDriveConnects.volumeIDs") ?? [])
            let connected = !selected.isDisjoint(with: Set(Volumes.external().compactMap { Volumes.identifier($0) }))
            hold("armWhenDriveConnects", while: env.onCharger && connected, engine: engine)
        }
        if isEnabled("finishJobsThenSleep") {
            let jobs = WorkProcesses.currentIDs()
            if jobsSnapshot.started == nil, !jobs.isEmpty { jobsSnapshot.begin(ids: jobs, now: now) }
            // The session cap and the post-job window are the user's settings;
            // the defaults keep the old eight-hour / two-minute behaviour.
            let maximum = TimeInterval(intSetting("finishJobsThenSleep.maxHours", default: 8, in: 1...24) * 3600)
            let waitingMaximum = TimeInterval(intSetting("finishJobsThenSleep.waitMinutes", default: 2, in: 1...120) * 60)
            let active = jobsSnapshot.active(current: jobs, now: now, maximum: maximum)
            let expired = jobsSnapshot.started.map { now.timeIntervalSince($0) >= maximum } ?? false
            hold("finishJobsThenSleep", while: active, engine: engine, grace: expired ? 0 : waitingMaximum)
        }
        // Caps Lock has one controller, not a second, competing automatic owner.
    }

    private func batteryBudget(engine: PowerEngine) {
        let consumed = batteryPolicy.sample(percent: engine.batteryPercent(), closed: engine.lidClosed,
                                            armed: engine.isArmed, onBattery: engine.onBattery())
        let budget = max(1, UserDefaults.standard.object(forKey: "batteryBudget.percent") as? Int ?? 15)
        if consumed >= budget {
            engine.disarm(reason: "the battery budget ran out")
            Notifier.post(title: "Battery Budget", body: "The closed session used its \(budget) percent. Your Mac can sleep.")
        }
    }

    private func sleepWhenIdle(engine: PowerEngine, agents: AgentMonitor) {
        let busy = agents.workingCount + agents.waitingCount > 0 || SSH.activeSessions() > 0 || networkBusy || !WorkProcesses.currentIDs().isEmpty
        if busy {
            idleSince = nil
            if idleMayRearm && !idleHadActivity && !engine.lidClosed {
                idleMayRearm = false
                _ = engine.requestAutomaticArm(owner: "sleepWhenIdle", source: "new activity")
            }
        } else if engine.isArmed && engine.lidClosed {
            idleSince = idleSince ?? Date()
            let idleWindow = TimeInterval(intSetting("sleepWhenIdle.minutes", default: 15, in: 1...240) * 60)
            if Date().timeIntervalSince(idleSince!) >= idleWindow {
                engine.disarm(reason: "nothing was working")
                idleMayRearm = true
                idleSince = nil
            }
        }
        idleHadActivity = busy
    }

    private func sleepTimer(engine: PowerEngine) {
        guard engine.isArmed else { sleepDeadline = nil; return }
        let minutes = max(1, UserDefaults.standard.object(forKey: "sleepTimer.minutes") as? Int ?? 30)
        sleepDeadline = sleepDeadline ?? Date().addingTimeInterval(Double(minutes) * 60)
        guard let deadline = sleepDeadline else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 60 && remaining > 0 { Audio.fadeOut(seconds: remaining) }
        guard remaining <= 0 else { return }
        sleepDeadline = nil
        preserveFadeOnSessionEnd = true
        engine.disarm(reason: "the sleep timer ended")
        preserveFadeOnSessionEnd = false
        if engine.isArmed {
            Audio.cancelFade(restore: true)
            Diagnostics.log("sleep timer: another owner kept the session armed; audio restored")
            return
        }
        let generation = engine.sessionGeneration
        pendingSleep?.cancel()
        pendingSleep = Task { @MainActor [weak self] in
            // Allow cancellation/re-arm during the delay. Never sleep a newer session.
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            guard let self, self.isEnabled("sleepTimer"), !engine.isArmed,
                  engine.sessionGeneration == generation else { return }
            if !System.sleep() {
                Audio.cancelFade(restore: true)
                Diagnostics.log("sleep timer: sleep request refused; audio restored")
            }
            self.pendingSleep = nil
        }
    }

    // MARK: - Lid

    func lidChanged(closed: Bool) {
        quietCloseTask?.cancel(); quietCloseTask = nil
        if closed {
            // Password After Close acts on the close itself, armed or not, and
            // locks the screen before the helper applies the Touch ID change.
            PasswordAfterCloseController.shared.lidDidClose()
            // The close is the first moment this component may schedule anything.
            SleepUntilResetController.shared.lidDidClose()
            endKeepAwake()
            // A close while already armed is a session start for protected
            // settings even when the arm generation did not change.
            if PowerEngine.shared.isArmed { ProtectedComponents.shared.sessionDidStart() }
            if isEnabled("quietClose"), !mutedByUs {
                quietCloseTask = Task { @MainActor [weak self] in
                    _ = await CloseSoundPlayer.shared.waitForPlaybackCompletion(timeout: 4)
                    guard !Task.isCancelled, let self, self.isEnabled("quietClose"),
                          PowerEngine.shared.lidClosed else { return }
                    // Capture the exact device only after playback has finished.
                    // A read failure is not evidence that the device was unmuted.
                    guard let snapshot = Audio.muteSnapshot(),
                          Audio.setMuted(true, device: snapshot.device) else {
                        Diagnostics.log("quiet close: output mute could not be read or set")
                        return
                    }
                    self.savedMute = snapshot
                    self.mutedByUs = true
                }
            }
            if isEnabled("lidShortcuts") { Shortcuts.run(named: UserDefaults.standard.string(forKey: "lidShortcuts.close") ?? "") }
        } else {
            // The lock-aware Password After Close controller owns its own
            // restore trigger; the generic sweep must not hand Touch ID back
            // while the password prompt is still up.
            ProtectedComponents.shared.restoreSessionScoped(reason: "lid opened",
                                                        excluding: ["passwordAfterClose"])
            // Restore only when the screen is provably unlocked; a lid open on
            // the password prompt keeps Touch ID off.
            PasswordAfterCloseController.shared.lidDidOpen()
            // Opening the lid is the user's override: the owned wakes go.
            SleepUntilResetController.shared.lidDidOpen()
            restoreQuietClose()
            bagCheckNotified = false
            sleepPreparedForThisSleep = false
            restoreBluetooth()
            if isEnabled("lidShortcuts") { Shortcuts.run(named: UserDefaults.standard.string(forKey: "lidShortcuts.open") ?? "") }
        }
    }

    private func bagCheck(engine: PowerEngine, env: Environment) {
        guard env.lidClosed, !engine.isArmed else { bagCheckTimer?.invalidate(); bagCheckTimer = nil; return }
        // One notice per closed, unarmed episode. The capability describes one
        // notice, not a reminder every minute for as long as the lid stays shut.
        guard !bagCheckNotified, bagCheckTimer == nil else { return }
        bagCheckTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in
            Task { @MainActor in
                if PowerEngine.shared.lidClosed && !PowerEngine.shared.isArmed {
                    self.bagCheckNotified = true
                    Notifier.post(title: "Bag Check", body: "Your Mac is awake with the lid closed and Wakely is off. If it is in a bag, it will not sleep.")
                }
                self.bagCheckTimer = nil
            }
        }
    }

    // MARK: - Cleaning lock

    private func cleaningLockTick() {
        if PowerEngine.shared.isArmed { CleaningLockController.shared.end() }
    }

    func beginCleaningLock(seconds: Int = 60) {
        guard !PowerEngine.shared.isArmed else {
            SettingsModel.shared.cleaningLockMessage = "Disarm Wakely before locking input for cleaning. Your keyboard has not been locked."
            if isEnabled("cleaningLock") { setEnabled("cleaningLock", false) }
            return
        }
        guard ComponentPermissions.shared.requireAccessibility(for: "cleaningLock") else {
            SettingsModel.shared.cleaningLockMessage = "Accessibility access is needed. Finish setup, then turn Cleaning Lock on again. Your keyboard is not locked."
            if isEnabled("cleaningLock") { setEnabled("cleaningLock", false) }
            return
        }
        if !isEnabled("cleaningLock") {
            setEnabled("cleaningLock", true)
            return // The enable path starts the controller exactly once.
        }
        guard isEnabled("cleaningLock") else {
            SettingsModel.shared.cleaningLockMessage = "Cleaning Lock could not be enabled. Your keyboard is not locked."
            return
        }
        if CleaningLockController.shared.begin(seconds: seconds) {
            SettingsModel.shared.cleaningLockMessage = "Cleaning lock started. Hold Escape for three seconds to finish early."
        } else {
            SettingsModel.shared.cleaningLockMessage = CleaningLockController.shared.failureReason
            setEnabled("cleaningLock", false)
        }
    }

    private func endCleaningLock() { CleaningLockController.shared.end() }
    var isKeyboardLocked: Bool { CleaningLockController.shared.isActive }

    // MARK: - Self test

    /// Read-only capability diagnostics. This never enables or disables a
    /// component, plays audio, ejects a disk, changes a preference, asks for a
    /// permission, or claims a PASS for behavior it did not observe.
    @discardableResult
    func runSelfTest() -> String {
        // Read the stored id list directly: the enabledIDs getter writes defaults
        // when the key is absent, and a report must not do that.
        let stored = UserDefaults.standard.stringArray(forKey: "enabledComponentIDs").map { Set($0) }
        var counts: [ComponentCapabilityStatus: Int] = [:]
        var body: [String] = []
        var category: String?
        for component in ComponentCatalog.all {
            if component.category.rawValue != category {
                category = component.category.rawValue
                if !body.isEmpty { body.append("") }
                body.append("[\(component.category.rawValue)]")
            }
            let capability = ComponentCapabilityPolicy.capability(for: component.id)
            counts[capability.status, default: 0] += 1
            let enabled: String
            if let stored {
                enabled = stored.contains(component.id) ? "on" : "off"
            } else {
                enabled = "unset"
            }
            body.append("\(component.id) [\(enabled)] — \(capability.status.label): \(capability.reason)")
        }
        let summary = [ComponentCapabilityStatus.implemented, .partial, .protectedManualOnly, .unsupported]
            .map { "\($0.label) \(counts[$0] ?? 0)" }
            .joined(separator: " | ")
        var lines = [
            "Wakely capability report — read-only, not a behavior test",
            "No component was enabled, disabled, played, ejected, or asked for a permission.",
            summary
        ]
        lines.append(contentsOf: body)
        let registered = ComponentCapabilityPolicy.registeredIDs
        let missing = ComponentCatalog.all.map(\.id).filter { !registered.contains($0) }
        if !missing.isEmpty {
            lines.append("capability table error: no entry for \(missing.joined(separator: ", "))")
        }
        if !ComponentCapabilityPolicy.duplicateIDs.isEmpty {
            lines.append("capability table error: duplicate entries for \(ComponentCapabilityPolicy.duplicateIDs.joined(separator: ", "))")
        }
        lines.append("A capability is not a PASS: it describes the shipped code path, not observed behavior.")
        Diagnostics.log("capability report: \(summary) (\(ComponentCatalog.all.count) components)")
        let report = lines.joined(separator: "\n")
        try? report.write(to: Diagnostics.supportDirectory.appendingPathComponent("capability.txt"),
                          atomically: true, encoding: .utf8)
        return report
    }

}

// MARK: - Password After Close

/// What a narrow Touch ID-off application did. `.unavailable` is deliberately
/// coarse: the helper is missing, busy, shutting down or rate-limited, and the
/// phase stays `turnOffPending` so the close can be retried while it stands.
enum PasswordAfterCloseOutcome: Equatable {
    case applied
    case alreadyApplied
    case unavailable
    case failed(String)
}

enum PasswordAfterCloseRestoreOutcome: Equatable {
    case restored
    case nothingApplied
    case failed(String)
    case busy
}

/// The runtime half of Password After Close. The pure decisions live in
/// PasswordAfterClosePolicy; this class owns the persisted phase, the lock
/// observer and the narrow helper calls.
///
/// Promise: after a close, Touch ID for unlock stays off until an unlock is
/// observed (or Wakely quits/disables), never restored while the screen is
/// locked, and never turned off after an unlock.
@MainActor
final class PasswordAfterCloseController {
    static let shared = PasswordAfterCloseController()

    private static let phaseKey = "passwordAfterClose.phase"
    private static let closeIDKey = "passwordAfterClose.closeID"
    private static let retryFloor: TimeInterval = 5
    private static let failureLogFloor: TimeInterval = 60

    private let defaults: UserDefaults
    private var phase: PasswordAfterClosePolicy.Phase = .idle
    private var unlockedSinceClose = false
    private var observer: ScreenLockObserver?
    private var applyInFlight = false
    private var restoreInFlight = false
    private var nextAttempt = Date.distantPast
    private var lastFailureLog = Date.distantPast
    private var lateTurnOffLoggedFor: UUID?
    private var shuttingDown = false

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.phase = PasswordAfterClosePolicy.restore(
            from: defaults.string(forKey: Self.phaseKey),
            closeID: defaults.string(forKey: Self.closeIDKey))
    }

    /// Read-only view for diagnostics and structural tests.
    var currentPhase: PasswordAfterClosePolicy.Phase { phase }

    private func setPhase(_ next: PasswordAfterClosePolicy.Phase) {
        guard phase != next else { return }
        phase = next
        let record = PasswordAfterClosePolicy.persist(next)
        defaults.set(record.name, forKey: Self.phaseKey)
        if let closeID = record.closeID {
            defaults.set(closeID, forKey: Self.closeIDKey)
        } else {
            defaults.removeObject(forKey: Self.closeIDKey)
        }
    }

    private var helperInstalled: Bool {
        if case .installed = HelperClient.shared.installState { return true }
        return false
    }

    /// One user-facing switch from the persisted preferences. The settings pane
    /// owns the stored value; a missing key falls back to the documented default.
    private func boolSetting(_ key: String, default def: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? def
    }

    /// An immediate Lock Screen request is today's rule. With
    /// `passwordAfterClose.immediate` off the system's usual lock delay applies
    /// instead; the Touch ID hand-back work still runs.
    @discardableResult
    private func lockImmediatelyIfRequested() -> Bool {
        guard boolSetting("passwordAfterClose.immediate", default: true) else {
            Diagnostics.log("password after close: immediate Lock Screen is off; the usual delay applies")
            return true
        }
        return PowerEngine.shared.lockScreenNow(reason: "password after close")
    }

    // MARK: Close

    /// Called immediately on a real lid close, armed or not: turning Touch ID
    /// off at close is this component's whole purpose. An external display means
    /// the close is a normal desktop session and changes nothing, unless the
    /// user asked for a lock even then.
    func lidDidClose() {
        guard !shuttingDown else { return }
        guard ComponentEngine.shared.isEnabled("passwordAfterClose") else { return }
        let externalDisplay = PowerEngine.shared.externalDisplayCount() > 0
        let lockWithExternalDisplay = boolSetting("passwordAfterClose.externalDisplay", default: false)
        guard PasswordAfterClosePolicy().shouldTurnOff(
            componentEnabled: true, externalDisplay: externalDisplay && !lockWithExternalDisplay) else {
            Diagnostics.log("password after close: external display connected; closing the lid changes nothing")
            return
        }
        switch phase {
        case .idle:
            let closeID = UUID()
            unlockedSinceClose = false
            lateTurnOffLoggedFor = nil
            lastFailureLog = .distantPast
            setPhase(.turnOffPending(closeID: closeID))
            Diagnostics.log("password after close: lid closed; requesting the Lock Screen and Touch ID off")
            startObserverIfNeeded()
            guard lockImmediatelyIfRequested() else {
                noteFailure("the Lock Screen request was not accepted; Touch ID was left unchanged")
                setPhase(.idle)
                return
            }
            Task { await self.applyTurnOff(closeID: closeID) }
        case .turnOffPending(let closeID):
            // Repeated close notifications for one standing close are
            // idempotent: same lifecycle, same id, one promised unlock.
            Diagnostics.log("password after close: repeated close; the standing hand-back is unchanged")
            guard lockImmediatelyIfRequested() else {
                noteFailure("the Lock Screen request was not accepted; Touch ID was left unchanged")
                return
            }
            startObserverIfNeeded()
            Task { await self.applyTurnOff(closeID: closeID) }
        case .off, .restorePending:
            // Touch ID is already off for a close that has not been settled by
            // an unlock; another close must not erase the earlier promise.
            Diagnostics.log("password after close: close while the previous hand-back is still owed; keeping it")
            if !lockImmediatelyIfRequested() {
                noteFailure("the Lock Screen request was not accepted")
            }
            startObserverIfNeeded()
        }
    }

    /// The private lock API has no documented success contract. Observation is
    /// the only safe proof before changing the authentication database.
    private func waitForObservedScreenLock() async -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if ScreenLockObserver.readIsLocked() == true { return true }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        return false
    }

    private func applyTurnOff(closeID: UUID) async {
        guard case .turnOffPending(let current) = phase, current == closeID else { return }
        guard !applyInFlight else { return }
        applyInFlight = true
        defer { applyInFlight = false }

        if boolSetting("passwordAfterClose.immediate", default: true) {
            guard await waitForObservedScreenLock() else {
                noteFailure("the Lock Screen did not become active; Touch ID was left unchanged")
                setPhase(.idle)
                return
            }
        }
        let outcome = await ProtectedComponents.shared.passwordAfterCloseDidClose()
        switch outcome {
        case .applied, .alreadyApplied:
            // The write landed. Two races must undo it rather than leave an
            // unreported Touch ID lockout: an unlock during the request, and an
            // orderly quit during the request.
            if unlockedSinceClose {
                setPhase(.restorePending(closeID: closeID))
                Diagnostics.log("password after close: unlocked before the late turn-off finished")
                await restore(closeID: closeID, reason: "unlocked before the late turn-off finished")
                return
            }
            if shuttingDown {
                setPhase(.restorePending(closeID: closeID))
                await restore(closeID: closeID, reason: "Wakely quit")
                return
            }
            // The phase may have moved on while the helper answered.
            guard case .turnOffPending(let still) = phase, still == closeID else { return }
            setPhase(.off(closeID: closeID))
            Diagnostics.log("password after close: Touch ID for unlock turned off for this Mac")
            startObserverIfNeeded()
        case .unavailable:
            guard case .turnOffPending(let still) = phase, still == closeID else { return }
            noteFailure("turning Touch ID for unlock off not confirmed")
            logLateTurnOffIfNeeded()
            startObserverIfNeeded()
        case .failed(let message):
            guard case .turnOffPending(let still) = phase, still == closeID else { return }
            noteFailure("turning Touch ID for unlock off not confirmed: \(message)")
            logLateTurnOffIfNeeded()
            startObserverIfNeeded()
        }
    }

    // MARK: Restore triggers

    /// The promised unlock happened. This is the strongest trigger.
    private func unlockObserved() {
        unlockedSinceClose = true
        switch phase {
        case .idle:
            stopObserverIfIdle()
        case .turnOffPending(let closeID):
            if pendingTurnOffWasApplied() {
                setPhase(.restorePending(closeID: closeID))
                Diagnostics.log("password after close: unlocked before the late turn-off finished")
                Task { await self.restore(closeID: closeID, reason: "the next unlock") }
            } else {
                Diagnostics.log("password after close: unlocked since the close that found the helper away; no late turn-off")
                setPhase(.idle)
                stopObserverIfIdle()
            }
        case .off(let closeID), .restorePending(let closeID):
            Task { await self.restore(closeID: closeID, reason: "the next unlock") }
        }
    }

    /// The armed-session apply path and the close-time path share the same
    /// interlocks, but a tick can win the race and leave the write applied while
    /// the controller still holds `turnOffPending`. Never cancel that as if
    /// nothing happened: ask the helper's ledger first.
    private func pendingTurnOffWasApplied() -> Bool {
        ProtectedComponents.shared.hasApplied("passwordAfterClose")
    }

    /// Opening the lid is not itself an unlock: while the password prompt is up
    /// the screen is still locked, and handing Touch ID back would defeat the
    /// promise. Unknown lock state is treated the same way.
    func lidDidOpen() {
        guard PasswordAfterClosePolicy.owesHandBack(phase) else { return }
        switch ScreenLockObserver.isLocked {
        case true:
            Diagnostics.log("password after close: lid open with the screen still locked; Touch ID stays off until the next unlock")
            startObserverIfNeeded()
            if case .turnOffPending = phase { attemptPendingTurnOff() }
        case false:
            settleWhileUnlocked(trigger: "lid open")
        case nil:
            Diagnostics.log("password after close: lid open but the lock state is unknown; Touch ID stays off for now")
            startObserverIfNeeded()
            if case .turnOffPending = phase { attemptPendingTurnOff() }
        }
    }

    /// A wake can be a real unlock or a lid-open wake that is still locked. Only
    /// a proven unlocked screen restores.
    func lidDidWake() {
        guard PasswordAfterClosePolicy.owesHandBack(phase) else { return }
        guard ScreenLockObserver.isLocked == false else {
            startObserverIfNeeded()
            return
        }
        settleWhileUnlocked(trigger: "wake")
    }

    /// Launch is the recovery trigger: finish or undo a phase persisted by a
    /// previous run. An unlock observed while Wakely was away is not
    /// recoverable as an event, so a proven unlocked screen settles the debt.
    func didLaunch() async {
        guard !shuttingDown else { return }
        // Adopt helper leases before deciding: a previous run may have died
        // between the helper's write and our phase update.
        await ProtectedComponents.shared.bootstrap()
        let hasLease = ProtectedComponents.shared.hasApplied("passwordAfterClose")

        guard let closeID = PasswordAfterClosePolicy.closeID(of: phase) else {
            if hasLease {
                // Give the recovery a phase, so a failed restore is retried on
                // the next trigger instead of leaving an unexplained lockout.
                let recoveryID = UUID()
                setPhase(.restorePending(closeID: recoveryID))
                Diagnostics.log("password after close: found an unexplained Touch ID lease from a previous run; putting it back")
                await restore(closeID: recoveryID, reason: "an unexplained lease from a previous run")
            } else {
                stopObserverIfIdle()
            }
            return
        }

        // A component disabled while the app was away is a safety stop: put a real
        // write back and drop an unconfirmed request. Never turn it off late.
        if !ComponentEngine.shared.isEnabled("passwordAfterClose") {
            if hasLease {
                setPhase(.restorePending(closeID: closeID))
                Diagnostics.log("password after close: component disabled; asking for Touch ID for unlock back on")
                await restore(closeID: closeID, reason: "component disabled")
            } else {
                setPhase(.idle)
                stopObserverIfIdle()
                Diagnostics.log("password after close: component disabled; the unconfirmed turn-off is cancelled")
            }
            return
        }

        unlockedSinceClose = ScreenLockObserver.isLocked == false
        if unlockedSinceClose {
            Diagnostics.log("password after close: launched with the screen unlocked; settling the standing hand-back")
            settleWhileUnlocked(trigger: "launch")
            return
        }
        startObserverIfNeeded()
        Diagnostics.log("password after close: hand-back still not settled; asked again at the next unlock, lid open, wake or launch")
        if case .turnOffPending = phase { attemptPendingTurnOff() }
    }

    /// A settle path reached with proof that the screen is not locked.
    private func settleWhileUnlocked(trigger: String) {
        switch phase {
        case .idle:
            stopObserverIfIdle()
        case .turnOffPending(let closeID):
            if pendingTurnOffWasApplied() {
                setPhase(.restorePending(closeID: closeID))
                Diagnostics.log("password after close: \(trigger) found an applied turn-off; putting Touch ID back")
                Task { await self.restore(closeID: closeID, reason: trigger) }
            } else {
                setPhase(.idle)
                stopObserverIfIdle()
                Diagnostics.log("password after close: \(trigger) found the screen unlocked before the late turn-off finished; no turn-off")
            }
        case .off(let closeID), .restorePending(let closeID):
            Task { await self.restore(closeID: closeID, reason: trigger) }
        }
    }

    private func restore(closeID: UUID, reason: String) async {
        guard !restoreInFlight else { return }
        restoreInFlight = true
        defer { restoreInFlight = false }

        if case .off(let current) = phase, current == closeID {
            setPhase(.restorePending(closeID: closeID))
        }
        let outcome = await ProtectedComponents.shared.passwordAfterCloseRestore()
        switch outcome {
        case .restored:
            settleRestored(closeID: closeID)
            Diagnostics.log("password after close: Touch ID for unlock back on for this Mac")
        case .nothingApplied:
            // Nothing this run wrote (or an earlier restore already finished).
            settleRestored(closeID: closeID)
        case .busy:
            // Another path owns the restore; a later trigger retries.
            break
        case .failed(let message):
            // Keep exactly a restore that is still owed. A pending turn-off or a
            // newer close is not converted into a restore by a stale reply.
            if case .off(let current) = phase, current == closeID {
                setPhase(.restorePending(closeID: closeID))
            }
            noteFailure("hand-back still not settled; asked again at the next unlock, lid open, wake or launch (\(message))")
            startObserverIfNeeded()
        }
    }

    private func settleRestored(closeID: UUID) {
        if case .off(let current) = phase, current == closeID { setPhase(.idle) }
        if case .restorePending(let current) = phase, current == closeID { setPhase(.idle) }
        stopObserverIfIdle()
    }

    // MARK: Quit / disable

    /// Quit restores: if Wakely quits first, Touch ID comes back on then.
    /// The termination drain owns the wait; this
    /// starts the request and leaves the phase persisted if it cannot finish.
    func didQuit() {
        shuttingDown = true
        switch phase {
        case .idle:
            stopObserverIfIdle()
        case .turnOffPending(let closeID):
            if pendingTurnOffWasApplied() {
                setPhase(.restorePending(closeID: closeID))
                Diagnostics.log("password after close: Wakely quits first; asking for Touch ID for unlock back on")
                Task { await self.restore(closeID: closeID, reason: "Wakely quit") }
            } else {
                setPhase(.idle)
                stopObserver()
                Diagnostics.log("password after close: Wakely quit before the late turn-off finished; Touch ID was left on")
            }
        case .off(let closeID), .restorePending(let closeID):
            setPhase(.restorePending(closeID: closeID))
            Diagnostics.log("password after close: Wakely quits first; asking for Touch ID for unlock back on")
            Task { await self.restore(closeID: closeID, reason: "Wakely quit") }
        }
    }

    /// Disabling the component is a safety-class stop: it restores a hand-back
    /// immediately and drops any unconfirmed late turn-off.
    func didDisable() {
        guard PasswordAfterClosePolicy.owesHandBack(phase) else {
            stopObserverIfIdle()
            return
        }
        let owed = PasswordAfterClosePolicy.hasAppliedTurnOff(phase) || pendingTurnOffWasApplied()
        setPhase(.idle)
        stopObserver()
        if owed {
            Diagnostics.log("password after close: component disabled; asking for Touch ID for unlock back on")
            ProtectedComponents.shared.restore(component: "passwordAfterClose", reason: "component disabled")
        } else {
            Diagnostics.log("password after close: component disabled; the unconfirmed turn-off is cancelled")
        }
    }

    // MARK: Polling

    /// Runs from the component engine's tick. It retries only while the close
    /// still stands and the screen is locked; an unlock cancels instead.
    func tick() {
        guard PasswordAfterClosePolicy.owesHandBack(phase) else {
            stopObserverIfIdle()
            return
        }
        startObserverIfNeeded()
        guard !applyInFlight, !restoreInFlight, Date() >= nextAttempt else { return }
        switch phase {
        case .turnOffPending(let closeID):
            let locked = ScreenLockObserver.isLocked
            if locked == false {
                settleWhileUnlocked(trigger: "tick")
                return
            }
            guard PasswordAfterClosePolicy().shouldRetryTurnOff(
                lidClosed: PowerEngine.shared.lidClosed,
                isLocked: locked,
                helperReachable: helperInstalled,
                phase: phase) else { return }
            nextAttempt = Date().addingTimeInterval(Self.retryFloor)
            Task { await self.applyTurnOff(closeID: closeID) }
        case .restorePending(let closeID):
            guard ScreenLockObserver.isLocked == false else { return }
            // Immediate triggers (unlock, lid open, wake) retry at once; only
            // the background tick is paced, so a missing helper is not asked
            // every five seconds.
            nextAttempt = Date().addingTimeInterval(Self.failureLogFloor)
            Task { await self.restore(closeID: closeID, reason: "retry after a failed restore") }
        case .off, .idle:
            break
        }
    }

    private func attemptPendingTurnOff() {
        guard case .turnOffPending(let closeID) = phase, !applyInFlight else { return }
        guard helperInstalled else {
            logLateTurnOffIfNeeded()
            return
        }
        Task { await self.applyTurnOff(closeID: closeID) }
    }

    private func noteFailure(_ detail: String) {
        let now = Date()
        guard now.timeIntervalSince(lastFailureLog) >= Self.failureLogFloor else { return }
        lastFailureLog = now
        Diagnostics.log("password after close: \(detail)")
    }

    private func logLateTurnOffIfNeeded() {
        guard case .turnOffPending(let closeID) = phase, lateTurnOffLoggedFor != closeID else { return }
        lateTurnOffLoggedFor = closeID
        Diagnostics.log("password after close: helper not ready (re-registering or awaiting Login Items approval); Touch ID left on, turned off late if it is back while this close stands")
    }

    // MARK: Lock observer

    private func startObserverIfNeeded() {
        guard PasswordAfterClosePolicy.owesHandBack(phase) else { return }
        if observer == nil {
            let observer = ScreenLockObserver()
            observer.onUnlocked = { [weak self] in self?.unlockObserved() }
            observer.onLocked = { [weak self] in
                guard let self, PasswordAfterClosePolicy.isTurnOffPending(self.phase) else { return }
                self.logLateTurnOffIfNeeded()
            }
            self.observer = observer
        }
        observer?.start()
    }

    private func stopObserver() {
        observer?.stop()
        observer = nil
    }

    private func stopObserverIfIdle() {
        guard case .idle = phase else { return }
        stopObserver()
    }
}

// MARK: - Protected components

/// The only app-side code allowed to drive privileged settings. Every call goes
/// through `HelperComponentAPI`; nothing here can express an arbitrary command.
///
/// State model:
///  - `applied` records recovery ownership: a successful mutation or an explicit
///    durable helper lease. A lease alone is not proof the write succeeded.
///  - Failed requests are reconciled separately; no lease means no invented
///    restoration ownership. Transport uncertainty survives until a lease is seen.
///  - A saved lease is adopted after a crash so open/end/disable can restore it;
///    failed-application leases are rolled back immediately when discovered.
///  - Repeated session events and ticks see `applied`/`applying` and do nothing.
@MainActor
final class ProtectedComponents {
    static let shared = ProtectedComponents()

    private let api = HelperComponentAPI()
    private(set) var applied: Set<String> = []
    private var fanGovernor: Task<Void, Never>?
    private var fanForced = false
    private var applying: Set<String> = []
    private var restoring: Set<String> = []
    private var shuttingDown = false
    /// Monotonic epoch for fan replies. A reply may only change `fanForced` or
    /// start/stop the governor while its issuing generation is still current.
    /// Bumped when a session starts, when restoration begins, and on shutdown.
    private var sessionGeneration = 0
    /// Fan mutations that have not produced a definitive answer, with the
    /// generation that issued them. Entries are registered before the request
    /// can suspend, so the termination drain cannot miss queued work. A
    /// transport-uncertain failure stays here: it is unresolved, not gone.
    private var fanInFlight: [UUID: Int] = [:]
    /// Final session-only `restoreSession` sweep, started at most once.
    private var finalRestoreTask: Task<Void, Never>?

    func beginShutdown() {
        shuttingDown = true
        sessionGeneration += 1
        stopFanGovernor()
    }

    /// Drain already-issued helper operations without blocking the main actor.
    /// Persistent leases intentionally survive ordinary quit. A failed restore
    /// remains recorded, rather than being reported as successfully restored.
    ///
    /// The final sweep is one `restoreSession` call (not per-component
    /// `restoreComponent` requests) and is never awaited past this deadline: a
    /// helper that never answers makes the drain return false, not hang.
    func awaitShutdownRestoration(timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var finalRestoreScheduled = false
        while true {
            if applying.isEmpty && probeTask == nil {
                if !finalRestoreScheduled {
                    finalRestoreScheduled = true
                    // Bootstrap may have adopted a session lease after stop().
                    scheduleFinalSessionRestore()
                }
                if finalRestoreTask == nil, restoring.isEmpty, fanInFlight.isEmpty {
                    return ProtectedComponentPolicy.restorePlan(applied: applied, limit: .session).isEmpty
                        && !pendingReconciliation.keys.contains {
                            ProtectedComponentPolicy.scope(of: $0) == .session
                        }
                }
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
        }
    }

    /// The helper restores only session-scoped leases for `restoreSession`;
    /// persistent leases stay. Scheduled rather than awaited so the drain's
    /// deadline is authoritative even when XPC never replies.
    private func scheduleFinalSessionRestore() {
        guard finalRestoreTask == nil else { return }
        finalRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let receipt = await self.api.restoreSession()
            if receipt.reply.ok {
                for id in ProtectedComponentPolicy.restorePlan(applied: self.applied, limit: .session) {
                    self.applied.remove(id)
                }
            } else {
                Diagnostics.log("termination drain: session restore failed: \(receipt.reply.message)")
            }
            self.finalRestoreTask = nil
        }
    }
    private var retryAfter: [String: Date] = [:]
    private var probeFinished = false
    private var probeTask: Task<Void, Never>?
    private var nextProbeAfter: Date?
    // Unresolved requests are not successful application. Persist transport
    // uncertainty: concurrent status absence cannot prove a timed-out write ended.
    // v2 stores the client request UUID so a protocol-2 helper can answer
    // authoritatively; v1 held bare component ids and migrates to unresolved
    // (nil UUID, transport-uncertain) records.
    private static let reconciliationKey = "protectedHelperPendingRecovery.v1"
    private static let reconciliationKeyV2 = "protectedHelperPendingRecovery.v2"
    private var pendingReconciliation: [String: ProtectedPendingRecovery] = [:]
    private var reconciliationTask: Task<Void, Never>?
    /// Precise refusal/failure text for the settings UI.
    private(set) var lastEnablementReason: [String: String] = [:]
    /// Helper enhancements that are unavailable but do not block a component's
    /// core behavior (currently Home Server's firmware auto-restart).
    private var optionalUnsupported: Set<String> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.reconciliationKeyV2),
           let decoded = try? JSONDecoder().decode([String: ProtectedPendingRecovery].self, from: data) {
            for (id, record) in decoded where ProtectedComponentPolicy.isProtected(id) {
                pendingReconciliation[id] = record
            }
        } else {
            let legacy = UserDefaults.standard.stringArray(forKey: Self.reconciliationKey) ?? []
            for (id, record) in ProtectedRecoveryPolicy.migrateLegacyPending(legacy)
                where ProtectedComponentPolicy.isProtected(id) {
                pendingReconciliation[id] = record
            }
        }
    }

    // MARK: Capability gate

    /// Ask the live helper whether this component's operation is supported. The
    /// caller stays off unless this returns true; a refusal is recorded.
    func gateEnablement(_ id: String) async -> Bool {
        guard ProtectedComponentPolicy.isProtected(id) else { return true }
        guard let name = ProtectedComponentPolicy.operation(for: id),
              let operation = Self.operation(named: name) else {
            refuse(id, "no privileged operation is defined for this component")
            return false
        }
        guard await HelperClient.shared.isReachable() else {
            refuse(id, ProtectedComponentPolicy.gate(
                componentID: id, reachable: false, supported: false).reason)
            return false
        }
        let capability = await HelperClient.shared.capability(operation)
        if id == "homeServer", !capability.supported {
            optionalUnsupported.insert(id)
            lastEnablementReason[id] =
                "Restart after power loss is unavailable on this Mac. The AC hold and login relaunch still work."
            return true
        }
        let decision = ProtectedComponentPolicy.gate(
            componentID: id, reachable: true,
            supported: capability.supported, supportReason: capability.reason)
        guard decision.allowed else { refuse(id, decision.reason); return false }
        optionalUnsupported.remove(id)
        lastEnablementReason.removeValue(forKey: id)
        return true
    }

    // MARK: Session application

    /// Apply the enabled protected components that belong to a session, in policy
    /// order, each in its own task so one refusal cannot block the rest.
    func sessionDidStart() {
        // Tick retries are not new epochs. Only restoration/shutdown invalidates
        // outstanding writes; capture before bootstrap can suspend.
        let generation = sessionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.bootstrap()
            guard generation == self.sessionGeneration,
                  PowerEngine.shared.isArmed, PowerEngine.shared.lidClosed else { return }
            let engine = PowerEngine.shared
            let steps = ProtectedComponentPolicy.pendingSessionPlan(
                enabled: ComponentEngine.shared.enabledIDs,
                applied: self.applied,
                onBattery: engine.onBattery(),
                externalDisplay: DisplayTopology.hasExternalDisplay)
            self.apply(steps: steps)
        }
    }

    /// Persistent settings are applied while their component is enabled, not only
    /// during a closed session.
    func applyPersistent() {
        apply(steps: ProtectedComponentPolicy.persistentPlan(enabled: ComponentEngine.shared.enabledIDs))
    }

    private func apply(steps: [ProtectedComponentPolicy.Step]) {
        guard !shuttingDown else { return }
        var previous: Task<Void, Never>?
        for step in steps {
            let id = step.componentID
            guard !applied.contains(id), !applying.contains(id), !restoring.contains(id),
                  pendingReconciliation[id] == nil, !optionalUnsupported.contains(id) else { continue }
            if let retry = retryAfter[id], retry > Date() { continue }
            applying.insert(id)
            let generation = sessionGeneration
            let prior = previous
            let task = Task { @MainActor [weak self] in
                // Preserve policy order without letting one failure block the
                // rest: every task records its own failure and returns Void.
                await prior?.value
                guard let self else { return }
                defer { self.applying.remove(id) }
                guard !self.shuttingDown, ComponentEngine.shared.isEnabled(id), !self.applied.contains(id) else { return }
                if id == "homeServer" {
                    let capability = await HelperClient.shared.capability(.autoRestartAfterPowerLoss)
                    guard capability.supported else {
                        self.optionalUnsupported.insert(id)
                        self.lastEnablementReason[id] = "Restart after power loss is unavailable on this Mac. The AC hold and login relaunch still work."
                        return
                    }
                }
                guard await HelperClient.shared.isReachable() else {
                    self.fail(id, "the privileged helper is not reachable; nothing was applied",
                              retryAfter: 60)
                    return
                }
                let persistent = ProtectedComponentPolicy.scope(of: id) == .persistent
                guard ProtectedApplyLifetime.wanted(
                    enabled: ComponentEngine.shared.isEnabled(id), persistent: persistent,
                    shuttingDown: self.shuttingDown, armed: PowerEngine.shared.isArmed,
                    lidClosed: PowerEngine.shared.lidClosed, requestedEpoch: generation,
                    currentEpoch: self.sessionGeneration) else { return }
                let receipt = await self.perform(step)
                guard receipt.reply.ok else {
                    self.fail(id, receipt.reply.message, retryAfter: 60)
                    self.pendingReconciliation[id] = ProtectedPendingRecovery(
                        requestID: receipt.requestID,
                        transportUncertain: receipt.reply.details["transportUncertain"] == "yes")
                    self.persistPendingReconciliation()
                    await self.reconcileFailedApplications()
                    self.startReconciliationIfNeeded()
                    return
                }
                // A confirmed write owns recovery even if its immediate rollback
                // fails. Never drop the lease simply because it is no longer wanted.
                self.applied.insert(id)
                let stillWanted = ProtectedApplyLifetime.wanted(
                    enabled: ComponentEngine.shared.isEnabled(id), persistent: persistent,
                    shuttingDown: self.shuttingDown, armed: PowerEngine.shared.isArmed,
                    lidClosed: PowerEngine.shared.lidClosed, requestedEpoch: generation,
                    currentEpoch: self.sessionGeneration)
                guard stillWanted else {
                    // Disabled or the session ended while the request was in
                    // flight. Put it back instead of claiming it is applied.
                    let rollback = await self.api.restore(component: id)
                    if rollback.reply.ok { self.applied.remove(id) }
                    else { self.fail(id, rollback.reply.message, retryAfter: 60) }
                    return
                }
                if ProtectedRecoveryPolicy.fanForcedAfterInitialApply(componentID: id,
                                                                      replyOK: receipt.reply.ok),
                   generation == self.sessionGeneration {
                    self.fanForced = true
                    self.startFanGovernorIfNeeded()
                }
                self.retryAfter.removeValue(forKey: id)
                self.lastEnablementReason.removeValue(forKey: id)
                Diagnostics.log("protected component \(id) applied")
            }
            previous = task
        }
    }

    private func perform(_ step: ProtectedComponentPolicy.Step) async -> HelperRequestReceipt {
        switch step.action {
        case .lowPowerOn:
            return await api.setLowPowerMode(true)
        case .suppressWakeSources:
            return await api.suppressWakeSources()
        case .fanPercent:
            let raw = UserDefaults.standard.object(forKey: "fanBoost.percent") as? Int
            return await setFanPercentTracked(ProtectedComponentPolicy.fanPercent(from: raw))
        case .touchIDOff:
            return await api.setTouchIDUnlock(false)
        case .autoRestartOn:
            return await api.setAutoRestart(true)
        case .bootOnLidOpenOff:
            return await api.setBootOnLidOpen(false)
        }
    }

    // MARK: Password After Close (narrow, close-time path)

    func hasApplied(_ id: String) -> Bool { applied.contains(id) }

    /// Apply only the close-time Touch ID change. This deliberately does not
    /// require an armed session: Password After Close is a security action on
    /// the close itself. It still respects the shutdown flag, the `applied` /
    /// `applying` / `restoring` interlocks and the failed-request ledger, so it
    /// cannot race the armed-session apply path or report a write that never
    /// landed.
    func passwordAfterCloseDidClose() async -> PasswordAfterCloseOutcome {
        let id = "passwordAfterClose"
        guard ComponentEngine.shared.isEnabled(id), !shuttingDown else { return .unavailable }
        if applied.contains(id) { return .alreadyApplied }
        guard !applying.contains(id), !restoring.contains(id),
              pendingReconciliation[id] == nil else { return .unavailable }
        if let retry = retryAfter[id], retry > Date() { return .unavailable }

        applying.insert(id)
        defer { applying.remove(id) }
        guard await HelperClient.shared.isReachable() else {
            fail(id, "the privileged helper is not reachable; nothing was applied", retryAfter: 60)
            return .unavailable
        }
        guard !shuttingDown, ComponentEngine.shared.isEnabled(id) else { return .unavailable }

        let step = ProtectedComponentPolicy.Step(componentID: id, action: .touchIDOff,
                                              needsBattery: false, needsNoExternalDisplay: true)
        let receipt = await perform(step)
        guard receipt.reply.ok else {
            fail(id, receipt.reply.message, retryAfter: 60)
            pendingReconciliation[id] = ProtectedPendingRecovery(
                requestID: receipt.requestID,
                transportUncertain: receipt.reply.details["transportUncertain"] == "yes")
            persistPendingReconciliation()
            await reconcileFailedApplications()
            startReconciliationIfNeeded()
            return .failed(receipt.reply.message)
        }

        // Disabled or quitting while the write was queued: put it back now
        // instead of leaving an unowned Touch ID change behind.
        guard !shuttingDown, ComponentEngine.shared.isEnabled(id) else {
            let rollback = await api.restore(component: id)
            if !rollback.reply.ok {
                applied.insert(id)
                fail(id, rollback.reply.message, retryAfter: 60)
                pendingReconciliation[id] = ProtectedPendingRecovery(
                    requestID: rollback.requestID,
                    transportUncertain: rollback.reply.details["transportUncertain"] == "yes")
                persistPendingReconciliation()
                startReconciliationIfNeeded()
            }
            return .unavailable
        }

        applied.insert(id)
        retryAfter.removeValue(forKey: id)
        lastEnablementReason.removeValue(forKey: id)
        Diagnostics.log("protected component \(id) applied")
        return .applied
    }

    /// Restore only the Password After Close lease, and report the real outcome
    /// so the controller knows whether the persisted phase is settled. It uses
    /// the shared `restoring` ledger, which also lets the termination drain wait
    /// for a quit-time restore without a second mechanism.
    func passwordAfterCloseRestore() async -> PasswordAfterCloseRestoreOutcome {
        let id = "passwordAfterClose"
        guard applied.contains(id) else { return .nothingApplied }
        guard !restoring.contains(id), !applying.contains(id) else { return .busy }
        restoring.insert(id)
        defer { restoring.remove(id) }

        let receipt = await api.restore(component: id)
        if receipt.reply.ok {
            applied.remove(id)
            retryAfter.removeValue(forKey: id)
            Diagnostics.log("protected component \(id) restored (password after close)")
            return .restored
        }
        fail(id, receipt.reply.message, retryAfter: 60)
        return .failed(receipt.reply.message)
    }

    /// Registers the fan request UUID before the XPC call can suspend, so the
    /// termination drain sees it. A definitive answer resolves it; a
    /// transport-uncertain failure stays unresolved and blocks a "restored"
    /// verdict.
    private func setFanPercentTracked(_ percent: Int) async -> HelperRequestReceipt {
        let requestID = UUID()
        fanInFlight[requestID] = sessionGeneration
        let receipt = await api.setFanPercent(percent, requestID: requestID)
        if receipt.reply.ok || receipt.reply.details["transportUncertain"] != "yes" {
            fanInFlight.removeValue(forKey: requestID)
        }
        return receipt
    }

    // MARK: Fan governor

    /// OSS workload governor; its thresholds and timing are NOT yet traced to
    /// the earlier implementation. Initial application currently precedes this task, so this
    /// governor does not gate the first forced target. Preserve until the
    /// full trigger/restore chain is established.
    private func startFanGovernorIfNeeded() {
        guard !shuttingDown, fanGovernor == nil,
              ComponentEngine.shared.isEnabled("fanBoost"),
              case .installed = HelperClient.shared.installState else { return }
        fanGovernor = Task { @MainActor [weak self] in
            var busySamples = 0
            var idleSamples = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                guard let self, !self.shuttingDown else { break }
                guard PowerEngine.shared.isArmed, PowerEngine.shared.lidClosed,
                      ComponentEngine.shared.isEnabled("fanBoost") else { break }
                if WorkloadSampler.isBusy() {
                    busySamples += 1
                    idleSamples = 0
                } else {
                    idleSamples += 1
                    busySamples = 0
                }
                if busySamples >= 2, !self.fanForced {
                    let raw = UserDefaults.standard.object(forKey: "fanBoost.percent") as? Int
                    let percent = ProtectedComponentPolicy.fanPercent(from: raw)
                    let generation = self.sessionGeneration
                    let receipt = await self.setFanPercentTracked(percent)
                    guard generation == self.sessionGeneration else { continue }
                    if receipt.reply.ok {
                        self.fanForced = true
                        Diagnostics.log("fan governor: working, forcing \(percent)%")
                    } else {
                        Diagnostics.log("fan governor failed: \(receipt.reply.message)")
                        busySamples = 0
                    }
                } else if idleSamples >= 3, self.fanForced {
                    let generation = self.sessionGeneration
                    let receipt = await self.setFanPercentTracked(0)
                    guard generation == self.sessionGeneration else { continue }
                    if receipt.reply.ok {
                        self.fanForced = false
                        Diagnostics.log("fan governor: resting, automatic control")
                    } else {
                        Diagnostics.log("fan governor restore failed: \(receipt.reply.message)")
                        idleSamples = 0
                    }
                }
            }
            self?.fanGovernor = nil
        }
    }

    /// Cancels the loop but deliberately keeps `fanInFlight`: cancelling a
    /// task does not cancel a root helper write already queued behind XPC.
    private func stopFanGovernor() {
        fanGovernor?.cancel()
        fanGovernor = nil
        fanForced = false
    }

    // MARK: Restoration

    func restore(component id: String, reason: String) {
        // Invalidate even a write still in flight (not yet in applied).
        if id == "fanBoost" { stopFanGovernor() }
        restore(ids: [id], reason: reason)
    }

    /// Session-scoped settings only. Persistent components survive a session end.
    /// Password After Close is excluded by its callers on lid open/session end:
    /// it must not restore while the screen is still locked, and the controller
    /// owns its triggers.
    func restoreSessionScoped(reason: String, excluding: Set<String> = []) {
        restore(ids: ProtectedComponentPolicy.restorePlan(applied: applied, limit: .session)
                    .filter { !excluding.contains($0) },
                reason: reason)
    }

    /// Every applied protected setting. Used when the helper is being removed;
    /// persistent components are intentionally not restored on an ordinary quit.
    func restoreAll(reason: String) {
        restore(ids: ProtectedComponentPolicy.restorePlan(applied: applied), reason: reason)
    }

    private func restore(ids: [String], reason: String) {
        // Restoration ends the epoch in which fan replies were authoritative.
        sessionGeneration += 1
        var previous: Task<Void, Never>?
        for id in ids {
            guard applied.contains(id), !restoring.contains(id) else { continue }
            restoring.insert(id)
            let prior = previous
            let task = Task { @MainActor [weak self] in
                await prior?.value
                guard let self else { return }
                defer { self.restoring.remove(id) }
                let receipt = await self.api.restore(component: id)
                if receipt.reply.ok {
                    self.applied.remove(id)
                    self.retryAfter.removeValue(forKey: id)
                    Diagnostics.log("protected component \(id) restored (\(reason))")
                } else {
                    // Keep it in `applied`: the setting is still in place, and a
                    // later open/quit retries rather than pretending it is back.
                    self.fail(id, receipt.reply.message, retryAfter: 300)
                }
            }
            previous = task
        }
    }

    // MARK: Failed-application recovery

    /// v2 is the only format written from now on. Writing it also removes the
    /// v1 array so a migrated entry cannot be re-read as a resolved component.
    private func persistPendingReconciliation() {
        guard let data = try? JSONEncoder().encode(pendingReconciliation) else { return }
        UserDefaults.standard.set(data, forKey: Self.reconciliationKeyV2)
        UserDefaults.standard.removeObject(forKey: Self.reconciliationKey)
    }

    private func reconcileFailedApplications() async {
        guard !pendingReconciliation.isEmpty else { return }
        let pending = pendingReconciliation
        // Probe capability once per pass. A missing or failed answer is not
        // protocol 2, so those records keep the status-lease path.
        let authoritative = await HelperClient.shared.supportsAuthoritativeRequests()
        // Status remains the fallback evidence for legacy records and for a
        // journal answer of `.unknown`.
        let reply = await HelperClient.shared.perform(HelperRequest(operation: .status))
        let leases = ProtectedComponentPolicy.leases(details: reply.details)
        let hasLeaseReport = reply.details["leases"] != nil
        for (id, record) in pending {
            // A newer attempt may have replaced this record during the probe.
            guard pendingReconciliation[id] == record else { continue }
            let outcome: HelperRequestOutcome?
            if authoritative, let requestID = record.requestID {
                outcome = await HelperClient.shared.requestOutcome(requestID)
            } else {
                outcome = nil
            }
            // Re-check after the journal round trip; never settle a record that
            // a concurrent apply has already replaced.
            guard pendingReconciliation[id] == record else { continue }
            let decision = ProtectedRecoveryPolicy.decision(
                outcome: outcome,
                transportUncertain: record.transportUncertain,
                statusOK: reply.ok,
                hasLeaseReport: hasLeaseReport,
                reportsComponentLease: leases.contains(id))
            switch decision {
            case .retryProbe:
                break
            case .settledWithoutLease:
                pendingReconciliation.removeValue(forKey: id)
                if let requestID = record.requestID { fanInFlight.removeValue(forKey: requestID) }
                persistPendingReconciliation()
            case .adoptLease:
                // A lease proves a recovery record, not successful application.
                // Failed application is rolled back even if the session remains on.
                applied.insert(id)
                pendingReconciliation.removeValue(forKey: id)
                if let requestID = record.requestID { fanInFlight.removeValue(forKey: requestID) }
                persistPendingReconciliation()
                restore(ids: [id], reason: "recovering a failed or timed-out helper application")
            }
        }
    }

    private func startReconciliationIfNeeded() {
        guard reconciliationTask == nil, !pendingReconciliation.isEmpty else { return }
        reconciliationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                guard let self, !self.pendingReconciliation.isEmpty else { break }
                await self.reconcileFailedApplications()
            }
            self?.reconciliationTask = nil
        }
    }

    // MARK: Crash recovery

    /// Probe the helper once for saved leases. A still-enabled lease is adopted
    /// (so it is restored later); a lease whose component was disabled in the
    /// meantime is restored now. An unreachable helper is retried on the next
    /// session rather than treated as success.
    func bootstrap() async {
        await reconcileFailedApplications()
        startReconciliationIfNeeded()
        if probeFinished { return }
        if let task = probeTask { await task.value; return }
        if let next = nextProbeAfter, next > Date() { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            // `restoreAll` is an action, not a probe: it would put back settings
            // the user may have deliberately changed outside Wakely. Status
            // reports the saved leases without changing anything.
            guard await HelperClient.shared.isReachable() else {
                self.nextProbeAfter = Date().addingTimeInterval(60)
                return
            }
            let reply = await HelperClient.shared.perform(HelperRequest(operation: .status))
            guard reply.ok else {
                self.fail("status", reply.message, retryAfter: 60)
                self.nextProbeAfter = Date().addingTimeInterval(60)
                return
            }
            self.probeFinished = true
            let reported = ProtectedComponentPolicy.leases(details: reply.details)
            for id in reported { self.applied.insert(id) }
            let stale = ProtectedComponentPolicy.staleLeases(
                reported: reported, enabled: ComponentEngine.shared.enabledIDs)
            self.restore(ids: stale, reason: "a saved helper lease outlived its component")
            self.applyPersistent()
        }
        probeTask = task
        await task.value
        probeTask = nil
    }

    /// Call before the helper is removed: persistent settings go back too.
    func helperWillUninstall() { restoreAll(reason: "the privileged helper is being removed") }

    /// Delete Wakely: put back every applied setting, persistent ones included,
    /// and report whether all of them really went back before the deadline.
    func restoreEverythingBeforeDelete(timeout: TimeInterval) async -> Bool {
        restoreAll(reason: "Wakely is being deleted")
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while !restoring.isEmpty || !applying.isEmpty {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
        }
        return applied.isEmpty
    }

    // MARK: Failure recording

    func recordRefusal(_ id: String, _ reason: String) { refuse(id, reason) }

    private func refuse(_ id: String, _ reason: String) {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = text.isEmpty ? "the privileged helper refused without a reason" : text
        lastEnablementReason[id] = detail
        Diagnostics.log("component \(id) cannot be enabled: \(detail)")
    }

    private func fail(_ id: String, _ message: String, retryAfter delay: TimeInterval) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = text.isEmpty ? "the privileged helper refused without a reason" : text
        lastEnablementReason[id] = detail
        retryAfter[id] = Date().addingTimeInterval(delay)
        Diagnostics.log("protected component \(id) failed: \(detail)")
    }

    private static func operation(named name: String) -> HelperOperation? {
        switch name {
        case "lowPowerMode": return .lowPowerMode
        case "suppressWakeSources": return .suppressWakeSources
        case "fanPercent": return .fanPercent
        case "touchIDUnlock": return .touchIDUnlock
        case "bootOnLidOpen": return .bootOnLidOpen
        case "autoRestartAfterPowerLoss": return .autoRestartAfterPowerLoss
        default: return nil
        }
    }
}

// MARK: - Small system helpers

/// Whether the finished or waiting agent's own app (or the terminal hosting it)
/// is already in front. Suppression errs toward silence only when it cannot
/// prove the agent lives somewhere else: a missed match posts a notice, it never
/// hides one for an unrelated app.
enum AgentPresence {
    /// Apps that can host a CLI agent. Not exhaustive: an unlisted terminal just
    /// means the decision relies on process ancestry.
    static let hostBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "com.github.wez.wezterm", "net.kovidgoyal.kitty",
        "io.alacritty", "com.panic.Prompt", "co.zeit.hyper", "org.tabby",
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
        "dev.zed.Zed", "com.apple.dt.Xcode", "com.jetbrains.intellij", "com.jetbrains.pycharm"
    ]

    @MainActor
    static func isFrontmost(thread: AgentThread) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let chain = ancestors(of: thread.pid)
        if chain.pids.contains(front.processIdentifier) { return true }
        // A complete chain that does not include the front app means this agent
        // lives elsewhere: let the notification through.
        if chain.complete { return false }
        // The process is gone or sysctl failed and a known terminal/editor is in
        // front. That is the closest safe inference, and suppression is quiet.
        return hostBundleIDs.contains(front.bundleIdentifier ?? "")
    }

    /// Parent pids above this one, stopping before launchd. `complete` says the
    /// walk reached launchd rather than failing early.
    static func ancestors(of pid: Int32) -> (pids: [Int32], complete: Bool) {
        var pids: [Int32] = []
        var current = pid
        for _ in 0..<16 {
            guard let parent = parentPID(current) else { return (pids, false) }
            if parent <= 1 || pids.contains(parent) { return (pids, true) }
            pids.append(parent)
            current = parent
        }
        return (pids, false)
    }

    private static func parentPID(_ pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

enum Audio {
    private static func defaultOutput() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    struct MuteSnapshot {
        let device: AudioDeviceID
        let muted: Bool
    }

    static func muteSnapshot() -> MuteSnapshot? {
        let device = defaultOutput()
        guard device != 0 else { return nil }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else { return nil }
        return MuteSnapshot(device: device, muted: muted != 0)
    }

    static func isMuted() -> Bool? { muteSnapshot()?.muted }

    @discardableResult
    static func setMuted(_ muted: Bool, device: AudioDeviceID) -> Bool {
        var value = UInt32(muted ? 1 : 0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    private static var fadeTimer: Timer?
    private static var fadeOriginalVolume: Float?
    private static var fadeDevice: AudioDeviceID?

    static func volume(device: AudioDeviceID? = nil) -> Float? {
        let device = device ?? defaultOutput()
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setVolume(_ value: Float, device: AudioDeviceID? = nil) -> Bool {
        let device = device ?? defaultOutput()
        var value = max(0, min(1, value))
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &value) == noErr
    }

    @MainActor
    static func cancelFade(restore: Bool = true) {
        fadeTimer?.invalidate(); fadeTimer = nil
        if restore, let value = fadeOriginalVolume, let device = fadeDevice { _ = setVolume(value, device: device) }
        fadeOriginalVolume = nil; fadeDevice = nil
    }

    @MainActor
    static func fadeOut(seconds: Double) {
        guard fadeTimer == nil else { return }
        let device = defaultOutput()
        guard let original = volume(device: device) else {
            Diagnostics.log("sleep timer fade unavailable: output device has no writable main volume")
            return
        }
        fadeDevice = device; fadeOriginalVolume = original
        let start = Date()
        let duration = max(0.1, seconds)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            let progress = min(1, Date().timeIntervalSince(start) / duration)
            _ = setVolume(original * Float(1 - progress), device: device)
            if progress >= 1 { timer.invalidate() }
        }
        if let fadeTimer { RunLoop.main.add(fadeTimer, forMode: .common) }
    }

}

enum Bluetooth {
    private typealias SetPowerFn = @convention(c) (Int32) -> Int32
    private typealias GetPowerFn = @convention(c) () -> Int32
    private static let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW)

    private static let setPowerFn: SetPowerFn? = {
        guard let handle, let sym = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else { return nil }
        return unsafeBitCast(sym, to: SetPowerFn.self)
    }()
    private static let getPowerFn: GetPowerFn? = {
        guard let handle, let sym = dlsym(handle, "IOBluetoothPreferenceGetControllerPowerState") else { return nil }
        return unsafeBitCast(sym, to: GetPowerFn.self)
    }()

    static func powerState() -> Bool? {
        guard let value = getPowerFn?(), value == 0 || value == 1 else { return nil }
        return value == 1
    }
    static func isOn() -> Bool { powerState() ?? false }
    /// False when the private framework symbol is missing, so callers can say
    /// "unavailable" instead of pretending a request changed the radio.
    static var isControllable: Bool { setPowerFn != nil && getPowerFn != nil }
    /// A request, not a verified state change: the legacy IOBluetooth
    /// preference call has no completion we can read back.
    static func setPower(_ on: Bool) { _ = setPowerFn?(on ? 1 : 0) }
}

enum CapsLock {
    @MainActor static func isOn() -> Bool { CapsLockLight.isLit }
}

enum SSH {
    /// Remote server activity, not local terminal windows or outgoing SSH clients.
    static func activeSessions() -> Int {
        let text = CommandRead.cached("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-Fpc"])
        var count = 0
        for line in text.split(separator: "\n") where line.hasPrefix("c") {
            let command = String(line.dropFirst()).lowercased()
            if command.hasPrefix("sshd") || command.contains("screensharing") || command == "ardagent" { count += 1 }
        }
        // who supplies remote PTY sessions even if lsof cannot see server PIDs.
        let who = CommandRead.cached("/usr/bin/who", [])
        let remote = who.split(separator: "\n").filter { line in
            line.contains("(") && !line.contains("console") && !line.contains("(:0)")
        }.count
        return max(count, remote)
    }
}

enum WorkProcesses {
    /// Snapshot known transfer/backup/render processes, plus explicitly selected
    /// apps. This does not pretend arbitrary background network bytes are jobs.
    static func currentIDs() -> Set<String> {
        let known: Set<String> = ["curl", "wget", "rsync", "scp", "sftp", "backupd", "aria2c", "ffmpeg", "handbrakecli", "ditto"]
        let text = CommandRead.cached("/bin/ps", ["-axo", "pid=,comm="])
        var ids: Set<String> = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, known.contains(URL(fileURLWithPath: String(parts[1])).lastPathComponent.lowercased()) { ids.insert(String(parts[0])) }
        }
        let selected = Set(UserDefaults.standard.stringArray(forKey: "finishJobsThenSleep.bundleIDs") ?? [])
        for app in NSWorkspace.shared.runningApplications where selected.contains(app.bundleIdentifier ?? "") { ids.insert(String(app.processIdentifier)) }
        return ids
    }
}

enum CommandRead {
    private static let lock = NSLock()
    private static var cachedValues: [String: (String, Date)] = [:]
    private static var pending: Set<String> = []

    static func cached(_ path: String, _ arguments: [String]) -> String {
        let key = path + arguments.joined(separator: "\u{0}")
        lock.lock()
        let cached = cachedValues[key]
        let shouldRefresh = !pending.contains(key) && (cached == nil || Date().timeIntervalSince(cached!.1) >= 2)
        if shouldRefresh { pending.insert(key) }
        lock.unlock()
        if shouldRefresh {
            DispatchQueue.global(qos: .utility).async {
                let value = output(path, arguments)
                lock.lock(); cachedValues[key] = (value, Date()); pending.remove(key); lock.unlock()
            }
        }
        return cached?.0 ?? ""
    }

    static func output(_ path: String, _ arguments: [String]) -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum DisplayTopology {
    static var hasExternalDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

enum Network {
    private static var lastTotal: UInt64 = 0
    private static var lastCheck = Date.distantPast

    static func totalBytes() -> UInt64 {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return 0 }
        defer { freeifaddrs(ifaddr) }
        var total: UInt64 = 0
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let interface = current.pointee
            if let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
               let data = interface.ifa_data {
                let stats = data.assumingMemoryBound(to: if_data.self)
                total += UInt64(stats.pointee.ifi_ibytes) + UInt64(stats.pointee.ifi_obytes)
            }
            pointer = interface.ifa_next
        }
        return total
    }

    static func busy() -> Bool {
        let now = totalBytes()
        defer { lastTotal = now; lastCheck = Date() }
        guard lastTotal > 0, now >= lastTotal else { return false }
        return now - lastTotal > 256 * 1024
    }
}

enum Volumes {
    static func external() -> [URL] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsInternalKey, .volumeIsLocalKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.filter {
            guard let values = try? $0.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]) else { return false }
            return values.volumeIsInternal == false && values.volumeIsLocal == true
        }
    }

    static func identifier(_ url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey])
        return values?.volumeUUIDString ?? url.standardizedFileURL.path
    }

    static func ejectAll() -> [String] {
        var failed: [String] = []
        for url in external() {
            do { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
            catch { failed.append(url.lastPathComponent) }
        }
        return failed
    }

    /// A mounted external volume, resolved off the main actor because asking a
    /// stalled drive for its resource values can block on I/O.
    struct EjectCandidate: Sendable {
        let url: URL
        let name: String
    }

    /// Read-only enumeration. Never unmounts anything and never touches the
    /// selected drive that another component is holding a session for.
    static func ejectCandidates(excluding selectedIDs: Set<String>) -> [EjectCandidate] {
        external().compactMap { url in
            let id = identifier(url) ?? url.standardizedFileURL.path
            guard !selectedIDs.contains(id) else { return nil }
            return EjectCandidate(url: url, name: url.lastPathComponent)
        }
    }

    /// Runs only from the real system-sleep handshake. Every blocking step
    /// (tmutil, mount enumeration, unmount) happens off the main actor, and the
    /// session conditions are re-checked before each drive is touched.
    @MainActor
    private static let ejectedNamesKey = "ejectOnSleep.ejectedNames"

    /// Volume names ejected for this sleep, so a wake can mount them again.
    static func rememberEjected(_ name: String) {
        var names = UserDefaults.standard.stringArray(forKey: ejectedNamesKey) ?? []
        if !names.contains(name) { names.append(name) }
        UserDefaults.standard.set(names, forKey: ejectedNamesKey)
    }

    /// Mounts the drives back when the component is set to "Drives come back".
    /// Never runs when the user chose "Stay ejected".
    static func remountEjectedIfWanted() {
        let wantsRemount = UserDefaults.standard.object(forKey: "ejectOnSleep.remount") as? Bool ?? true
        let names = UserDefaults.standard.stringArray(forKey: ejectedNamesKey) ?? []
        guard !names.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: ejectedNamesKey)
        guard wantsRemount else {
            Diagnostics.log("eject on sleep: \(names.count) drive(s) stay ejected by choice")
            return
        }
        Task.detached(priority: .utility) {
            for name in names {
                // diskutil mounts by volume name; a failure is reported by the
                // tool's exit status and leaves the drive to Finder.
                let result = CommandRead.output("/usr/sbin/diskutil", ["mount", name])
                Diagnostics.log("remount \(name): \(result.isEmpty ? "ok" : result)")
            }
        }
    }

    static func ejectForSleep(excluding selectedIDs: Set<String>) async -> [String] {
        let candidates = await Task.detached(priority: .utility) {
            ejectCandidates(excluding: selectedIDs)
        }.value
        guard !candidates.isEmpty else { return [] }
        // Unknown Time Machine status is deliberately fail-closed: a status we
        // could not read is not evidence that no backup is running.
        let statusText = await Task.detached(priority: .utility) {
            CommandRead.output("/usr/bin/tmutil", ["status"])
        }.value
        guard TimeMachineStatus.isDefinitelyIdle(statusText) else {
            Diagnostics.log("eject on sleep skipped: Time Machine running or status unavailable")
            return []
        }
        var failed: [String] = []
        for candidate in candidates {
            // Session state is main-actor owned; read it there once per drive.
            let (armed, lidClosed, external, enabled) = await MainActor.run {
                (PowerEngine.shared.isArmed, PowerEngine.shared.lidClosed,
                 DisplayTopology.hasExternalDisplay, ComponentEngine.shared.isEnabled("ejectOnSleep"))
            }
            guard !Task.isCancelled, enabled, !armed, lidClosed, !external else {
                Diagnostics.log("eject on sleep stopped: session state changed")
                break
            }
            let ok = await Task.detached(priority: .utility) { () -> Bool in
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: candidate.url); return true }
                catch { return false }
            }.value
            if ok {
                Diagnostics.log("ejected \(candidate.name) for sleep")
                Volumes.rememberEjected(candidate.name)
            } else {
                failed.append(candidate.name)
            }
        }
        return failed
    }

}

enum WiFi {
    static func currentSSID() -> String? {
        // Nil means unavailable (including missing Location permission), never a
        // made-up network. The 60s grace tolerates transient missing samples.
        CWWiFiClient.shared().interface()?.ssid()
    }
}

enum Shortcuts {
    static func run(named name: String) {
        guard !name.isEmpty else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        Diagnostics.log("ran shortcut \(name)")
    }
}

enum Schedule {
    static func insideWindow(start: String, end: String) -> Bool {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: Date())
        let now = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        func parse(_ s: String) -> Double? {
            let p = s.split(separator: ":")
            guard p.count == 2, let h = Double(p[0]), let m = Double(p[1]) else { return nil }
            return h * 60 + m
        }
        guard let a = parse(start), let b = parse(end) else { return false }
        return a <= b ? (now >= a && now < b) : (now >= a || now < b)
    }
}

enum System {
    @discardableResult
    static func sleep() -> Bool {
        // Public IOKit API accepts the console user. Avoid an Apple Events
        // permission dependency on System Events just to request system sleep.
        let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard connection != 0 else {
            Diagnostics.log("sleep request failed: power management connection unavailable")
            return false
        }
        defer { IOServiceClose(connection) }
        let result = IOPMSleepSystem(connection)
        guard result == kIOReturnSuccess else {
            Diagnostics.log("sleep request refused by macOS: \(result)")
            return false
        }
        return true // Request accepted, not proof that the Mac actually slept.
    }
}

// BEGIN TESTABLE PROTECTED POLICY
//
// Pure policy for the privileged protected components: no AppKit, IOKit, XPC,
// HelperClient or UserDefaults. Tests extract this block, compile it on its own
// and exercise ordering, idempotence and the capability gate.

enum ProtectedComponentPolicy {
    enum Scope: String, Equatable {
        case session
        case persistent
    }

    enum Action: Equatable {
        case lowPowerOn
        case suppressWakeSources
        case fanPercent
        case touchIDOff
        case autoRestartOn
        case bootOnLidOpenOff
    }

    struct Step: Equatable {
        let componentID: String
        let action: Action
        let needsBattery: Bool
        let needsNoExternalDisplay: Bool
    }

    struct GateDecision: Equatable {
        let allowed: Bool
        let reason: String
    }

    /// Fixed application order. Restoration walks it backwards.
    static let orderedSteps: [Step] = [
        Step(componentID: "lowPowerWhileClosed", action: .lowPowerOn,
             needsBattery: true, needsNoExternalDisplay: false),
        Step(componentID: "sleepMeansSleep", action: .suppressWakeSources,
             needsBattery: false, needsNoExternalDisplay: false),
        Step(componentID: "fanBoost", action: .fanPercent,
             needsBattery: false, needsNoExternalDisplay: false),
        Step(componentID: "passwordAfterClose", action: .touchIDOff,
             needsBattery: false, needsNoExternalDisplay: true),
        Step(componentID: "homeServer", action: .autoRestartOn,
             needsBattery: false, needsNoExternalDisplay: false),
        Step(componentID: "stayOffWhenOpened", action: .bootOnLidOpenOff,
             needsBattery: false, needsNoExternalDisplay: false)
    ]

    static let sessionScoped: Set<String> = [
        "lowPowerWhileClosed", "fanBoost", "passwordAfterClose"
    ]
    static let persistent: Set<String> = ["homeServer", "stayOffWhenOpened", "sleepMeansSleep"]

    static var componentIDs: Set<String> { Set(orderedSteps.map(\.componentID)) }

    static func scope(of componentID: String) -> Scope? {
        if sessionScoped.contains(componentID) { return .session }
        if persistent.contains(componentID) { return .persistent }
        return nil
    }

    static func isProtected(_ componentID: String) -> Bool { scope(of: componentID) != nil }

    /// Helper operation names, kept as strings so this block stays free of the
    /// helper client and its XPC types.
    static func operation(for componentID: String) -> String? {
        switch componentID {
        case "lowPowerWhileClosed": return "lowPowerMode"
        case "sleepMeansSleep": return "suppressWakeSources"
        case "fanBoost": return "fanPercent"
        case "passwordAfterClose": return "touchIDUnlock"
        case "homeServer": return "autoRestartAfterPowerLoss"
        case "stayOffWhenOpened": return "bootOnLidOpen"
        default: return nil
        }
    }

    /// 0 means automatic in the helper, which is not a boost; the enabled component
    /// therefore clamps to 1...100 and defaults to 100.
    /// The earlier implementation's `HelperSMC.fanSpeedPercents` is `30...100`: it never asks
    /// for less than 30% of a fan's maximum. Decompiled from
    /// the earlier helper's `get_fanSpeedPercents`.
    static let fanPercentRange = 30...100

    static func fanPercent(from raw: Int?) -> Int {
        min(fanPercentRange.upperBound, max(fanPercentRange.lowerBound, raw ?? 100))
    }

    static func sessionPlan(enabled: Set<String>, onBattery: Bool, externalDisplay: Bool) -> [Step] {
        orderedSteps.filter { step in
            guard enabled.contains(step.componentID) else { return false }
            if step.needsBattery, !onBattery { return false }
            if step.needsNoExternalDisplay, externalDisplay { return false }
            return true
        }
    }

    static func pendingSessionPlan(enabled: Set<String>, applied: Set<String>,
                                   onBattery: Bool, externalDisplay: Bool) -> [Step] {
        sessionPlan(enabled: enabled, onBattery: onBattery, externalDisplay: externalDisplay)
            .filter { !applied.contains($0.componentID) }
    }

    static func persistentPlan(enabled: Set<String>) -> [Step] {
        orderedSteps.filter { persistent.contains($0.componentID) && enabled.contains($0.componentID) }
    }

    /// Reverse application order, restricted to what was actually applied.
    static func restorePlan(applied: Set<String>, limit: Scope? = nil) -> [String] {
        orderedSteps.reversed().compactMap { step in
            guard applied.contains(step.componentID) else { return nil }
            if let limit = limit, scope(of: step.componentID) != limit { return nil }
            return step.componentID
        }
    }

    /// Reads the component ids a helper `status` reply reports as having saved
    /// leases. Unknown ids are ignored; the result keeps application order.
    static func leases(details: [String: String]) -> [String] {
        var found: Set<String> = []
        for key in ["leases", "savedLeases", "saved.leases", "componentLeases",
                    "components", "savedComponents"] {
            guard let raw = details[key] else { continue }
            for piece in raw.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace }) {
                let id = String(piece)
                if isProtected(id) { found.insert(id) }
            }
        }
        for (key, value) in details where key.hasPrefix("lease.") {
            let id = String(key.dropFirst("lease.".count))
            if isProtected(id), truthy(value) { found.insert(id) }
        }
        return orderedSteps.map(\.componentID).filter { found.contains($0) }
    }

    static func staleLeases(reported: [String], enabled: Set<String>) -> [String] {
        orderedSteps.map(\.componentID).filter { reported.contains($0) && !enabled.contains($0) }
    }

    static func truthy(_ value: String) -> Bool {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "active", "supported", "enabled": return true
        default: return false
        }
    }

    /// A component is enabled only when the helper is reachable and reports the
    /// operation as supported. Non-protected components need no gate.
    static func gate(componentID: String, reachable: Bool, supported: Bool,
                     supportReason: String = "") -> GateDecision {
        guard isProtected(componentID) else { return GateDecision(allowed: true, reason: "") }
        guard reachable else {
            return GateDecision(
                allowed: false,
                reason: "the privileged helper is not reachable; install it and approve it before enabling this component")
        }
        guard supported else {
            let text = supportReason.trimmingCharacters(in: .whitespacesAndNewlines)
            return GateDecision(
                allowed: false,
                reason: text.isEmpty ? "the privileged helper does not support this operation" : text)
        }
        return GateDecision(allowed: true, reason: "")
    }

    /// In-memory ledger mirroring the runtime's `applied` set: `markApplied`
    /// returns false for a duplicate, and restore plans only name ids that were
    /// actually applied.
    struct Ledger {
        private(set) var applied: Set<String> = []

        init() {}

        mutating func markApplied(_ componentID: String) -> Bool {
            guard ProtectedComponentPolicy.isProtected(componentID) else { return false }
            return applied.insert(componentID).inserted
        }

        /// A lease from a previous run proves the helper performed the change.
        mutating func adopt(_ componentID: String) -> Bool { markApplied(componentID) }

        mutating func markRestored(_ componentID: String) -> Bool {
            applied.remove(componentID) != nil
        }

        func pending(enabled: Set<String>, onBattery: Bool, externalDisplay: Bool) -> [Step] {
            ProtectedComponentPolicy.pendingSessionPlan(
                enabled: enabled, applied: applied,
                onBattery: onBattery, externalDisplay: externalDisplay)
        }

        func restorePlan(limit: Scope? = nil) -> [String] {
            ProtectedComponentPolicy.restorePlan(applied: applied, limit: limit)
        }
    }
}
// END TESTABLE PROTECTED POLICY
