import Foundation
import CoreGraphics

/// The three commanded destinations. Back is deliberately different from
/// dismissal: a settings cross returns to compact, not to an invisible window.
enum GooPanelRoute { case hidden, compact, settings }

struct GooPanelMotion {
    private(set) var route: GooPanelRoute = .hidden
    var visibility = GooSpring()
    var expansion = GooSpring()
    var isSettled: Bool { visibility.isSettled && expansion.isSettled }

    mutating func request(_ destination: GooPanelRoute) {
        route = destination
        visibility.retarget(destination == .hidden ? 0 : 1)
        expansion.retarget(destination == .settings ? 1 : 0)
    }
    mutating func back() { request(route == .settings ? .compact : .hidden) }
    mutating func toggle() { request(route == .hidden ? .compact : .hidden) }
    mutating func settle() { visibility.settle(); expansion.settle() }
    mutating func advance(_ dt: Double) {
        visibility.advance(dt)
        expansion.advance(dt)
        if visibility.isSettled { visibility.settle() }
        if expansion.isSettled { expansion.settle() }
    }
}

/// Placement is exclusively status-relative; no saved frame, drag origin, or
/// resize grip participates. The surface is reserved once for both sizes.
struct GooPanelLayout {
    let anchor: CGPoint
    let compact: CGRect
    let settings: CGRect
    let surface: CGRect

    init(anchor: CGPoint, visibleScreen: CGRect, compactHeight: CGFloat) {
        self.anchor = anchor
        let gap: CGFloat = 38
        let room = max(140, anchor.y - visibleScreen.minY - gap - 16)
        func placed(_ width: CGFloat, _ height: CGFloat) -> CGRect {
            let w = min(width, max(200, visibleScreen.width - 24))
            let h = min(height, room)
            let x = min(max(anchor.x - w / 2, visibleScreen.minX + 12), visibleScreen.maxX - w - 12)
            return CGRect(x: x, y: anchor.y - gap - h, width: w, height: h)
        }
        compact = placed(320, max(140, compactHeight))
        settings = placed(760, 560)
        surface = compact.union(settings)
            .union(CGRect(x: anchor.x - 10, y: anchor.y - 10, width: 20, height: 10))
            .insetBy(dx: -24, dy: -24)
    }

    func body(for motion: GooPanelMotion) -> CGRect {
        // Limit visible overshoot to a few points, but keep the spring itself
        // unmodified so retargeting always retains its real velocity.
        func bounded(_ value: Double) -> CGFloat {
            // Compress overshoot smoothly instead of hard-clamping a spring
            // into a brief, visibly flat stop at the end of its travel.
            if value > 1 { return CGFloat(1 + 0.012 * (1 - exp(-(value - 1) / 0.012))) }
            if value < 0 { return CGFloat(-0.012 * (1 - exp(value / 0.012))) }
            return CGFloat(value)
        }
        let e = bounded(motion.expansion.value)
        let v = max(0, bounded(motion.visibility.value))
        let width = compact.width + (settings.width - compact.width) * e
        let height = compact.height + (settings.height - compact.height) * e
        let center = compact.midX + (settings.midX - compact.midX) * e
        // A true zero-area endpoint: a minimum 24x8 body lingered through
        // the spring tail and then popped out when the NSWindow ordered out.
        let grownWidth = max(0, width * v)
        let grownHeight = max(0, height * v)
        let top = anchor.y - 38 * v
        let x = anchor.x + (center - anchor.x) * v - grownWidth / 2
        return CGRect(x: x, y: top - grownHeight, width: grownWidth, height: grownHeight)
    }
}
