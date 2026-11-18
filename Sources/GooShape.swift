import Foundation
import CoreGraphics

/// Analytic damped spring. Every sample uses the same coefficients for a given
/// target; frame subdivision and overshooting cannot change the equation.
struct GooSpring {
    var value = 0.0
    var velocity = 0.0
    private(set) var target = 0.0

    var isSettled: Bool { abs(value - target) < 0.0004 && abs(velocity) < 0.006 }

    mutating func retarget(_ next: Double) {
        guard next.isFinite else { return }
        target = next
    }
    mutating func settle() { value = target; velocity = 0 }

    mutating func advance(_ dt: Double) {
        guard dt.isFinite && dt > 0 else { return }
        let stiffness = target == 1 ? 320.0 : 420.0
        let damping = target == 1 ? 27.0 : 36.0
        let decay = damping / 2
        let frequency = sqrt(stiffness - decay * decay)
        let displacement = value - target
        let sine = (velocity + decay * displacement) / frequency
        let angle = frequency * dt
        let wave = displacement * cos(angle) + sine * sin(angle)
        let derivative = -displacement * frequency * sin(angle)
            + sine * frequency * cos(angle)
        let envelope = exp(-decay * dt)
        value = target + envelope * wave
        velocity = envelope * (derivative - decay * wave)
    }
}

/// A single filled silhouette in AppKit's y-up coordinates. The parent owns
/// placement and interpolation of `body`; normally its top is 30–44pt below
/// `anchor`. `flare` is the desired half-width of the broad meniscus base.
struct GooShape {
    static let bodyCornerRadius: CGFloat = 12

    let body: CGRect
    let path: CGPath
    /// Rounded body only: use to clip content, not as another silhouette fill.
    let bodyPath: CGPath
    let connectionLeft: CGPoint
    let connectionRight: CGPoint

    static func smooth(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        guard high > low else { return value < low ? 0 : 1 }
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    init(body: CGRect, anchor: CGPoint, flare: CGFloat = 120) {
        self.body = body
        let radius = max(0, min(Self.bodyCornerRadius, min(body.width, body.height) / 2))
        bodyPath = CGPath(roundedRect: body, cornerWidth: radius,
                          cornerHeight: radius, transform: nil)
        let top = body.maxY
        let leftEdge = body.minX + radius
        let rightEdge = body.maxX - radius
        // Clamp only as a defensive fallback for anchors outside the panel.
        // Screen-clamped parents should keep the actual anchor in this interval.
        let apexX = min(rightEdge, max(leftEdge, anchor.x))
        let half = max(0, flare.isFinite ? flare : 120)
        let left = max(leftEdge, apexX - half)
        let right = min(rightEdge, apexX + half)
        connectionLeft = CGPoint(x: left, y: top)
        connectionRight = CGPoint(x: right, y: top)
        let outline = CGMutablePath()
        outline.move(to: CGPoint(x: leftEdge, y: top))
        outline.addLine(to: connectionLeft)
        let rise = anchor.y - top
        let leftSpan = apexX - left
        let rightSpan = right - apexX
        if rise > 0 && leftSpan > 0 && rightSpan > 0 {
            // One smooth bell, not a circular cap stitched onto unrelated sides.
            // f(t) = (1-t²)³/(1+k*t²) has zero slope/curvature at
            // the base. Choosing k per side gives BOTH sides the same apex
            // curvature -1/tipRadius, even when screen clamping is asymmetric.
            // A broad 26pt tip spreads the bend into the flanks instead of
            // reading as a bulb with shoulders. Small bodies clamp naturally.
            let tipRadius = min(26, min(leftSpan * leftSpan, rightSpan * rightSpan) / (6 * rise))
            func sample(_ x: CGFloat, span: CGFloat, direction: CGFloat) -> (y: CGFloat, slope: CGFloat) {
                let t = min(1, max(0, abs(x - apexX) / span))
                let k = max(0, span * span / (2 * rise * tipRadius) - 3)
                let u = 1 - t * t
                let denominator = 1 + k * t * t
                let f = u * u * u / denominator
                let derivative = -6 * t * u * u / denominator
                    - 2 * k * t * u * u * u / (denominator * denominator)
                return (top + rise * f, rise * derivative * direction / span)
            }
            // Cubic Hermite samples retain the analytic slope at every join.
            // Evenly spaced x handles make the horizontal derivative positive
            // everywhere; no backwards handle can produce hooks or loops.
            let segments = 96
            for (start, end, span, direction): (CGFloat, CGFloat, CGFloat, CGFloat) in [
                (left, apexX, leftSpan, -1), (apexX, right, rightSpan, 1)
            ] {
                for index in 0..<segments {
                    let x0 = start + (end - start) * CGFloat(index) / CGFloat(segments)
                    let x1 = start + (end - start) * CGFloat(index + 1) / CGFloat(segments)
                    let a = sample(x0, span: span, direction: direction)
                    let b = sample(x1, span: span, direction: direction)
                    let handle = (x1 - x0) / 3
                    outline.addCurve(to: CGPoint(x: x1, y: b.y),
                        control1: CGPoint(x: x0 + handle, y: a.y + handle * a.slope),
                        control2: CGPoint(x: x1 - handle, y: b.y - handle * b.slope))
                }
            }
        } else {
            outline.addLine(to: connectionRight)
        }
        outline.addLine(to: CGPoint(x: rightEdge, y: top))
        let k: CGFloat = 0.5522847498307936
        outline.addCurve(to: CGPoint(x: body.maxX, y: top - radius),
            control1: CGPoint(x: rightEdge + k * radius, y: top),
            control2: CGPoint(x: body.maxX, y: top - radius + k * radius))
        outline.addLine(to: CGPoint(x: body.maxX, y: body.minY + radius))
        outline.addCurve(to: CGPoint(x: rightEdge, y: body.minY),
            control1: CGPoint(x: body.maxX, y: body.minY + radius - k * radius),
            control2: CGPoint(x: rightEdge + k * radius, y: body.minY))
        outline.addLine(to: CGPoint(x: leftEdge, y: body.minY))
        outline.addCurve(to: CGPoint(x: body.minX, y: body.minY + radius),
            control1: CGPoint(x: leftEdge - k * radius, y: body.minY),
            control2: CGPoint(x: body.minX, y: body.minY + radius - k * radius))
        outline.addLine(to: CGPoint(x: body.minX, y: top - radius))
        outline.addCurve(to: CGPoint(x: leftEdge, y: top),
            control1: CGPoint(x: body.minX, y: top - radius + k * radius),
            control2: CGPoint(x: leftEdge - k * radius, y: top))
        outline.closeSubpath()
        path = outline
    }
}
