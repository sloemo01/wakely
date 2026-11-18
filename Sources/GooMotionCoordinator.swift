import Foundation
import CoreGraphics

/// Owns the three presentation tracks for one FluidOpen panel.
///
/// This is deliberately not an app-wide animation singleton. Submenu motion,
/// card/detail travel, sheets and SwiftUI controls have separate owners; making
/// them share this clock would let unrelated updates reset one another.
struct GooMotionCoordinator {
    private(set) var motion = GooPanelMotion()
    private(set) var compactHeight = GooSpring()
    private(set) var routeRevision = 0
    private(set) var contentRevision = 0

    var route: GooPanelRoute { motion.route }
    var isSettled: Bool { motion.isSettled && compactHeight.isSettled }
    var compactHeightPoints: CGFloat { CGFloat(compactHeight.value) * Self.heightUnit }
    var compactTargetPoints: CGFloat { CGFloat(compactHeight.target) * Self.heightUnit }

    static let heightUnit: CGFloat = 620

    mutating func request(_ destination: GooPanelRoute) {
        guard motion.route != destination else { return }
        motion.request(destination)
        routeRevision &+= 1
    }

    mutating func toggle() {
        let destination: GooPanelRoute = motion.route == .hidden ? .compact : .hidden
        request(destination)
    }

    mutating func back() {
        let destination: GooPanelRoute = motion.route == .settings ? .compact : .hidden
        request(destination)
    }

    /// Height is content-driven and independent of the route. The same target
    /// is a no-op and never resets a live opening or dismissal spring.
    mutating func retargetCompactHeight(points: CGFloat) {
        guard points.isFinite else { return }
        let normalized = Double(max(0, points) / Self.heightUnit)
        guard abs(compactHeight.target - normalized) > 0.00001 else { return }
        compactHeight.retarget(normalized)
        contentRevision &+= 1
    }

    mutating func settle() {
        motion.settle()
        compactHeight.settle()
    }

    mutating func settleCompactHeight() { compactHeight.settle() }

    mutating func advance(_ dt: Double) {
        motion.advance(dt)
        compactHeight.advance(dt)
        if compactHeight.isSettled { compactHeight.settle() }
    }

    var snapshot: GooPanelSnapshot {
        GooPanelSnapshot(route: motion.route,
                         visibility: motion.visibility.value,
                         expansion: motion.expansion.value,
                         compactHeightPoints: compactHeightPoints,
                         routeRevision: routeRevision,
                         contentRevision: contentRevision,
                         isSettled: isSettled)
    }
}

/// Immutable values the host renders. Keeping this separate from AppKit makes
/// route/interruption behavior testable without a real window.
struct GooPanelSnapshot: Equatable {
    let route: GooPanelRoute
    let visibility: Double
    let expansion: Double
    let compactHeightPoints: CGFloat
    let routeRevision: Int
    let contentRevision: Int
    let isSettled: Bool
}
