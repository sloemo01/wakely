// App-free tests. The runner extracts only the pure lifecycle helpers from
// PowerEngine.swift; no IOHIDManager, AppKit window, power assertion or audio
// device is created here.
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var value = 0
    func increment() {
        lock.lock(); value += 1; lock.unlock()
    }
}

@main
struct PowerEngineLifecycleTests {
    @MainActor
    static func main() async {
        // MARK: Resource retention and bounded retry
        expect(PowerResourceRelease.retainedID(42, succeeded: false) == 42,
               "failed release retains the exact resource ID")
        expect(PowerResourceRelease.retainedID(42, succeeded: true) == 0,
               "successful release clears ownership")
        expect(PowerResourceRelease.retainedID(0, succeeded: false) == 0,
               "an absent resource stays absent")
        var retry = PowerCleanupRetry()
        for expected in [1.0, 2, 4, 8, 16, 32, 60, 60] {
            expect(retry.nextDelay() == expected, "cleanup backs off exponentially with a 60s cap")
        }
        retry.reset()
        expect(retry.nextDelay() == 1, "successful cleanup resets backoff")
        expect(PowerAssertionPolicy.transitionProperties(majorVersion: 25) == nil,
               "older macOS skips the transition assertion")
        for version in [26, 27] {
            let properties = PowerAssertionPolicy.transitionProperties(majorVersion: version)!
            expect(properties.count == 4, "transition assertion has exactly four entries")
            expect(properties["AssertType"] as? String == "PreventSystemSleep", "exact type")
            expect(properties["AssertName"] as? String == "Wakely: protecting closed-lid power transitions", "exact name")
            expect(properties["AssertLevel"] as? Int == 255, "exact assertion level")
            expect(properties["SensorActive"] as? Bool == true, "sensor active is true")
        }

        // MARK: Lid angle freshness
        // Discovery is not proof of a working sensor; only a report inside the
        // 2s window is fresh, and a stale sample must leave registry polling
        // authoritative.
        var health = LidAngleSensorHealth(freshness: 2, restartInterval: 10)
        expect(!health.isFresh(at: 100), "a manager with no report is never fresh")
        expect(health.shouldRestart(at: 100), "the first discovery attempt is immediate")
        health.beginAttempt(at: 100)
        expect(!health.shouldRestart(at: 109.9), "do not thrash a just-opened sensor")
        expect(health.shouldRestart(at: 110), "redispatch a stalled sensor after 10s")

        health.recordSample(at: 111)
        expect(health.isFresh(at: 112.9), "a report inside 2s is fresh")
        expect(!health.isFresh(at: 113.1), "a 2s stall is stale, not frozen")
        health.beginAttempt(at: 120)
        expect(!health.isFresh(at: 120), "a rediscovery attempt awaits its first report")

        health.recordSample(at: 121)
        health.reset()
        expect(!health.isFresh(at: 121.1), "stop must reset the sample state")
        expect(health.shouldRestart(at: 121.1), "stop must also clear the attempt state")

        // MARK: Chime gating
        expect(CloseChimePolicy.isEligible(armed: true, componentEnabled: true, lidClosed: true),
               "armed + enabled + really closed is eligible")
        expect(!CloseChimePolicy.isEligible(armed: false, componentEnabled: true, lidClosed: true),
               "an unarmed close is silent")
        expect(!CloseChimePolicy.isEligible(armed: true, componentEnabled: false, lidClosed: true),
               "a disabled component is silent")
        expect(!CloseChimePolicy.isEligible(armed: true, componentEnabled: true, lidClosed: false),
               "an open lid is never eligible")

        // Near-close audio: fires on the crossing into <=30°, never at the old
        // arbitrary 70° crossing, and only while the registry still says open.
        expect(CloseChimePolicy.crossedNearClose(previous: 100, current: 22, lidClosed: false),
               "a hinge entering the near-closed band may chime")
        expect(!CloseChimePolicy.crossedNearClose(previous: 100, current: 60, lidClosed: false),
               "the old 70°-ish crossing must stay silent")
        expect(!CloseChimePolicy.crossedNearClose(previous: 25, current: 20, lidClosed: false),
               "already-near samples do not retrigger")
        expect(!CloseChimePolicy.crossedNearClose(previous: 100, current: 10, lidClosed: true),
               "the registry close fallback handles a real closed state")
        expect(CloseChimePolicy.isClearlyOpen(45), "45° re-arms the next close")
        expect(!CloseChimePolicy.isClearlyOpen(44.9), "hysteresis keeps a near-close chime latched")
        // These are OSS audio settings, not ArmedCloseTracker's travel deltas.
        expect(CloseChimePolicy.nearCloseAngle == 30, "preserve audio lead-in pending original call-chain trace")

        var latch = CloseChimeLatch()
        expect(!latch.sounded, "a new close starts unlatched")
        // Queueing a request is not a start: only markStarted consumes the latch.
        expect(!latch.sounded, "a failed start must remain retryable")
        latch.markStarted()
        expect(latch.sounded, "an actually started playback consumes the latch")
        latch.reset()
        expect(!latch.sounded, "the next close may chime again")

        // MARK: Caps Lock reset policy
        expect(ClosedSessionPolicy.shouldResetCaps(closedSessionActive: true, componentEnabled: true),
               "a real closed-lid session ending may clear Caps Lock")
        expect(!ClosedSessionPolicy.shouldResetCaps(closedSessionActive: false, componentEnabled: true),
               "an idle Unarm never clears the user's Caps Lock")
        expect(!ClosedSessionPolicy.shouldResetCaps(closedSessionActive: true, componentEnabled: false),
               "the component must be enabled to own the key")

        // Caps Lock is the switch, so an explicit Unarm must release it even with
        // the lid open; nothing else may touch the key.
        expect(ClosedSessionPolicy.shouldReleaseCapsOnExplicitUnarm(componentEnabled: true, explicitUnarm: true, capsLit: true),
               "explicit Unarm releases a lit key while the component is on")
        expect(!ClosedSessionPolicy.shouldReleaseCapsOnExplicitUnarm(componentEnabled: false, explicitUnarm: true, capsLit: true),
               "a disabled component never changes the key")
        expect(!ClosedSessionPolicy.shouldReleaseCapsOnExplicitUnarm(componentEnabled: true, explicitUnarm: false, capsLit: true),
               "lid-open and safety disarms leave the key alone")
        expect(!ClosedSessionPolicy.shouldReleaseCapsOnExplicitUnarm(componentEnabled: true, explicitUnarm: true, capsLit: false),
               "an unlit key is not toggled")

        // MARK: Exactly-once power acknowledgement
        let counter = Counter()
        let gate = OnceGate { counter.increment() }
        expect(gate.fire(), "the first acknowledgement runs")
        expect(!gate.fire(), "later acknowledgements are suppressed")
        expect(counter.value == 1, "IOAllowPowerChange-style action runs exactly once")

        // MARK: Bounded sleep preparation
        let fastStart = ProcessInfo.processInfo.systemUptime
        let prepared = await SleepHandshake.awaitPreparation(timeout: 1) { }
        expect(prepared, "fast preparation completes")
        expect(ProcessInfo.processInfo.systemUptime - fastStart < 1, "fast path is not delayed")

        let slowStart = ProcessInfo.processInfo.systemUptime
        let timedOut = await SleepHandshake.awaitPreparation(timeout: 0.2) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let slowElapsed = ProcessInfo.processInfo.systemUptime - slowStart
        expect(!timedOut, "a wedged preparation returns false at the deadline")
        expect(slowElapsed >= 0.15 && slowElapsed < 1.0,
               "deadline is near 0.2s, got \(slowElapsed)s")
        // Let the cancelled operation finish; a duplicate continuation resume
        // would crash the process here.
        try? await Task.sleep(nanoseconds: 250_000_000)

        print("PASS: 9 shared-engine power lifecycle tests (pure policies, no hardware)")
    }
}
