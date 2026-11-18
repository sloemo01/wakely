import Foundation
import CoreGraphics

// A pure model of the component-card -> wide-detail-header morph.
//
// This file deliberately imports only Foundation and CoreGraphics. It owns no
// views, no animators, and no global state, so the same arithmetic can drive an
// AppKit overlay, a snapshot runner, or the executable tests in
// Tests/CardMorphModelTests.swift.
//
// The timings below are proposed approximations for a motion fit, not measured
// properties of the reference recording. Comments call out which choices are
// choreography and which are only engineering placeholders.

/// One independently animated layer of the morph.
///
/// The tracks are intentionally coarse: a renderer can fold several visual
/// details (for example the card border and its fill) under `surface` instead
/// of inventing a separate track for every layer.
enum CardMorphTrack: CaseIterable, Equatable {
    case surface
    case icon
    case title
    case description
    case toggle
    case paragraph
    case navigation
    case dim
}

/// Which endpoint is the destination of this particular transition.
enum CardMorphDirection: Equatable {
    case opening
    case closing
}

/// A duration plus the progress law used for that direction.
///
/// `curve` is pure and monotonic. Endpoints are exact even for floating-point
/// inputs at or beyond the ends of the range.
struct CardMorphTiming: Equatable {
    /// Proposed opening duration. The reference's opening principal geometry
    /// was estimated around 0.47-0.50 s; this value is a rounded engineering
    /// choice, not a measured constant.
    static let opening = CardMorphTiming(duration: 0.50, law: .opening)

    /// Proposed closing duration. Returns looked shorter than openings in the
    /// sampled frames; 0.36 s is a calm but noticeably quicker return. Again,
    /// this is an approximation for tuning, not a claim about the reference.
    static let closing = CardMorphTiming(duration: 0.36, law: .closing)

    /// Total wall-clock duration in seconds.
    let duration: Double

    private let law: Law

    private enum Law {
        case opening
        case closing
    }

    /// Creates a timing with an arbitrary duration using the opening progress
    /// law. The named `.opening` and `.closing` values are the supported pair
    /// for the morph itself; this initializer exists so the arithmetic can be
    /// exercised with other durations.
    init(duration: Double) {
        self.init(duration: duration, law: .opening)
    }

    private init(duration: Double, law: Law) {
        self.duration = duration
        self.law = law
    }

    /// Normalized eased progress for a normalized raw progress `p`.
    ///
    /// Both laws are monotonic on 0...1, satisfy f(0) = 0 and f(1) = 1, and
    /// clamp inputs outside that interval.
    func curve(_ p: Double) -> Double {
        // Special-casing the ends guarantees exact endpoints, including when a
        // renderer asks for f(duration) after accumulating floating-point time.
        if p.isNaN || p <= 0 { return 0 }
        if p >= 1 { return 1 }

        switch law {
        case .opening:
            // Fast early travel with a gentle settle.
            //
            // Ease-out quint alone spends almost all of its displacement in
            // the first third of the duration and then barely moves; blending
            // it with smoothstep keeps the early lead while giving the final
            // few points a little more visible travel. 70/30 is a proposed
            // approximation, not a measured reference curve.
            let easeOutQuint = 1 - pow(1 - p, 5)
            let smoothstep = p * p * (3 - 2 * p)
            return cardMorphClamp01(0.7 * easeOutQuint + 0.3 * smoothstep)

        case .closing:
            // A return should feel calmer than the opening snap. Plain
            // smoothstep has zero velocity at both ends and reads as a
            // deliberate retreat rather than another launch. Proposed
            // approximation for the return leg, not reference evidence.
            return cardMorphClamp01(p * p * (3 - 2 * p))
        }
    }
}

/// A retargetable semantic presentation for the card <-> detail route.
///
/// `progress` is always 0 at the resting card and 1 at the settled wide header,
/// for both directions. That is deliberately different from the elapsed-time
/// geometry below: reversing must preserve the current position and velocity,
/// not start a new endpoint animation.
struct CardMorphPresentation: Equatable {
    /// Fixed analytic coefficients. Critical damping keeps the surface from
    /// bouncing while retaining momentum across an interruption.
    static let openingStiffness = 196.0
    static let closingStiffness = 320.0
    static let valueTolerance = 0.001
    static let velocityTolerance = 0.02

    private(set) var progress = 0.0
    private(set) var velocity = 0.0
    private(set) var target = 0.0

    var isAnimating: Bool { abs(progress - target) > Self.valueTolerance || abs(velocity) > Self.velocityTolerance }
    var isSettled: Bool { !isAnimating }

    mutating func retarget(to destination: Double) {
        guard destination.isFinite else { return }
        target = min(1, max(0, destination))
    }

    mutating func open() { retarget(to: 1) }

    mutating func close() { retarget(to: 0) }

    mutating func settle() {
        progress = target
        velocity = 0
    }

    /// Advances with real elapsed time and returns the endpoint exactly once
    /// when a moving spring reaches its target.
    mutating func advance(_ dt: Double) -> CardMorphEndpoint? {
        guard dt.isFinite, dt > 0 else { return nil }
        let wasMoving = isAnimating
        let stiffness = target >= 0.5 ? Self.openingStiffness : Self.closingStiffness
        let omega = sqrt(stiffness)
        let displacement = progress - target
        // Critically damped analytic solution. A repeated root avoids both
        // overshoot and the singular underdamped sine term.
        let carried = displacement + (velocity + omega * displacement) * dt
        let envelope = exp(-omega * dt)
        progress = target + carried * envelope
        velocity = envelope * (velocity - omega * (velocity + omega * displacement) * dt)
        guard wasMoving, isSettled else { return nil }
        let endpoint: CardMorphEndpoint = target >= 0.5 ? .opened : .closed
        settle()
        return endpoint
    }
}

enum CardMorphEndpoint: Equatable {
    case opened
    case closed
}

/// Layout defaults shared by the morph and its callers.
///
/// These are defaults for the proposed layout, not measurements recovered from
/// the recording. The same names are exposed on the type (for the standard
/// defaults) and on an instance (for callers that prefer to pass a metrics
/// value around); the initializer still permits overrides.
struct CardMorphMetrics {
    static let settledCornerRadius: CGFloat = 14
    static let sourceCornerRadius: CGFloat = 14
    static let headerHeight: CGFloat = 112
    static let contentInset: CGFloat = 28

    let settledCornerRadius: CGFloat
    let sourceCornerRadius: CGFloat
    let headerHeight: CGFloat
    let contentInset: CGFloat

    init(
        settledCornerRadius: CGFloat = CardMorphMetrics.settledCornerRadius,
        sourceCornerRadius: CGFloat = CardMorphMetrics.sourceCornerRadius,
        headerHeight: CGFloat = CardMorphMetrics.headerHeight,
        contentInset: CGFloat = CardMorphMetrics.contentInset
    ) {
        self.settledCornerRadius = settledCornerRadius
        self.sourceCornerRadius = sourceCornerRadius
        self.headerHeight = headerHeight
        self.contentInset = contentInset
    }
}

/// Geometry and per-track progress for one card <-> header morph.
///
/// `source` always names the resting component card and `destination` always names
/// the settled wide header. Opening walks source -> destination; closing walks
/// destination -> source and uses the closing timing. Corner curvature follows
/// the same direction: 12 pt at the card, 14 pt at the settled header.
struct CardMorphGeometry {
    let source: CGRect
    let destination: CGRect
    let timing: CardMorphTiming

    private let direction: CardMorphDirection

    init(source: CGRect, destination: CGRect, direction: CardMorphDirection) {
        self.source = source
        self.destination = destination
        self.direction = direction
        switch direction {
        case .opening:
            self.timing = .opening
        case .closing:
            self.timing = .closing
        }
    }

    var isOpening: Bool { direction == .opening }

    var duration: Double { timing.duration }

    // MARK: - Helpers

    /// Clamps to 0...1, treating NaN as 0 and infinities as their nearest edge.
    static func clamp01(_ value: Double) -> Double {
        cardMorphClamp01(value)
    }

    /// Normalizes `p` into `max(0, min(1, (p - from) / (to - from)))`.
    ///
    /// The window is order-independent (`from > to` is normalized), and a
    /// zero-width window becomes a step at its single coordinate instead of
    /// dividing by zero.
    static func window(_ p: Double, from: Double, to: Double) -> Double {
        let lower = min(from, to)
        let upper = max(from, to)
        guard upper > lower else {
            return p >= upper ? 1 : 0
        }
        return cardMorphClamp01((p - lower) / (upper - lower))
    }

    // MARK: - Surface

    /// Linear elapsed-time progress in 0...1. Negative elapsed maps to 0 and
    /// elapsed at or beyond the duration maps to 1.
    func rawProgress(at elapsed: Double) -> Double {
        guard timing.duration > 0, timing.duration.isFinite else {
            // A caller-provided zero/negative/non-finite duration should not
            // produce a NaN or an infinite quotient.
            if elapsed > 0 { return 1 }
            return 0
        }
        return Self.clamp01(elapsed / timing.duration)
    }

    /// Semantic surface geometry. `presentation` is 0 at the card and 1 at the
    /// settled header regardless of which way the route is travelling.
    func surfaceFrame(presentation: Double) -> CGRect {
        let p = Self.clamp01(presentation)
        if p <= 0 { return source }
        if p >= 1 { return destination }
        // The spring is already the timing law. Do not apply a second,
        // direction-dependent ease here: flipping direction at the same
        // semantic progress must not jump to another curve family.
        let t = CGFloat(p)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return CGRect(x: lerp(source.minX, destination.minX),
                      y: lerp(source.minY, destination.minY),
                      width: lerp(source.width, destination.width),
                      height: lerp(source.height, destination.height))
    }

    func cornerRadius(presentation: Double) -> CGFloat {
        let p = Self.clamp01(presentation)
        return CardMorphMetrics.sourceCornerRadius
            + (CardMorphMetrics.settledCornerRadius - CardMorphMetrics.sourceCornerRadius)
            * CGFloat(p)
    }

    /// Destination-content presence for a semantic presentation. The same
    /// curve is used in both directions because presentation itself reverses.
    func contentPresence(presentation: Double) -> Double {
        Self.window(Self.clamp01(presentation), from: 0.58, to: 0.96)
    }

    func navigationPresence(presentation: Double) -> Double {
        Self.window(Self.clamp01(presentation), from: 0.62, to: 1.00)
    }

    func backgroundPresence(presentation: Double) -> Double {
        Self.window(Self.clamp01(presentation), from: 0.50, to: 0.86)
    }

    func catalogDim(presentation: Double) -> Double {
        Self.window(Self.clamp01(presentation), from: 0.02, to: 0.52)
    }

    /// The moving card surface. x, y, width, and height are interpolated
    /// separately, so the surface never performs a uniform scale; that is the
    /// central geometric property of this morph.
    func surfaceFrame(at elapsed: Double) -> CGRect {
        let progress = rawProgress(at: elapsed)
        let from = isOpening ? source : destination
        let to = isOpening ? destination : source

        // Return the exact endpoint values rather than recomputing them with
        // lerp arithmetic; callers compare these rects directly.
        if progress <= 0 { return from }
        if progress >= 1 { return to }

        let t = CGFloat(timing.curve(progress))
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            a + (b - a) * t
        }
        return CGRect(
            x: lerp(from.minX, to.minX),
            y: lerp(from.minY, to.minY),
            width: lerp(from.width, to.width),
            height: lerp(from.height, to.height)
        )
    }

    /// Corner radius in points. 12 pt at the source card and 14 pt at the
    /// settled header, eased by the same curve as the surface so the outline
    /// changes in step with the frame. Monotonic on each leg.
    func cornerRadius(at elapsed: Double) -> CGFloat {
        let progress = rawProgress(at: elapsed)
        let from = isOpening ? CardMorphMetrics.sourceCornerRadius : CardMorphMetrics.settledCornerRadius
        let to = isOpening ? CardMorphMetrics.settledCornerRadius : CardMorphMetrics.sourceCornerRadius

        if progress <= 0 { return from }
        if progress >= 1 { return to }

        return from + (to - from) * CGFloat(timing.curve(progress))
    }

    // MARK: - Tracks

    /// Progress in that track's own window, always in 0...1.
    ///
    /// Non-dim windows describe destination-content presence: content is
    /// hidden at the start of the window, present at its end. They are shared
    /// by both directions because they describe the content at the morph's
    /// destination rather than a separate removal animation. Dim is the
    /// backdrop exception: it fills in early while opening and clears early
    /// while closing.
    func trackProgress(for track: CardMorphTrack, at elapsed: Double) -> Double {
        let progress = rawProgress(at: elapsed)
        switch track {
        case .surface:
            return progress
        case .icon, .title, .description, .toggle:
            return Self.window(progress, from: 0.05, to: 0.90)
        case .paragraph:
            return Self.window(progress, from: 0.58, to: 0.96)
        case .navigation:
            return Self.window(progress, from: 0.62, to: 1.00)
        case .dim:
            let end: Double = isOpening ? 0.55 : 0.60
            return Self.window(progress, from: 0, to: end)
        }
    }

    /// Opacity in 0...1 for one layer at the current elapsed time.
    ///
    /// The surface never fades. Dim reverses with direction: opening fades the
    /// scrim in over 0...0.55; closing fades it out over 0...0.60 of the
    /// return. Other tracks use their presence progress directly.
    func opacity(for track: CardMorphTrack, at elapsed: Double) -> Double {
        switch track {
        case .surface:
            return 1
        case .dim:
            let presence = trackProgress(for: .dim, at: elapsed)
            return isOpening ? presence : 1 - presence
        default:
            return trackProgress(for: track, at: elapsed)
        }
    }
}

/// File-private clamp used by both the timing law and the public helper.
private func cardMorphClamp01(_ value: Double) -> Double {
    if value.isNaN { return 0 }
    if value <= 0 { return 0 }
    if value >= 1 { return 1 }
    return value
}
