import Foundation
import CoreGraphics

// Executable tests for CardMorphModel.swift.
//
// Build from the repository root:
//   swiftc -swift-version 5 -target arm64-apple-macos14.0 \
//     Sources/CardMorphModel.swift Tests/CardMorphModelTests.swift \
//     -o build/card-morph-tests && build/card-morph-tests

@main struct CardMorphModelTests {
    static let source = CGRect(x: 24, y: 148, width: 320, height: 96)
    static let destination = CGRect(x: 16, y: 44, width: 960, height: 112)

    static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
            rect.size.width.isFinite && rect.size.height.isFinite
    }

    static func inUnit(_ value: Double) -> Bool {
        value >= 0 && value <= 1
    }

    static func main() {
        endpoints()
        surfaceMotion()
        curves()
        trackWindows()
        closingAndDegenerateInputs()
        progressClamping()
        print("PASS: all CardMorphModel checks (6 groups)")
    }

    // 1. Endpoints are exact for the opening leg.
    static func endpoints() {
        let opening = CardMorphGeometry(source: source, destination: destination, direction: .opening)

        precondition(opening.surfaceFrame(at: 0) == source, "opening at t=0 must equal the source rect")
        precondition(opening.surfaceFrame(at: opening.duration) == destination,
                     "opening at t=duration must equal the destination rect")
        precondition(opening.surfaceFrame(at: opening.duration + 5) == destination,
                     "opening after the end must stay at the destination rect")
        precondition(opening.surfaceFrame(at: -1) == source,
                     "opening before the start must stay at the source rect")

        precondition(opening.cornerRadius(at: 0) == CardMorphMetrics.sourceCornerRadius,
                     "opening must start at the source corner radius")
        precondition(opening.cornerRadius(at: opening.duration) == CardMorphMetrics.settledCornerRadius,
                     "opening must settle at the settled corner radius")
        precondition(CardMorphMetrics.sourceCornerRadius == 14, "source radius matches the card")
        precondition(CardMorphMetrics.settledCornerRadius == 14, "settled radius default")
        precondition(CardMorphMetrics.headerHeight == 112, "header height default")
        precondition(CardMorphMetrics.contentInset == 28, "content inset default")

        let defaults = CardMorphMetrics()
        precondition(defaults.settledCornerRadius == 14, "instance settled radius default")
        precondition(defaults.sourceCornerRadius == 14, "instance source radius matches the card")
        precondition(defaults.headerHeight == 112, "instance header height default")
        precondition(defaults.contentInset == 28, "instance content inset default")

        print("PASS: endpoints (surface and corner radius)")
    }

    // 2. Width grows monotonically while height stays between the endpoints.
    static func surfaceMotion() {
        let opening = CardMorphGeometry(source: source, destination: destination, direction: .opening)
        let minHeight = min(source.height, destination.height)
        let maxHeight = max(source.height, destination.height)
        var previousWidth = -Double.greatestFiniteMagnitude

        for sample in 0...200 {
            let elapsed = opening.duration * Double(sample) / 200
            let frame = opening.surfaceFrame(at: elapsed)
            precondition(isFinite(frame), "surface frame must be finite at sample \(sample)")
            precondition(frame.width >= 0, "surface width must not become negative")
            precondition(frame.width >= previousWidth - 1e-9,
                         "opening width must be monotonic at sample \(sample)")
            precondition(frame.height >= minHeight - 1e-9 && frame.height <= maxHeight + 1e-9,
                         "height must interpolate between source and destination at sample \(sample)")
            previousWidth = frame.width
        }

        precondition(previousWidth == destination.width, "opening must finish at destination width")
        print("PASS: monotonic opening width and bounded height")
    }

    // 3. Both curves have exact endpoints, stay in 0...1, and are monotonic.
    static func curves() {
        for timing in [CardMorphTiming.opening, CardMorphTiming.closing] {
            precondition(timing.curve(0) == 0, "curve(0) must be exactly 0")
            precondition(timing.curve(1) == 1, "curve(1) must be exactly 1")
            precondition(timing.curve(-0.5) == 0, "curve must clamp below 0")
            precondition(timing.curve(1.5) == 1, "curve must clamp above 1")

            var previous = -Double.greatestFiniteMagnitude
            for sample in 0...200 {
                let p = Double(sample) / 200
                let value = timing.curve(p)
                precondition(inUnit(value), "curve value must stay in 0...1 at p=\(p)")
                precondition(value >= previous - 1e-12, "curve must be monotonic at p=\(p)")
                previous = value
            }
        }

        precondition(CardMorphTiming.opening.curve(0.25) > CardMorphTiming.closing.curve(0.25),
                     "opening should travel faster early than closing")
        precondition(CardMorphTiming.closing.curve(0.5) == 0.5,
                     "smoothstep closing curve should cross 0.5 at p=0.5")
        print("PASS: curve endpoints, range, and monotonicity")
    }

    // 4. Track windows clamp and paragraph/navigation reveal late.
    static func trackWindows() {
        let opening = CardMorphGeometry(source: source, destination: destination, direction: .opening)

        for track in CardMorphTrack.allCases {
            precondition(opening.trackProgress(for: track, at: -10) == 0,
                         "\(track) progress must clamp to 0 before the start")
            precondition(opening.trackProgress(for: track, at: opening.duration * 2) == 1,
                         "\(track) progress must clamp to 1 after the end")
        }

        precondition(opening.trackProgress(for: .paragraph, at: 0) == 0,
                     "paragraph must start hidden")
        precondition(opening.trackProgress(for: .paragraph, at: opening.duration) == 1,
                     "paragraph must end visible")
        precondition(opening.trackProgress(for: .paragraph, at: opening.duration * 0.30) == 0,
                     "paragraph must still be hidden before its window")
        precondition(opening.trackProgress(for: .navigation, at: opening.duration * 0.50) == 0,
                     "navigation must still be hidden before its window")

        let midParagraph = opening.trackProgress(for: .paragraph, at: opening.duration * 0.77)
        precondition(midParagraph > 0 && midParagraph < 1,
                     "paragraph must be mid-fade inside its window")
        let midNavigation = opening.trackProgress(for: .navigation, at: opening.duration * 0.81)
        precondition(midNavigation > 0 && midNavigation < 1,
                     "navigation must be mid-fade inside its window")
        precondition(opening.opacity(for: .paragraph, at: 0) == 0, "paragraph opacity starts hidden")
        precondition(opening.opacity(for: .paragraph, at: opening.duration) == 1,
                     "paragraph opacity ends visible")
        precondition(opening.opacity(for: .surface, at: 0) == 1, "surface opacity never fades")

        precondition(CardMorphGeometry.clamp01(-3) == 0, "clamp01 lower bound")
        precondition(CardMorphGeometry.clamp01(0.25) == 0.25, "clamp01 pass-through")
        precondition(CardMorphGeometry.clamp01(9) == 1, "clamp01 upper bound")
        precondition(CardMorphGeometry.window(0.5, from: 0.25, to: 0.75) == 0.5, "window midpoint")
        precondition(CardMorphGeometry.window(-1, from: 0.25, to: 0.75) == 0, "window before")
        precondition(CardMorphGeometry.window(2, from: 0.25, to: 0.75) == 1, "window after")
        precondition(CardMorphGeometry.window(0.5, from: 0.5, to: 0.5) == 1,
                     "zero-width window is a safe step")
        precondition(CardMorphGeometry.window(0.2, from: 0.5, to: 0.5) == 0,
                     "zero-width window below its coordinate")
        print("PASS: track windows and helper clamping")
    }

    // 5. Closing uses the closing timing, reverses dim, and never produces NaN.
    static func closingAndDegenerateInputs() {
        let opening = CardMorphGeometry(source: source, destination: destination, direction: .opening)
        let closing = CardMorphGeometry(source: source, destination: destination, direction: .closing)

        precondition(!closing.isOpening && opening.isOpening, "directions must be reported correctly")
        precondition(closing.duration == CardMorphTiming.closing.duration, "closing duration")
        precondition(closing.timing == CardMorphTiming.closing, "closing timing law")
        precondition(opening.duration == CardMorphTiming.opening.duration, "opening duration")
        precondition(closing.duration != opening.duration, "the two directions use distinct timings")

        // Closing runs destination -> source.
        precondition(closing.surfaceFrame(at: 0) == destination,
                     "closing must start at the settled destination rect")
        precondition(closing.surfaceFrame(at: closing.duration) == source,
                     "closing must return to the source rect")
        precondition(closing.cornerRadius(at: 0) == CardMorphMetrics.settledCornerRadius,
                     "closing must start at the settled radius")
        precondition(closing.cornerRadius(at: closing.duration) == CardMorphMetrics.sourceCornerRadius,
                     "closing must return to the source radius")

        // Dim reverses: fades in on opening, out early on closing.
        precondition(opening.opacity(for: .dim, at: 0) == 0, "opening dim starts clear")
        precondition(opening.opacity(for: .dim, at: opening.duration) == 1, "opening dim settles full")
        precondition(closing.opacity(for: .dim, at: 0) == 1, "closing dim starts full")
        precondition(closing.opacity(for: .dim, at: closing.duration) == 0, "closing dim ends clear")

        var previousOpeningDim = -Double.greatestFiniteMagnitude
        var previousClosingDim = Double.greatestFiniteMagnitude
        for sample in 0...100 {
            let p = Double(sample) / 100
            let openingDim = opening.opacity(for: .dim, at: opening.duration * p)
            let closingDim = closing.opacity(for: .dim, at: closing.duration * p)
            precondition(inUnit(openingDim) && inUnit(closingDim), "dim opacity must stay in 0...1")
            precondition(openingDim >= previousOpeningDim - 1e-12, "opening dim must fade in")
            precondition(closingDim <= previousClosingDim + 1e-12, "closing dim must fade out")
            previousOpeningDim = openingDim
            previousClosingDim = closingDim
        }

        // Zero-size rects, zero-origin frames, and negative/oversized elapsed
        // values must stay finite for every public numeric accessor.
        let zeroRect = CGRect(x: 0, y: 0, width: 0, height: 0)
        let flatRect = CGRect(x: 12, y: 8, width: 0, height: 0)
        for geometry in [
            CardMorphGeometry(source: zeroRect, destination: flatRect, direction: .opening),
            CardMorphGeometry(source: flatRect, destination: zeroRect, direction: .closing)
        ] {
            for elapsed in [-2.0, 0, 0.05, geometry.duration * 0.5, geometry.duration, geometry.duration * 3] {
                let frame = geometry.surfaceFrame(at: elapsed)
                precondition(isFinite(frame), "degenerate surface frame must be finite at \(elapsed)")
                let radius = geometry.cornerRadius(at: elapsed)
                precondition(radius.isFinite, "degenerate corner radius must be finite at \(elapsed)")
                for track in CardMorphTrack.allCases {
                    let progress = geometry.trackProgress(for: track, at: elapsed)
                    let opacity = geometry.opacity(for: track, at: elapsed)
                    precondition(progress.isFinite, "\(track) progress must be finite at \(elapsed)")
                    precondition(opacity.isFinite, "\(track) opacity must be finite at \(elapsed)")
                    precondition(inUnit(progress), "\(track) progress must stay in 0...1")
                    precondition(inUnit(opacity), "\(track) opacity must stay in 0...1")
                }
            }
        }

        print("PASS: closing timing, reversed dim, and finite degenerate geometry")
    }

    // 6. rawProgress clamps at both ends and the shipped durations are positive.
    static func progressClamping() {
        let opening = CardMorphGeometry(source: source, destination: destination, direction: .opening)
        let closing = CardMorphGeometry(source: source, destination: destination, direction: .closing)

        precondition(opening.duration > 0, "opening duration must be positive")
        precondition(closing.duration > 0, "closing duration must be positive")
        precondition(CardMorphTiming.opening.duration > 0, "opening timing duration must be positive")
        precondition(CardMorphTiming.closing.duration > 0, "closing timing duration must be positive")

        precondition(opening.rawProgress(at: -10) == 0, "negative elapsed clamps to 0")
        precondition(opening.rawProgress(at: -0.0001) == 0, "just-below-zero elapsed clamps to 0")
        precondition(opening.rawProgress(at: 0) == 0, "elapsed zero is progress zero")
        precondition(opening.rawProgress(at: opening.duration / 2) == 0.5, "half duration is half progress")
        precondition(opening.rawProgress(at: opening.duration) == 1, "duration is progress one")
        precondition(opening.rawProgress(at: opening.duration + 10) == 1, "oversized elapsed clamps to 1")
        precondition(opening.rawProgress(at: Double.greatestFiniteMagnitude) == 1,
                     "huge elapsed clamps to 1")
        precondition(closing.rawProgress(at: -1) == 0, "closing negative elapsed clamps to 0")
        precondition(closing.rawProgress(at: closing.duration * 2) == 1,
                     "closing oversized elapsed clamps to 1")

        let custom = CardMorphTiming(duration: 2)
        precondition(custom.duration == 2 && custom.duration > 0, "custom duration is preserved")
        precondition(custom.curve(0) == 0 && custom.curve(1) == 1, "custom timing curve endpoints")

        print("PASS: rawProgress clamping and positive durations")
    }
}
