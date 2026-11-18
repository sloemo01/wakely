// App-free tests for the pure CloseGesturePolicy. The runner extracts only the
// `// BEGIN TESTABLE CLOSE GESTURE` block from PowerEngine.swift; no IOHIDManager,
// power assertion, audio device or window is created here.
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

func sample(_ angle: Double, _ timestamp: TimeInterval, shaped: Double? = nil,
            optionHeld: Bool = false, watching: Bool = true,
            gestureActive: Bool = false, retracted: Bool = false) -> CloseGestureSample {
    CloseGestureSample(angle: angle, timestamp: timestamp, shaped: shaped,
                       optionHeld: optionHeld, watching: watching,
                       gestureActive: gestureActive, retracted: retracted)
}

func armedProgress(_ decision: CloseGestureDecision) -> Double? {
    if case .armed(let progress) = decision { return progress }
    return nil
}

@main
struct CloseGesturePolicyTests {
    static func main() {
        // MARK: Engage travel
        expect(CloseGesturePolicy.engageTravel == 20, "engage travel is the traced 20°")
        expect(CloseGesturePolicy.reverseCancelTravel == 15, "reversal travel is the traced 15°")
        expect(CloseGesturePolicy.minimumSampleGap < 0.035
               && CloseGesturePolicy.maximumSampleGap > 0.035,
               "the observed 35 ms close sits inside the bounded sample window")

        var policy = CloseGesturePolicy()
        _ = policy.push(sample(180, 0))
        expect(policy.push(sample(160.1, 0.035)) == .none,
               "19.9° of travel never arms")
        expect(!policy.engaged, "sub-threshold travel leaves the tracker disengaged")
        expect(policy.baseline == 180, "the tracked maximum is retained")
        let engaged = policy.push(sample(160, 0.070))
        expect(armedProgress(engaged) == 0, "arming starts at progress 0")
        expect(policy.engaged, "20° of travel from the maximum arms")
        expect(policy.mostClosed == 160, "arming records the most-closed sample")

        // MARK: Void at the reversal travel
        _ = policy.push(sample(100, 0.105))
        let almost = policy.push(sample(114.9, 0.140))
        expect(armedProgress(almost) != nil, "14.9° of reversal keeps the armed close")
        expect(abs(policy.reverseTravel - 14.9) < 1e-9, "reversal travel is measured from the minimum")
        expect(policy.push(sample(115, 0.175)) == .voided,
               "15° of reversal voids the armed close")
        expect(!policy.engaged, "voiding ends the armed close")
        expect(policy.baseline == 115, "the void re-anchors at the release angle")

        // A voided close is over; a later fresh 20° tilt may arm again.
        expect(armedProgress(policy.push(sample(100, 0.210))) == nil,
               "a 15° drop after a void does not arm")
        expect(armedProgress(policy.push(sample(95, 0.245))) != nil,
               "a fresh 20° tilt after a void can arm a new close")

        // MARK: Sample timing rejection
        var timing = CloseGesturePolicy()
        _ = timing.push(sample(180, 0))
        expect(timing.push(sample(150, 1.0)) == .none,
               "a stale 1-second gap cannot arm a 30° drop")
        expect(!timing.engaged, "stale samples do not arm")
        expect(timing.baseline == 150, "a stale unengaged sample re-anchors the baseline")
        expect(timing.push(sample(100, 1.0)) == .none,
               "a duplicate timestamp is ignored")
        expect(!timing.engaged, "a duplicate cannot arm")
        expect(timing.baseline == 150, "a duplicate cannot move the baseline")
        expect(timing.push(sample(100, 1.001)) == .none,
               "a report inside the minimum gap is duplicate noise")
        expect(!timing.engaged, "a burst report cannot arm")
        expect(armedProgress(timing.push(sample(100, 1.035))) != nil,
               "the next real sample is measured from the last real timestamp")

        var ordering = CloseGesturePolicy()
        _ = ordering.push(sample(180, 1.0))
        expect(ordering.push(sample(100, 0.9)) == .none,
               "an out-of-order timestamp is ignored")
        expect(!ordering.engaged, "out-of-order samples cannot arm")

        // A stale gap during an armed close is ignored, but it must not erase
        // the armed state or the tracked minimum.
        var stale = CloseGesturePolicy()
        _ = stale.push(sample(116, 0))
        _ = stale.push(sample(96, 0.035))
        _ = stale.push(sample(80, 0.070))
        expect(stale.push(sample(200, 0.400)) == .none,
               "a stale engaged sample is ignored")
        expect(stale.engaged, "a sensor gap does not disarm an armed close")
        expect(stale.push(sample(95, 0.435)) == .voided,
               "the next valid sample still releases the void")

        // MARK: No arm on slow drift
        var drift = CloseGesturePolicy()
        _ = drift.push(sample(180, 0))
        var driftTime = 0.0
        var driftAngle = 180.0
        for _ in 0..<20 {
            driftTime += 0.1
            driftAngle -= 1
            let decision = drift.push(sample(driftAngle, driftTime))
            expect(armedProgress(decision) == nil, "1°/100 ms drift never arms")
        }
        expect(!drift.engaged, "20° of slow drift does not arm")

        // A fast flick after a long stationary hold still arms: the maximum's
        // timestamp stays fresh while the lid sits at the same angle.
        var flick = CloseGesturePolicy()
        for index in 0..<20 {
            _ = flick.push(sample(180, Double(index) * 0.1))
        }
        expect(armedProgress(flick.push(sample(159, 1.935))) == 0,
               "a 21° flick after a 2-second hold arms")

        // MARK: Option gate (modeled, not wired in the app)
        var option = CloseGesturePolicy()
        _ = option.push(sample(180, 0))
        expect(option.push(sample(159, 0.035, optionHeld: true)) == .none,
               "option held blocks arming")
        expect(!option.engaged, "option held leaves the tracker disengaged")
        expect(option.baseline == nil, "option held drops the prior maximum")
        _ = option.push(sample(159, 0.070))
        _ = option.push(sample(139, 0.105))
        expect(option.engaged, "a fresh 20° drop after option release arms")
        _ = option.push(sample(120, 0.140))
        expect(armedProgress(option.push(sample(140, 0.175, optionHeld: true))) != nil,
               "option held keeps an armed close through a reversal")
        expect(option.engaged, "the option-held armed close survives")
        expect(option.push(sample(140, 0.210, optionHeld: true, retracted: true)) == .voided,
               "retraction voids an option-held armed close")

        // MARK: Gesture cancel
        var gesture = CloseGesturePolicy()
        _ = gesture.push(sample(180, 0))
        _ = gesture.push(sample(160, 0.035))
        expect(gesture.engaged, "the gesture test starts armed")
        expect(gesture.push(sample(160, 0.070, gestureActive: true)) == .cancelled,
               "gesture-active cancels an armed close")
        expect(!gesture.engaged, "cancelling clears the armed state")
        expect(gesture.push(sample(180, 0.105, gestureActive: true)) == .none,
               "gesture-active without an armed close is a no-op")

        // MARK: Progress normalization (original progress(shaped:))
        var progress = CloseGesturePolicy()
        _ = progress.push(sample(116, 0))
        _ = progress.push(sample(96, 0.035))
        expect(abs(progress.startProgress - CloseGesturePolicy.closedFraction(angle: 96)) < 1e-9,
               "arm-time shaped becomes the progress origin")
        let mid = armedProgress(progress.push(sample(90, 0.070)))!
        expect(abs(mid - 0.0625) < 1e-9, "progress normalizes from the arm origin to closed")
        let complete = armedProgress(progress.push(sample(0, 0.105)))!
        expect(abs(complete - 1) < 1e-9, "progress reaches 1 at the closed end")
        expect(progress.progress(shaped: -1) == 0, "progress clamps below zero")
        expect(progress.progress(shaped: 2) == 1, "progress clamps above one")

        // MARK: One-close lifetime through the existing manual-hold path
        var arm = ArmPolicy()
        arm.requestManual()
        expect(arm.wantsArm, "the manual-hold path is what a tilt arm uses")
        arm.recordActivation(lifetime: .oneClose, succeeded: true)
        expect(arm.shouldEndOnLidOpen, "a tilt arm is a one-close session")
        arm.recordActivation(lifetime: .persistent, succeeded: true)
        expect(arm.shouldEndOnLidOpen,
               "a repeated request cannot overwrite the first session lifetime")
        arm.endSession()
        expect(!arm.wantsArm, "ending the armed close releases manual hold")
        expect(arm.sessionLifetime == nil, "ending the armed close clears the lifetime")

        var failed = ArmPolicy()
        failed.requestManual()
        failed.recordActivation(lifetime: .oneClose, succeeded: false)
        expect(failed.sessionLifetime == nil, "a failed arm publishes no lifetime")
        expect(!failed.shouldEndOnLidOpen, "a failed arm has no close lifetime to end")

        print("PASS: CloseGesturePolicy engage, timing, void, option, progress and one-close lifetime")
    }
}
