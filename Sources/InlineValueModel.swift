// InlineValueModel — the pure model behind an inline numeric chip in prose.
//
// No AppKit, SwiftUI, CoreGraphics, persistence or system call lives here. The
// settings sentence control owns drawing, gestures and storage; this file only
// answers "which numbers are allowed?", "how does this value read?", "what
// does this drag mean?" and "what does this typed buffer mean?". Everything is
// value-typed and deterministic, so the whole scrub/commit story can be
// compiled and exercised without a running app.
//
// The parts:
//
//   InlineValueDomain          the allowed values, strictly ascending
//   InlineValueFormat          how a value is spelled inside the sentence
//   InlineScrubMapping         pointer travel -> whole steps
//   InlineValueScrubSession    one drag, anchored where it started
//   InlineEditCommitPolicy     a typed buffer -> a value, or no value
//
// Two rules are decisions rather than arbitrary detail, and both are
// documented at their definitions: where `linear` anchors its stride, and how
// a scrub session accumulates pointer travel.

import Foundation

/// The closed set of values a chip may show, strictly ascending and non-empty.
struct InlineValueDomain: Equatable {
    /// Ascending and never empty. `init?` is the only way to build an invalid
    /// domain, and it refuses.
    let values: [Int]

    /// A domain must be non-empty and strictly ascending. A repeated value
    /// would make a step's direction ambiguous; an unsorted one would break
    /// `index(of:)` and `stepped(from:by:)`.
    init?(_ values: [Int]) {
        guard !values.isEmpty else { return nil }
        for index in 1..<values.count where values[index] <= values[index - 1] {
            return nil
        }
        self.values = values
    }

    /// Trusted construction for `linear`, whose loop establishes the
    /// non-empty, strictly ascending invariant itself.
    private init(knownValid values: [Int]) {
        self.values = values
    }

    /// A stride anchored at the range's lower bound:
    ///
    ///   1. `range.lowerBound` is always the first value.
    ///   2. Each following value is the previous value plus `step`, while it
    ///      is still `<= range.upperBound`.
    ///
    /// The upper bound is therefore included only when it lands on that grid.
    /// `linear(1...30, step: 5)` is `[1, 6, 11, 16, 21, 26]`; the upper bound
    /// 30 is not reached and is not included. `linear(0...10, step: 5)` is
    /// `[0, 5, 10]`, where the upper bound is.
    ///
    /// Anchoring at the lower bound is deliberate. It keeps the first allowed
    /// value exactly the bound the caller asked for, for every range. A
    /// zero-anchored grid would turn `2...20, step: 5` into
    /// `[2, 5, 10, 15, 20]` — a 3-point first gap — and would make the stride
    /// depend on whether the range happened to contain zero.
    ///
    /// A non-positive `step` cannot stride, so it falls back to the
    /// single-value domain `[range.lowerBound]` instead of trapping or
    /// producing an empty domain.
    static func linear(_ range: ClosedRange<Int>, step: Int) -> InlineValueDomain {
        guard step > 0 else {
            return InlineValueDomain(knownValid: [range.lowerBound])
        }
        var values: [Int] = []
        var value = range.lowerBound
        while true {
            values.append(value)
            let (next, overflow) = value.addingReportingOverflow(step)
            guard !overflow, next <= range.upperBound else { break }
            value = next
        }
        return InlineValueDomain(knownValid: values)
    }

    /// Explicit values, or `[0]` when the caller's list is invalid. This is
    /// the forgiving companion to `init?`: a stored list that was corrupted
    /// on disk still yields a usable single-value chip.
    static func explicit(_ values: [Int]) -> InlineValueDomain {
        // Callers commonly supply a stride plus its endpoints and the current
        // stored value; those lists are unsorted and contain duplicates. Treat
        // `explicit` as a set, not as a pre-sorted array, so a valid component
        // value cannot silently collapse to the [0] fallback.
        let unique = Array(Set(values)).sorted()
        return InlineValueDomain(unique) ?? InlineValueDomain(knownValid: [0])
    }

    var min: Int { values[0] }
    var max: Int { values[values.count - 1] }
    var count: Int { values.count }

    /// Limits `value` to the domain's closed bounds. On a contiguous domain
    /// (the common case) the result is always an allowed value. On a domain
    /// with gaps an in-range value can pass through unchanged, so callers
    /// that need an allowed value should use `value(at: index(of: value))`.
    func clamp(_ value: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }

    /// Index of the allowed value nearest to `value`; ties choose the lower
    /// value, so the answer never jumps upward on a tie.
    func index(of value: Int) -> Int {
        let last = values.count - 1
        if value <= values[0] { return 0 }
        if value >= values[last] { return last }

        // Lower bound: the first index whose value is >= `value`. The early
        // returns above guarantee the answer lies in 1...last, so the
        // candidates on either side both exist.
        var low = 0
        var high = last
        while low < high {
            let mid = low + (high - low) / 2
            if values[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if values[low] == value { return low }

        let lower = low - 1
        let upper = low
        // Compare the gaps without subtracting two Ints that can span the
        // whole Int range (Int.min to Int.max would overflow).
        let lowerGap = value.subtractingReportingOverflow(values[lower])
        let upperGap = values[upper].subtractingReportingOverflow(value)
        if lowerGap.overflow { return upper }
        if upperGap.overflow { return lower }
        return lowerGap.partialValue <= upperGap.partialValue ? lower : upper
    }

    /// The value at `index`, with the index clamped into range: negative
    /// indices mean the minimum, too-large ones mean the maximum.
    func value(at index: Int) -> Int {
        return values[Swift.min(Swift.max(index, 0), values.count - 1)]
    }

    /// Moves `steps` allowed values away from the allowed value nearest
    /// `value`. The destination index is clamped, so stepping off either end
    /// stays on that end rather than wrapping.
    func stepped(from value: Int, by steps: Int) -> Int {
        let start = index(of: value)
        let (destination, overflow) = start.addingReportingOverflow(steps)
        if overflow {
            return steps > 0 ? self.max : self.min
        }
        return self.value(at: destination)
    }
}

/// How a value is spelled inside the sentence.
enum InlineValueFormat: Equatable {
    case minutes
    case seconds
    case percent
    case hours
    case count

    /// The human label for one value.
    ///
    /// `minutes` folds whole hours into the label (`90` -> "1 hour, 30
    /// minutes") because a sentence reading "90 minutes" is usually less
    /// legible. `seconds` deliberately does not fold into minutes: a scrubber
    /// that occasionally printed "1 minute" would leave the sentence's unit
    /// ambiguous. A negative value keeps a leading "-" and the same unit
    /// agreement; `Int.min` is handled without trapping.
    func label(_ value: Int) -> String {
        switch self {
        case .count:
            return String(value)
        case .percent:
            return "\(value)%"
        case .seconds:
            return Self.spelled(value, singular: "second", plural: "seconds")
        case .hours:
            return Self.spelled(value, singular: "hour", plural: "hours")
        case .minutes:
            return Self.minutes(value)
        }
    }

    private static func spelled(_ value: Int, singular: String, plural: String) -> String {
        let (negative, magnitude) = split(value)
        return signPrefix(negative) + group(magnitude, singular: singular, plural: plural)
    }

    private static func minutes(_ value: Int) -> String {
        let (negative, magnitude) = split(value)
        let body: String
        if magnitude < 60 {
            body = group(magnitude, singular: "minute", plural: "minutes")
        } else {
            let wholeHours = magnitude / 60
            let remainder = magnitude % 60
            let hourText = group(wholeHours, singular: "hour", plural: "hours")
            body = remainder == 0
                ? hourText
                : hourText + ", " + group(remainder, singular: "minute", plural: "minutes")
        }
        return signPrefix(negative) + body
    }

    /// `magnitude` is used so `Int.min` is one larger in magnitude than
    /// `Int.max` without `-value` overflowing.
    private static func split(_ value: Int) -> (negative: Bool, magnitude: UInt) {
        return (value < 0, value.magnitude)
    }

    private static func signPrefix(_ negative: Bool) -> String {
        return negative ? "-" : ""
    }

    private static func group(_ magnitude: UInt, singular: String, plural: String) -> String {
        return "\(magnitude) \(magnitude == 1 ? singular : plural)"
    }
}

/// Pointer travel -> whole steps for a scrub gesture.
///
/// The mapping is a pure function of cumulative translation, so it never
/// drifts: the same pointer position always asks for the same step count. The
/// quotient truncates toward zero rather than rounding, so a 12-point step
/// needs a full 12 points, left and right are exact mirrors, and returning the
/// pointer to its origin always returns to step zero.
struct InlineScrubMapping: Equatable {
    /// Points of travel per whole step. Defaults to 12. A non-positive or
    /// non-finite value is replaced by the default at init so the mapping can
    /// never divide by zero. (`pointsPerStep` stays settable, so
    /// `steps(forTranslation:)` also guards against a later bad assignment.)
    var pointsPerStep: Double

    init(pointsPerStep: Double = 12) {
        self.pointsPerStep = pointsPerStep.isFinite && pointsPerStep > 0 ? pointsPerStep : 12
    }

    /// Converts cumulative horizontal pointer travel to a number of steps.
    ///
    /// `dx` is measured from the start of the gesture (the translation a pan
    /// or drag gesture reports), not from the previous call. Positive is
    /// right. The quotient truncates toward zero: 24 points at 12 points per
    /// step is 2 steps, 23 points is 1, -23 is -1, and any movement under a
    /// full step is 0. NaN has no direction and returns 0; +/-infinity
    /// saturates at the Int bounds instead of trapping.
    func steps(forTranslation dx: Double) -> Int {
        guard dx.isFinite else {
            if dx.isNaN { return 0 }
            return dx < 0 ? Int.min : Int.max
        }
        guard pointsPerStep.isFinite, pointsPerStep > 0 else { return 0 }
        let raw = (dx / pointsPerStep).rounded(.towardZero)
        guard raw.isFinite else { return raw < 0 ? Int.min : Int.max }
        if raw >= Double(Int.max) { return Int.max }
        if raw <= Double(Int.min) { return Int.min }
        return Int(raw)
    }
}

/// One scrub gesture, anchored at the value it began on.
///
/// The session owns the accumulation so a caller can feed it pointer deltas:
/// each `update(translation:)` adds the travel since the previous update and
/// re-derives the value from `anchorValue` using the accumulated total. That
/// has three useful consequences:
///
///   * `update(24)` then `update(-24)` at 12 points per step returns exactly
///     to the anchor, so a reversal retraces the same values;
///   * travel smaller than a whole step is kept rather than discarded per
///     event, so a slow drag still advances once it accumulates 12 points;
///   * truncation happens once against the total, so many tiny updates do not
///     accumulate rounding drift.
///
/// `currentValue` is never outside the domain: moving past either end clamps,
/// and the anchor itself is snapped to the nearest allowed value at init.
struct InlineValueScrubSession: Equatable {
    let domain: InlineValueDomain
    let anchorValue: Int
    let mapping: InlineScrubMapping
    private(set) var currentValue: Int

    /// Travel accumulated since the anchor. It is not public API, but it is
    /// part of equality because two sessions with different residual travel
    /// respond differently to the next update.
    private var accumulatedTranslation: Double

    /// `anchorValue` is snapped to the nearest allowed value; a value already
    /// in the domain is kept exactly.
    init(domain: InlineValueDomain, anchorValue: Int,
         mapping: InlineScrubMapping = .init()) {
        let anchor = domain.value(at: domain.index(of: anchorValue))
        self.domain = domain
        self.anchorValue = anchor
        self.mapping = mapping
        self.currentValue = anchor
        self.accumulatedTranslation = 0
    }

    /// Adds `dx` points of pointer travel and returns the resulting value.
    ///
    /// `dx` is a delta since the previous update (the gesture's current
    /// translation minus the last one it reported), not the gesture's
    /// cumulative translation. A non-finite delta is ignored rather than
    /// poisoning every later update.
    mutating func update(translation dx: Double) -> Int {
        guard dx.isFinite else { return currentValue }
        // Discard travel beyond an endpoint. Otherwise a long overshoot makes
        // reversing feel stuck until the pointer repays all that dead travel.
        let anchorIndex = domain.index(of: anchorValue)
        let points = mapping.pointsPerStep
        let lowerTravel = -Double(anchorIndex) * points
        let upperTravel = Double(domain.values.count - 1 - anchorIndex) * points
        accumulatedTranslation = min(upperTravel, max(lowerTravel, accumulatedTranslation + dx))
        let stepCount = mapping.steps(forTranslation: accumulatedTranslation)
        currentValue = domain.stepped(from: anchorValue, by: stepCount)
        return currentValue
    }

    /// Ends the gesture without committing anything: the anchor and zero
    /// travel are restored, so a later update starts a fresh drag.
    mutating func cancel() {
        accumulatedTranslation = 0
        currentValue = anchorValue
    }

    /// True when the pointer has actually moved the value off its anchor.
    var didChange: Bool { currentValue != anchorValue }
}

/// The policy for a value typed into the chip's editing field.
///
/// Parsing is strict about shape and range, and forgiving only in one
/// documented place: an in-range number that falls between allowed steps
/// snaps to the nearest allowed value as a *proposal*. The caller may accept
/// that proposal or keep the buffer. This type never reads or mutates UI
/// state.
enum InlineEditCommitPolicy {
    /// More than nine digits is rejected as overflow-shaped input, even when
    /// the number would fit an Int. A settings sentence has no business
    /// accepting a 10-digit value, and the cap means the Int conversion below
    /// can never overflow.
    static let maximumDigitCount = 9

    /// Parses a typed buffer.
    ///
    /// Accepted form: an optional leading `+` or `-`, then one to nine ASCII
    /// digits, with leading and trailing whitespace (including newlines)
    /// ignored. Everything else — an empty buffer, an inner space, a decimal
    /// point, a Unicode digit, a bare sign, ten or more digits — is invalid.
    ///
    /// The parsed number must lie inside `domain.min...domain.max`; an
    /// out-of-range number is invalid, never clamped. A number inside those
    /// bounds but between allowed values snaps to the nearest allowed value
    /// (ties choose the lower value). That snap is a **proposal**: the typed
    /// text was not itself an allowed value, and the caller is free to reject
    /// the proposal.
    static func parse(_ text: String, in domain: InlineValueDomain) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var digits = Substring(trimmed)
        var negative = false
        if let first = digits.first, first == "+" || first == "-" {
            negative = first == "-"
            digits = digits.dropFirst()
        }

        guard !digits.isEmpty, digits.count <= maximumDigitCount else { return nil }
        guard digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        guard let magnitude = Int(digits) else { return nil }

        let value = negative ? -magnitude : magnitude
        guard value >= domain.min, value <= domain.max else { return nil }
        return domain.value(at: domain.index(of: value))
    }

    /// The value to commit when the field loses focus.
    ///
    /// A valid buffer commits its parsed proposal; an empty or invalid one
    /// returns nil and the caller restores the pre-edit value. There is no
    /// "empty means minimum" fallback: clearing the field must never silently
    /// rewrite a setting.
    static func resolveOnBlur(_ text: String, in domain: InlineValueDomain) -> Int? {
        return parse(text, in: domain)
    }
}
