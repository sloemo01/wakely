import Foundation
import CoreGraphics

@main
struct GooMotionCoordinatorTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }

    static func main() {
        var coordinator = GooMotionCoordinator()
        check(coordinator.route == .hidden, "starts hidden")
        check(coordinator.routeRevision == 0, "no route revision before a request")

        coordinator.toggle()
        check(coordinator.route == .compact, "toggle opens compact")
        check(coordinator.routeRevision == 1, "route revision increments once")

        for _ in 0..<30 { coordinator.advance(1.0 / 120.0) }
        let visibility = coordinator.motion.visibility.value
        let velocity = coordinator.motion.visibility.velocity
        coordinator.request(.settings)
        check(coordinator.motion.visibility.value == visibility,
              "changed route preserves visibility position")
        check(coordinator.motion.visibility.velocity == velocity,
              "changed route preserves visibility velocity")

        let revision = coordinator.routeRevision
        coordinator.request(.settings)
        check(coordinator.routeRevision == revision, "same route is not a new revision")

        coordinator.retargetCompactHeight(points: 300)
        let heightRevision = coordinator.contentRevision
        let heightValue = coordinator.compactHeight.value
        let heightVelocity = coordinator.compactHeight.velocity
        coordinator.retargetCompactHeight(points: 300)
        check(coordinator.contentRevision == heightRevision, "same height target is a no-op")
        check(coordinator.compactHeight.value == heightValue, "same height keeps value")
        check(coordinator.compactHeight.velocity == heightVelocity, "same height keeps velocity")
        check(coordinator.routeRevision == revision, "height never changes route revision")

        coordinator.retargetCompactHeight(points: 420)
        check(coordinator.contentRevision == heightRevision + 1, "height change increments content revision")
        check(coordinator.routeRevision == revision, "height change keeps route revision")
        check(abs(coordinator.compactTargetPoints - 420) < 0.0001, "height is stored in points")

        for _ in 0..<500 { coordinator.advance(1.0 / 120.0) }
        check(coordinator.isSettled, "all tracks settle")
        check(abs(coordinator.compactHeightPoints - 420) < 0.001, "height settles at the requested points")

        var malformed = GooMotionCoordinator()
        malformed.toggle()
        let before = malformed.snapshot
        malformed.advance(.nan)
        malformed.advance(.infinity)
        malformed.advance(-1)
        check(malformed.snapshot.visibility == before.visibility,
              "invalid frame deltas leave the snapshot intact")

        let snapshot = coordinator.snapshot
        check(snapshot.isSettled && snapshot.route == .settings, "snapshot carries settled route")
        print("PASS: \(checks) per-panel coordinator checks")
    }
}
