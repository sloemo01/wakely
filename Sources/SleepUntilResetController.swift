// SleepUntilResetController — M6b wiring for the Sleep Until Reset component.
//
// The controller is the only app-side owner of the feature:
//   * it reads reset instants from the local Claude Code / Codex transcripts,
//   * asks the privileged helper to own one wake per planned instant
//     (reset + 1 minute) and reconciles that set every 15 minutes,
//   * after a wake on AC it arms a persistent session whose source is
//     "sleep until reset", holds it while agents work (four-hour cap), and
//     ends it once the agents have been idle for the configured window or one
//     has been waiting for the user for the configured window,
//   * cancels only the wakes the helper records as owned by this component, on
//     lid open, component disable and quit.
//
// Nothing here schedules or cancels a wake itself: the app never runs pmset,
// never asks for root and never creates a system power event. It also never
// wakes a sleeping Mac — wakes are the helper's durable, verified events; this
// code only reacts after the system has already woken.
//
// Logging is counts and fixed reasons only. Account labels, transcript paths
// and message text never reach a log line.

import Foundation

@MainActor
final class SleepUntilResetController {
    static let shared = SleepUntilResetController()
    static let componentID = "sleepUntilReset"
    /// "Replan every 15 minutes" from the feature contract.
    static let replanInterval: TimeInterval = 15 * 60
    /// How often the stay-awake session re-reads the agent counts.
    static let evaluationInterval: TimeInterval = 20
    /// The helper refuses a wake less than 30 s ahead; skip a planned instant
    /// that has already slipped inside that window.
    static let minimumWakeLead: TimeInterval = 30
    /// One-second ownership match, the same tolerance the helper's wake store
    /// uses for cancel.
    static let ownershipTolerance: TimeInterval = 1

    private let helper: HelperComponentAPI
    private let reader: UsageResetReader
    private let now: @MainActor () -> Date
    private let isEnabled: @MainActor () -> Bool
    private let isLidClosed: @MainActor () -> Bool
    private let onBattery: @MainActor () -> Bool
    private let isArmed: @MainActor () -> Bool
    private let agentCounts: @MainActor () -> (working: Int, waiting: Int)
    private let reachable: @MainActor () async -> Bool
    private let arm: @MainActor () -> Bool
    private let disarm: @MainActor (String) -> Void
    private let requestSleep: @MainActor () -> Void
    private let diagnostics: @MainActor (String) -> Void

    private var replanTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var isReconciling = false
    private var sessionStartedAt: Date?
    private var lastWorkAt: Date?
    private var waitingSince: Date?
    /// True only when this controller actually started the arm, so a session
    /// another component (or the user) already held is never torn down by us.
    private var ownsSessionHold = false
    /// Instants this component has reconciled with the helper. A wake outside this
    /// window is not ours and must not start a session.
    private var plannedWakes: [Date] = []
    /// Invalidates every asynchronous continuation after disable/open/quit.
    private var lifecycleGeneration = 0
    /// nil means no plan has been reported yet, so the first empty read is
    /// still logged honestly.
    private var lastReportedPlanKey: String?
    /// Set by `didQuit()` so the component teardown that follows the quit path
    /// does not start a second cancellation with a misleading reason.
    private var isQuitting = false

    init(helper: HelperComponentAPI? = nil,
         reader: UsageResetReader = UsageResetReader(roots: .live()),
         now: @escaping @MainActor () -> Date = { Date() },
         isEnabled: @escaping @MainActor () -> Bool = {
             ComponentEngine.shared.isEnabled(SleepUntilResetController.componentID)
         },
         isLidClosed: @escaping @MainActor () -> Bool = { PowerEngine.shared.lidClosed },
         onBattery: @escaping @MainActor () -> Bool = { PowerEngine.shared.onBattery() },
         isArmed: @escaping @MainActor () -> Bool = { PowerEngine.shared.isArmed },
         agentCounts: @escaping @MainActor () -> (working: Int, waiting: Int) = {
             (AgentMonitor.shared.workingCount, AgentMonitor.shared.waitingCount)
         },
         reachable: @escaping @MainActor () async -> Bool = {
             await HelperClient.shared.isReachable()
         },
         arm: @escaping @MainActor () -> Bool = {
             PowerEngine.shared.requestAutomaticArm(owner: "sleepUntilReset",
                                                    source: "sleep until reset", lifetime: .persistent)
         },
         disarm: @escaping @MainActor (String) -> Void = { reason in
             PowerEngine.shared.releaseAutomaticArm(owner: "sleepUntilReset", reason: reason)
         },
         requestSleep: @escaping @MainActor () -> Void = { System.sleep() },
         diagnostics: @escaping @MainActor (String) -> Void = { Diagnostics.log($0) }) {
        self.helper = helper ?? HelperComponentAPI()
        self.reader = reader
        self.now = now
        self.isEnabled = isEnabled
        self.isLidClosed = isLidClosed
        self.onBattery = onBattery
        self.isArmed = isArmed
        self.agentCounts = agentCounts
        self.reachable = reachable
        self.arm = arm
        self.disarm = disarm
        self.requestSleep = requestSleep
        self.diagnostics = diagnostics
    }

    // MARK: - Component lifecycle

    /// The shared instance lives for the process, so this only matters for an
    /// instance a test or a future caller lets go: a sleeping poll task must not
    /// outlive the controller that owns it.
    deinit {
        replanTask?.cancel()
        evaluationTask?.cancel()
    }

    /// Component enabled (or Wakely launched with it on). The helper may be
    /// installed late, so an unreachable helper is reported, not fatal.
    func start() {
        isQuitting = false
        stopTimers()
        guard isEnabled() else {
            diagnostics("sleep until reset: component is off; no wakes were scheduled")
            return
        }
        startReplanLoop()
        Task { @MainActor [weak self] in
            guard let self else { return }
            // A wake scheduled before a relaunch is still ours. Adopt the
            // helper's ownership record so didWake can recognize it even though
            // this process never saw the original schedule call.
            let snapshot = await self.helper.wakeScheduleSnapshot()
            if snapshot.ok {
                self.plannedWakes = snapshot.wakes.filter(Self.isOurs).map(\.at)
            }
            await self.replan(reason: "component enabled")
        }
    }

    /// Read the resets, plan the wakes and reconcile the helper's owned set.
    /// `[]` resets means the controller stays inert: it never claims a wake it
    /// did not schedule and never invents a reset time.
    func replan(reason: String = "replan") async {
        guard isEnabled() else { return }
        guard isLidClosed() else {
            // The lid is the user's override; do not schedule behind it.
            await cancelOwnedWakes(reason: "the lid opened")
            return
        }
        let generation = lifecycleGeneration
        guard await reachable() else {
            diagnostics("sleep until reset: the privileged helper is unavailable; no wakes were changed (\(reason))")
            return
        }
        guard generation == lifecycleGeneration, isEnabled(), isLidClosed() else { return }

        let reader = self.reader
        let instant = now()
        let resets = await Task.detached(priority: .utility) { reader.read() }.value
        guard generation == lifecycleGeneration, isEnabled(), isLidClosed() else { return }
        let planned = UsageResetPolicy.plan(resets: resets, now: instant)
        let planKey = UsageResetPolicy.replanKey(resets: resets)

        guard !planned.isEmpty else {
            // Keep any helper-owned wakes adopted at launch; an empty reset read
            // does not disprove a wake that is still scheduled.
            if planKey != lastReportedPlanKey {
                lastReportedPlanKey = planKey
                diagnostics("sleep until reset: no future reset was found in the local Claude Code or Codex records; no wakes were scheduled")
            }
            return
        }
        lastReportedPlanKey = planKey
        if let confirmed = await reconcile(planned: planned, generation: generation) {
            plannedWakes = confirmed
        }
    }

    /// Lid closed: plan now instead of waiting for the next periodic replan.
    /// Nothing is scheduled while the lid is open, so the close is the first
    /// moment this component has work to do.
    func lidDidClose() {
        guard isEnabled() else { return }
        Task { @MainActor [weak self] in
            await self?.replan(reason: "the lid closed")
        }
    }

    /// Lid opened: cancel this component's owned wakes and let the stay-awake
    /// session go. Fire-and-forget: nothing is scheduled from here.
    func lidDidOpen() {
        lifecycleGeneration &+= 1
        endSession(reason: "the lid opened", sleep: false)
        // The plan is abandoned with the wakes: a wake that lands near a stale
        // instant must not start a session behind the user's override.
        plannedWakes = []
        Task { @MainActor [weak self] in
            _ = await self?.cancelOwnedWakes(reason: "the lid opened")
        }
    }

    /// Component turned off: stop both timers, release our hold, forget the plan so
    /// a later enable replans from scratch, and cancel the owned wakes.
    func didDisable() {
        guard !isQuitting else { return }
        lifecycleGeneration &+= 1
        stopTimers()
        endSession(reason: "the component was turned off", sleep: false)
        plannedWakes = []
        lastReportedPlanKey = nil
        Task { @MainActor [weak self] in
            _ = await self?.cancelOwnedWakes(reason: "the component was turned off")
        }
    }

    /// Quit: stop timers and cancel the owned wakes. The existing termination
    /// drain keeps the process alive long enough for the XPC round trips; the
    /// cancellation is deliberately fire-and-forget so quitting never blocks
    /// on an absent helper.
    func didQuit() {
        isQuitting = true
        lifecycleGeneration &+= 1
        stopTimers()
        resetSessionState()
        disarm("Wakely quit")
        // Quit cancels the owned wakes; the in-memory plan no longer describes
        // anything the helper still owns, so a wake during the termination drain
        // must not start a session.
        plannedWakes = []
        Task { @MainActor [weak self] in
            _ = await self?.cancelOwnedWakes(reason: "Wakely quit")
        }
    }

    // MARK: - Wake

    /// Called from the existing system-wake path. The Mac is already awake;
    /// this method never asks the system to wake.
    func didWake() {
        guard isEnabled() else { return }
        guard isLidClosed() else { return }

        let instant = now()
        guard UsageResetPolicy.isPlannedWake(instant, planned: plannedWakes) else {
            diagnostics("sleep until reset: this wake does not match a planned reset time; nothing was started")
            return
        }
        // A planned instant is single use. Keeping it would let an unrelated
        // wake within the match window start a second four-hour session after
        // this reset's session already began (or already ended).
        plannedWakes.removeAll {
            abs($0.timeIntervalSince(instant)) <= UsageResetPolicy.wakeMatchTolerance
        }
        if UsageResetPolicy.shouldWakeOnBattery(at: instant, onBattery: onBattery()) {
            resetSessionState()
            disarm("the Mac woke on battery while sleeping until a usage reset")
            diagnostics("sleep until reset: the Mac woke on battery; it goes back to sleep instead of staying awake")
            if !isArmed() { requestSleep() }
            return
        }

        let wasArmed = isArmed()
        guard arm() else {
            diagnostics("sleep until reset: the stay-awake session could not be started after the wake")
            return
        }
        // A wake while our own session is still running must not extend the
        // four-hour cap or forget that the hold is ours. An arm that already
        // existed belongs to someone else and is never claimed.
        ownsSessionHold = true
        sessionStartedAt = sessionStartedAt ?? instant
        lastWorkAt = instant
        waitingSince = nil
        diagnostics("sleep until reset: awake on the charger; holding while agents work, for at most four hours")
        startEvaluation()
    }

    // MARK: - Reconcile

    /// Cancel owned wakes that are no longer planned and schedule the missing
    /// ones. A helper that cannot report its owned set is left untouched: a
    /// duplicate event is worse than a late one.
    private func reconcile(planned: [Date], generation: Int) async -> [Date]? {
        guard !isReconciling else { return nil }
        isReconciling = true
        defer { isReconciling = false }

        let snapshot = await helper.wakeScheduleSnapshot()
        guard generation == lifecycleGeneration, isEnabled(), isLidClosed() else { return nil }
        guard snapshot.ok else {
            diagnostics("sleep until reset: the helper could not report its owned wakes; nothing was scheduled or canceled")
            return nil
        }

        let owned = snapshot.wakes.filter(Self.isOurs)
        var kept: [Date] = []
        var canceled = 0
        var scheduled = 0

        for wake in owned {
            guard generation == lifecycleGeneration, isEnabled(), isLidClosed() else { return nil }
            if planned.contains(where: { abs($0.timeIntervalSince(wake.at)) <= Self.ownershipTolerance }) {
                kept.append(wake.at)
                continue
            }
            let receipt = await helper.cancelWake(at: wake.at)
            guard generation == lifecycleGeneration, isEnabled(), isLidClosed() else { return nil }
            if receipt.reply.ok {
                canceled += 1
            } else {
                diagnostics("sleep until reset: an owned wake could not be canceled: \(receipt.reply.message)")
            }
        }

        for instant in planned {
            guard generation == lifecycleGeneration, isEnabled(), isLidClosed() else { return nil }
            if kept.contains(where: { abs($0.timeIntervalSince(instant)) <= Self.ownershipTolerance }) {
                continue
            }
            // The plan was computed before the transcript scan (and the read
            // above); measure the lead against the clock at the moment of the
            // helper call, or a slow scan turns an acceptable instant into one
            // the helper refuses.
            guard instant.timeIntervalSince(now()) >= Self.minimumWakeLead else { continue }
            let receipt = await helper.scheduleWake(at: instant)
            guard generation == lifecycleGeneration, isEnabled(), isLidClosed() else { return nil }
            if receipt.reply.ok {
                kept.append(instant)
                scheduled += 1
            } else {
                diagnostics("sleep until reset: an owned wake could not be scheduled: \(receipt.reply.message)")
            }
        }

        diagnostics("sleep until reset: \(planned.count) wake(s) planned, \(scheduled) scheduled, \(canceled) canceled, \(kept.count) confirmed")
        return kept
    }

    /// Delete Wakely: cancel the owned wakes and WAIT for the XPC round trips.
    /// `didQuit`'s cancellation is fire-and-forget, which is fine for a quit
    /// (the termination drain covers it) but not for a delete: the helper is
    /// removed moments later, and a wake it still owns would survive the
    /// uninstall. Returns how many wakes were canceled.
    @discardableResult
    func cancelOwnedWakesForDelete(reason: String) async -> Int {
        await cancelOwnedWakes(reason: reason)
    }

    /// Cancel every wake this component owns. Never cancels by date alone: the
    /// helper matches its own ownership record, and only the component label it
    /// stored is treated as ours.
    @discardableResult
    private func cancelOwnedWakes(reason: String) async -> Int {
        guard await reachable() else {
            diagnostics("sleep until reset: the privileged helper is unavailable; owned wakes could not be canceled (\(reason))")
            return 0
        }
        let snapshot = await helper.wakeScheduleSnapshot()
        guard snapshot.ok else {
            diagnostics("sleep until reset: the helper could not report its owned wakes; nothing was canceled (\(reason))")
            return 0
        }
        let owned = snapshot.wakes.filter(Self.isOurs)
        guard !owned.isEmpty else { return 0 }
        var canceled = 0
        for wake in owned {
            let receipt = await helper.cancelWake(at: wake.at)
            if receipt.reply.ok { canceled += 1 }
        }
        diagnostics("sleep until reset: canceled \(canceled) owned wake(s) after \(reason)")
        return canceled
    }

    private static func isOurs(_ wake: OwnedWake) -> Bool {
        wake.kind == "wake" && (wake.createdBy ?? "") == componentID
    }

    // MARK: - Stay-awake session

    private func startReplanLoop() {
        replanTask?.cancel()
        replanTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.replanInterval * 1_000_000_000))
                } catch {
                    return
                }
                guard let self, self.isEnabled() else { return }
                await self.replan(reason: "periodic replan")
            }
        }
    }

    /// One user-facing window from `UserDefaults`. The settings pane owns the
    /// stored value; a missing key falls back to the documented default and
    /// anything out of range is clamped, so a duration is never zero or negative.
    private func intSetting(_ key: String, default def: Int, in range: ClosedRange<Int>) -> Int {
        let stored = UserDefaults.standard.object(forKey: key) as? Int ?? def
        return min(max(stored, range.lowerBound), range.upperBound)
    }

    private func startEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.evaluationInterval * 1_000_000_000))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.isEnabled(), self.isLidClosed() else {
                    self.endSession(reason: "the component was turned off or the lid opened", sleep: false)
                    return
                }
                self.evaluate()
            }
        }
    }

    private func evaluate() {
        guard let started = sessionStartedAt else {
            stopEvaluation()
            return
        }
        let instant = now()
        let counts = agentCounts()
        if counts.working > 0 {
            lastWorkAt = instant
            waitingSince = nil
        } else if counts.waiting > 0 {
            waitingSince = waitingSince ?? instant
        } else {
            waitingSince = nil
        }

        let policyReason = UsageResetPolicy.shouldEndAfterWake(
            now: instant,
            sessionStartedAt: started,
            working: counts.working,
            waiting: counts.waiting,
            waitingSince: waitingSince,
            lastWorkAt: lastWorkAt
        )
        // The four-hour cap is the policy's fixed contract. Its built-in idle
        // and waiter windows are not: those two are user settings, measured
        // below, so only the cap is taken from the policy here.
        if policyReason == UsageResetEndReason.fourHourCap {
            endSession(reason: UsageResetEndReason.fourHourCap.message, sleep: true)
            return
        }

        let idleMinutes = intSetting("sleepUntilReset.idleMinutes", default: 30, in: 5...240)
        let waitingMinutes = intSetting("sleepUntilReset.waitingMinutes", default: 15, in: 1...120)

        if counts.working > 0 { return }
        if counts.waiting > 0 {
            // A waiter is evidence of an unfinished task: hold until the
            // user's waiting window has elapsed.
            let since = min(instant, max(started, waitingSince ?? instant))
            if instant.timeIntervalSince(since) >= TimeInterval(waitingMinutes * 60) {
                endSession(reason: "an agent had been waiting for you for \(waitingMinutes) minutes", sleep: true)
            }
            return
        }
        let lastWorkEpoch = lastWorkAt ?? started
        let baseline = min(instant, max(started, lastWorkEpoch))
        if instant.timeIntervalSince(baseline) >= TimeInterval(idleMinutes * 60) {
            endSession(reason: "no agent was working within the \(idleMinutes)-minute grace after the wake", sleep: true)
        }
    }

    /// End the stay-awake session. The Mac is put back to sleep only when the
    /// session this controller began actually ended: another component's hold, or
    /// the user's, is never overridden by a sleep request from here.
    private func endSession(reason: String, sleep: Bool) {
        let held = ownsSessionHold
        resetSessionState()
        // Release only this controller's claim. Another component or a manual
        // hold keeps the session alive and suppresses our sleep request.
        disarm(reason)
        diagnostics("sleep until reset: \(reason)")
        if sleep, !isArmed() {
            requestSleep()
        }
        _ = held
    }

    private func resetSessionState() {
        stopEvaluation()
        sessionStartedAt = nil
        lastWorkAt = nil
        waitingSince = nil
        ownsSessionHold = false
    }

    private func stopEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = nil
    }

    private func stopTimers() {
        replanTask?.cancel()
        replanTask = nil
        stopEvaluation()
    }

    /// Test seam: whether this controller currently believes it owns the arm.
    var isHoldingSession: Bool { ownsSessionHold }
}
