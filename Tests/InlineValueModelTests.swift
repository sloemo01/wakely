// Tests for Sources/InlineValueModel.swift.
//
// Pure and standalone: no app, no UI framework, no system call, no fixture
// files. Compile from the repository root with:
//
//   swiftc -swift-version 5 -target arm64-apple-macos14.0 \
//     Sources/InlineValueModel.swift Tests/InlineValueModelTests.swift \
//     -o build/inline-value-tests && build/inline-value-tests
//
// Every failed expectation trips a precondition and names the broken rule.

@main
struct InlineValueModelTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() {
        domains()
        explicitDomains()
        stepping()
        formatting()
        scrubbing()
        commitPolicy()
        print("PASS: inline value model")
    }

    // MARK: - Domains

    static func domains() {
        let linear = InlineValueDomain.linear(1...30, step: 5)
        // Stride anchored at the lower bound: 1, then 1+5, ... while <= 30.
        // The upper bound 30 is not on that grid and is not included.
        expect(linear.values == [1, 6, 11, 16, 21, 26],
               "linear(1...30, step: 5) follows the lower-bound-anchored rule")
        expect(linear.min == 1 && linear.max == 26 && linear.count == 6,
               "linear domain bounds and count")

        let everyValue = InlineValueDomain.linear(1...30, step: 1)
        expect(everyValue.values == Array(1...30), "step 1 covers the whole range")
        expect(everyValue.values.last == 30, "an aligned upper bound is included")

        let single = InlineValueDomain.linear(5...5, step: 3)
        expect(single.values == [5], "a single-point range yields one value")

        let aligned = InlineValueDomain.linear(0...10, step: 5)
        expect(aligned.values == [0, 5, 10], "upper bound included when aligned")

        let unaligned = InlineValueDomain.linear(2...20, step: 5)
        expect(unaligned.values == [2, 7, 12, 17],
               "the stride starts at the lower bound, not at zero")
        expect(unaligned.min == 2 && unaligned.max == 17,
               "an unaligned upper bound is excluded")

        expect(InlineValueDomain.linear(1...30, step: 0).values == [1],
               "non-positive step falls back to the lower bound")
        expect(InlineValueDomain.linear(1...30, step: -5).values == [1],
               "negative step falls back to the lower bound")

        let overflowing = InlineValueDomain.linear(Int.max - 1...Int.max, step: 5)
        expect(overflowing.values == [Int.max - 1],
               "the stride stops before Int overflow")

        expect(linear.clamp(0) == 1, "clamp below the range yields the minimum")
        expect(linear.clamp(100) == 26, "clamp above the range yields the maximum")
        expect(linear.clamp(16) == 16, "clamp keeps an allowed in-range value")
        expect(linear.clamp(13) == 13,
               "clamp is a bounds clamp; snapping is value(at: index(of:)) instead")

        expect(linear.value(at: -100) == 1, "negative index clamps to minimum")
        expect(linear.value(at: 100) == 26, "large index clamps to maximum")
        expect(linear.value(at: 3) == 16, "in-range index selects that value")
    }

    static func explicitDomains() {
        expect(InlineValueDomain([]) == nil, "empty domain is invalid")
        expect(InlineValueDomain([3, 3]) == nil, "repeated value is invalid")
        expect(InlineValueDomain([3, 2]) == nil, "descending domain is invalid")
        expect(InlineValueDomain([1, 3, 2]) == nil, "unsorted domain is invalid")

        expect(InlineValueDomain([5])?.values == [5], "single-value domain is valid")
        expect(InlineValueDomain([-10, 0, 10])?.values == [-10, 0, 10],
               "negative and zero values are valid")

        expect(InlineValueDomain.explicit([]).values == [0],
               "explicit falls back to [0] for an empty list")
        expect(InlineValueDomain.explicit([3, 2]).values == [2, 3],
               "explicit sorts an unordered list")
        expect(InlineValueDomain.explicit([5, 1, 5, 3]).values == [1, 3, 5],
               "explicit deduplicates a component value list")
        let componentDomain = InlineValueDomain.explicit(Array(stride(from: 1, through: 60, by: 1)) + [1, 60, 2])
        expect(componentDomain.min == 1 && componentDomain.max == 60,
               "a component stride plus endpoints and current value keeps its bounds")
        expect(componentDomain.stepped(from: 2, by: 1) == 3,
               "a component value can increase and decrease")
        expect(InlineValueDomain.explicit([7]).values == [7],
               "explicit keeps a valid single value")
        expect(InlineValueDomain.explicit([-2, 2, 4]).values == [-2, 2, 4],
               "explicit keeps valid values")
        expect(InlineValueDomain.explicit([1, 2]) == InlineValueDomain([1, 2]),
               "explicit equals the failable init on valid input")
    }

    // MARK: - Stepping

    static func stepping() {
        let domain = InlineValueDomain.linear(1...30, step: 5)  // 1, 6, 11, 16, 21, 26

        expect(domain.index(of: 1) == 0, "nearest at the minimum")
        expect(domain.index(of: 26) == 5, "nearest at the maximum")
        expect(domain.index(of: 0) == 0, "below range maps to the first index")
        expect(domain.index(of: 100) == 5, "above range maps to the last index")
        expect(domain.index(of: 11) == 2, "an exact allowed value maps to itself")
        expect(domain.index(of: 13) == 2, "13 is nearest to 11")
        expect(domain.index(of: 14) == 3, "14 is nearest to 16")

        expect(domain.stepped(from: 1, by: 2) == 11, "two steps up")
        expect(domain.stepped(from: 11, by: -2) == 1, "two steps down")
        expect(domain.stepped(from: 1, by: -1) == 1, "stepping below min clamps")
        expect(domain.stepped(from: 26, by: 4) == 26, "stepping above max clamps")
        expect(domain.stepped(from: 14, by: 1) == 21,
               "an off-grid start snaps before stepping up")
        expect(domain.stepped(from: 14, by: -1) == 11,
               "an off-grid start snaps before stepping down")
        expect(domain.stepped(from: 11, by: 0) == 11, "zero steps is a no-op")
        expect(domain.stepped(from: 13, by: 0) == 11,
               "zero steps still resolves an off-grid start to the nearest value")
        expect(domain.stepped(from: 1, by: Int.max) == 26,
               "a huge step count clamps to the maximum")
        expect(domain.stepped(from: 26, by: Int.max) == 26,
               "an overflowing start+steps clamps to the maximum")
        expect(domain.stepped(from: 26, by: Int.min) == 1,
               "an extreme negative step count clamps to the minimum")

        let gapped = InlineValueDomain.explicit([10, 20])
        expect(gapped.index(of: 15) == 0, "a tie chooses the lower allowed value")
        expect(gapped.index(of: 16) == 1, "16 is nearest to 20")
        expect(gapped.index(of: 14) == 0, "14 is nearest to 10")
        expect(gapped.stepped(from: 20, by: -1) == 10, "a gap domain steps down")
        expect(gapped.value(at: 1) == 20 && gapped.value(at: -1) == 10,
               "value(at:) clamps indices at both ends")

        let extremes = InlineValueDomain.explicit([Int.min, Int.max])
        expect(extremes.index(of: 0) == 1,
               "the nearest comparison survives the full Int range")
        expect(extremes.index(of: -1) == 0,
               "a value one below zero is nearest to Int.min")
    }

    // MARK: - Formatting

    static func formatting() {
        typealias F = InlineValueFormat

        expect(F.minutes.label(1) == "1 minute", "one minute is singular")
        expect(F.minutes.label(2) == "2 minutes", "two minutes is plural")
        expect(F.minutes.label(59) == "59 minutes", "under an hour stays minutes")
        expect(F.minutes.label(60) == "1 hour", "a whole hour folds")
        expect(F.minutes.label(90) == "1 hour, 30 minutes", "ninety minutes folds")
        expect(F.minutes.label(120) == "2 hours", "two whole hours fold")
        expect(F.minutes.label(61) == "1 hour, 1 minute", "singular remainder")
        expect(F.minutes.label(121) == "2 hours, 1 minute",
               "plural hours with a singular remainder")
        expect(F.minutes.label(0) == "0 minutes", "zero minutes")
        expect(F.minutes.label(-90) == "-1 hour, 30 minutes",
               "negative minutes keep the sign")

        expect(F.hours.label(1) == "1 hour", "one hour is singular")
        expect(F.hours.label(2) == "2 hours", "two hours is plural")
        expect(F.hours.label(0) == "0 hours", "zero hours")
        expect(F.hours.label(-1) == "-1 hour", "negative one hour")

        expect(F.seconds.label(1) == "1 second", "one second is singular")
        expect(F.seconds.label(30) == "30 seconds", "thirty seconds is plural")
        expect(F.seconds.label(0) == "0 seconds", "zero seconds")
        expect(F.seconds.label(60) == "60 seconds",
               "seconds do not fold into minutes")

        expect(F.percent.label(15) == "15%", "percent")
        expect(F.percent.label(0) == "0%", "zero percent")
        expect(F.percent.label(-15) == "-15%", "negative percent")

        expect(F.count.label(42) == "42", "count is a plain number")
        expect(F.count.label(0) == "0", "zero count")
        expect(F.count.label(-3) == "-3", "negative count")

        expect(F.minutes == .minutes && F.minutes != .hours,
               "format values are Equatable")
    }

    // MARK: - Scrubbing

    static func scrubbing() {
        let mapping = InlineScrubMapping()
        expect(mapping.pointsPerStep == 12, "default is 12 points per step")
        expect(mapping.steps(forTranslation: 0) == 0, "no travel is no steps")
        expect(mapping.steps(forTranslation: 6) == 0, "half a step truncates to zero")
        expect(mapping.steps(forTranslation: 11.9) == 0, "just under a step truncates")
        expect(mapping.steps(forTranslation: 12) == 1, "one full step")
        expect(mapping.steps(forTranslation: 23.9) == 1,
               "one and a fraction truncates")
        expect(mapping.steps(forTranslation: 24) == 2, "two full steps")
        expect(mapping.steps(forTranslation: 47.9) == 3,
               "three and a fraction truncates")
        expect(mapping.steps(forTranslation: -24) == -2, "left mirrors right")
        expect(mapping.steps(forTranslation: -35.9) == -2,
               "negative travel truncates toward zero, not down to -3")

        for dx in [0.0, 0.5, 6.0, 11.9, 12.0, 23.0, 24.0, 35.9, -11.9, -12.0, -100.5] {
            expect(mapping.steps(forTranslation: dx) == -mapping.steps(forTranslation: -dx),
                   "the mapping is symmetric at \(dx)")
        }

        let tenPoint = InlineScrubMapping(pointsPerStep: 10)
        expect(tenPoint.steps(forTranslation: 25) == 2, "custom points per step")
        expect(tenPoint.steps(forTranslation: -25) == -2, "custom mapping is symmetric")

        expect(InlineScrubMapping(pointsPerStep: 0).pointsPerStep == 12,
               "a zero step size falls back to the 12-point default")
        expect(InlineScrubMapping(pointsPerStep: -4).pointsPerStep == 12,
               "a negative step size falls back to the default")
        expect(InlineScrubMapping(pointsPerStep: .infinity).pointsPerStep == 12,
               "an infinite step size falls back to the default")
        expect(InlineScrubMapping(pointsPerStep: .nan).pointsPerStep == 12,
               "a NaN step size falls back to the default")

        let domain = InlineValueDomain.linear(1...30, step: 5)  // 1, 6, 11, 16, 21, 26
        var session = InlineValueScrubSession(domain: domain, anchorValue: 11)
        expect(session.currentValue == 11, "a session starts on its anchor")
        expect(session.anchorValue == 11, "the anchor is kept")
        expect(!session.didChange, "a fresh session has not changed")

        expect(session.update(translation: 24) == 21,
               "+24 points at 12/step is two steps up")
        expect(session.didChange, "moving off the anchor marks a change")
        expect(session.update(translation: -24) == 11,
               "-24 points returns to the anchor")
        expect(!session.didChange, "returning to the anchor clears didChange")

        // Sub-step travel accumulates instead of being discarded per event.
        expect(session.update(translation: 6) == 11, "half a step alone does not move")
        expect(session.update(translation: 6) == 16,
               "a second half step reaches a whole step")
        expect(session.update(translation: -12) == 11, "returning 12 points retraces")

        // Reversal stability: overshoot, then come back step for step.
        expect(session.update(translation: 30) == 21, "30 points is two steps")
        expect(session.update(translation: -6) == 21, "a sub-step reversal holds")
        expect(session.update(translation: -6) == 16, "another 6 points steps back")
        expect(session.update(translation: -18) == 11, "the full reversal returns")

        // Bounds clamping.
        var low = InlineValueScrubSession(domain: domain, anchorValue: 1)
        expect(low.update(translation: 1000) == 26, "far right clamps to max")
        expect(low.update(translation: -12) == 21, "one step back responds immediately after upper overshoot")
        expect(low.update(translation: -2000) == 1, "far left clamps to min")
        expect(low.update(translation: 12) == 6, "one step forward responds immediately after lower overshoot")
        expect(low.update(translation: -12) == 1, "returns to anchor after boundary reversal")
        expect(!low.didChange, "clamping back onto the anchor reports no change")

        var high = InlineValueScrubSession(domain: domain, anchorValue: 26)
        expect(high.update(translation: 24) == 26, "cannot step past the max")
        expect(!high.didChange, "clamping at the max is not a change")

        // Cancel.
        var cancelled = InlineValueScrubSession(domain: domain, anchorValue: 11)
        _ = cancelled.update(translation: 24)
        expect(cancelled.currentValue == 21, "scrubbed before cancel")
        cancelled.cancel()
        expect(cancelled.currentValue == 11, "cancel restores the anchor")
        expect(!cancelled.didChange, "cancel clears didChange")
        expect(cancelled.update(translation: 6) == 11,
               "cancel also clears the accumulated travel")

        // Anchor normalization for off-grid and out-of-range anchors.
        let gapped = InlineValueDomain.explicit([10, 20])
        expect(InlineValueScrubSession(domain: gapped, anchorValue: 15).anchorValue == 10,
               "an off-grid anchor snaps to the nearest allowed value")
        expect(InlineValueScrubSession(domain: gapped, anchorValue: 1000).anchorValue == 20,
               "an above-range anchor snaps to the maximum")
        expect(InlineValueScrubSession(domain: gapped, anchorValue: -1000).anchorValue == 10,
               "a below-range anchor snaps to the minimum")

        let fresh = InlineValueScrubSession(domain: domain, anchorValue: 11)
        var moved = InlineValueScrubSession(domain: domain, anchorValue: 11)
        expect(fresh == moved, "fresh sessions with the same inputs are equal")
        _ = moved.update(translation: 24)
        expect(fresh != moved, "a scrubbed session differs from a fresh one")
    }

    // MARK: - Commit policy

    static func commitPolicy() {
        typealias P = InlineEditCommitPolicy
        let domain = InlineValueDomain.linear(1...30, step: 5)  // 1, 6, 11, 16, 21, 26

        expect(P.parse("21", in: domain) == 21, "a legal value parses")
        expect(P.parse(" 21 ", in: domain) == 21, "surrounding whitespace is trimmed")
        expect(P.parse("\t+18\n", in: domain) == 16,
               "a leading plus is accepted and 18 snaps to 16")
        expect(P.parse("19", in: domain) == 21, "19 snaps up to 21")
        expect(P.parse("17", in: domain) == 16, "17 snaps down to 16")
        expect(P.parse("1", in: domain) == 1, "the minimum parses")
        expect(P.parse("26", in: domain) == 26, "the maximum parses")
        expect(P.parse("+000000021", in: domain) == 21,
               "leading zeros are digits, not sign")
        expect(P.parse("-0", in: domain) == nil,
               "negative zero is zero, which is below the domain")

        expect(P.parse("30", in: domain) == nil,
               "30 is above the domain's max of 26")
        expect(P.parse("27", in: domain) == nil, "above the maximum is rejected")
        expect(P.parse("0", in: domain) == nil, "below the minimum is rejected")
        expect(P.parse("-1", in: domain) == nil,
               "an out-of-domain negative value is rejected")

        expect(P.parse("", in: domain) == nil, "empty input is invalid")
        expect(P.parse("   ", in: domain) == nil, "whitespace-only input is invalid")
        expect(P.parse("abc", in: domain) == nil, "non-numeric input is invalid")
        expect(P.parse("12x", in: domain) == nil, "trailing junk is invalid")
        expect(P.parse("1 2", in: domain) == nil, "inner whitespace is invalid")
        expect(P.parse("1.5", in: domain) == nil, "decimals are invalid")
        expect(P.parse("+", in: domain) == nil, "a bare sign is invalid")
        expect(P.parse("-", in: domain) == nil, "a bare minus is invalid")
        expect(P.parse("--5", in: domain) == nil, "a doubled sign is invalid")
        expect(P.parse("١٢", in: domain) == nil, "non-ASCII digits are invalid")

        expect(P.parse("1234567890", in: domain) == nil,
               "ten digits is overflow-shaped input")
        expect(P.parse("0000000000", in: domain) == nil,
               "ten digits are rejected even when their value is small")
        let wide = InlineValueDomain.explicit([0, 999_999_999])
        expect(P.parse("999999999", in: wide) == 999_999_999,
               "nine digits fit and are accepted in range")

        let gapped = InlineValueDomain.explicit([10, 20])
        expect(P.parse("15", in: gapped) == 10,
               "an off-grid parse snaps to the lower value on a tie")

        expect(P.resolveOnBlur("21", in: domain) == 21,
               "a valid blur buffer commits its parsed value")
        expect(P.resolveOnBlur("18", in: domain) == 16,
               "a blur buffer can commit the nearest proposal")
        expect(P.resolveOnBlur("", in: domain) == nil,
               "an empty blur buffer restores the old value")
        expect(P.resolveOnBlur("junk", in: domain) == nil,
               "an invalid blur buffer restores the old value")
        expect(P.resolveOnBlur("31", in: domain) == nil,
               "an out-of-domain blur buffer restores the old value")
    }
}
