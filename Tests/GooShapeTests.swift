import Foundation
import CoreGraphics

@main
struct GooShapeTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func inspect(_ shape: GooShape, anchor: CGPoint) {
        var moves = 0
        var closes = 0
        var curves = [[CGPoint]]()
        var current = CGPoint.zero
        shape.path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint:
                moves += 1; current = e.points[0]
            case .addLineToPoint:
                current = e.points[0]
            case .addCurveToPoint:
                curves.append([current, e.points[0], e.points[1], e.points[2]])
                current = e.points[2]
            case .closeSubpath: closes += 1
            default: check(false, "unexpected quadratic")
            }
        }
        check(moves == 1 && closes == 1, "one closed fill, no overlapping subpaths")
        check(curves.count > 8, "smooth bell sampling plus four panel corners")
        let bounds = shape.path.boundingBoxOfPath
        check([bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy { $0.isFinite }, "finite bounds")
        check(abs(bounds.maxY - anchor.y) < 1e-8, "rounded cap touches but never exceeds anchor ceiling")
        check(abs(bounds.minY - shape.body.minY) < 1e-8, "body bottom remains visible")
        check(abs(bounds.minX - shape.body.minX) < 1e-8 && abs(bounds.maxX - shape.body.maxX) < 1e-8, "body edges retained")
        let bridge = Array(curves.dropLast(4))
        for c in bridge {
            check(zip(c, c.dropFirst()).allSatisfy { $0.x <= $1.x }, "monotonic control polygon rules out horizontal self-loops")
            for i in 0...100 {
                let t = CGFloat(i) / 100
                let u = 1 - t
                let dx = 3*u*u*(c[1].x-c[0].x) + 6*u*t*(c[2].x-c[1].x) + 3*t*t*(c[3].x-c[2].x)
                let y = u*u*u*c[0].y + 3*u*u*t*c[1].y + 3*u*t*t*c[2].y + t*t*t*c[3].y
                check(dx >= -1e-9, "nonnegative horizontal derivative")
                check(y <= anchor.y + 1e-9 && y >= shape.body.maxY - 1e-9, "bridge within ceiling and body top")
            }
        }
        check(bridge[0][1].x > bridge[0][0].x && bridge[0][1].y == shape.body.maxY, "left join continues rightward horizontally")
        let last = bridge[bridge.count - 1]
        check(last[2].x < last[3].x && last[2].y == shape.body.maxY, "right join arrives rightward horizontally")
        func secondDerivative(_ c: [CGPoint], atEnd: Bool) -> CGFloat {
            let width = c[3].x - c[0].x
            let d2 = atEnd ? c[3].y - 2*c[2].y + c[1].y : c[2].y - 2*c[1].y + c[0].y
            return 6*d2/(width*width)
        }
        let leftSpan = anchor.x - shape.connectionLeft.x
        let rightSpan = shape.connectionRight.x - anchor.x
        let rise = anchor.y - shape.body.maxY
        let tipRadius = min(26, min(leftSpan*leftSpan, rightSpan*rightSpan)/(6*rise))
        let apexLeft = bridge[bridge.count/2-1]
        let apexRight = bridge[bridge.count/2]
        check(abs(secondDerivative(apexLeft, atEnd: true) + 1/tipRadius) * tipRadius < 0.02, "left apex curvature matches smooth bell radius")
        check(abs(secondDerivative(apexRight, atEnd: false) + 1/tipRadius) * tipRadius < 0.02, "right apex curvature matches same radius")
        check(abs(secondDerivative(apexLeft, atEnd: true) - secondDerivative(apexRight, atEnd: false)) * tipRadius < 0.02, "no apex curvature kink with asymmetric spans")
        check(abs(secondDerivative(bridge[0], atEnd: false))*leftSpan*leftSpan/rise < 0.05, "base curvature tends smoothly to flat top")
        check(abs(secondDerivative(last, atEnd: true))*rightSpan*rightSpan/rise < 0.05, "opposite base curvature tends to flat top")
        for i in 0..<(bridge.count - 1) {
            let a = bridge[i]
            let b = bridge[i+1]
            let ax = a[3].x-a[2].x, ay = a[3].y-a[2].y
            let bx = b[1].x-b[0].x, by = b[1].y-b[0].y
            check(abs(ax*by-ay*bx) < 1e-8 && ax*bx+ay*by > 0, "continuous analytic slope at every bell joint")
            let curvatureJump = abs(secondDerivative(a, atEnd: true) - secondDerivative(b, atEnd: false))
            check(curvatureJump * tipRadius < 0.04, "Hermite curvature approximation has no stiff arc/side joins")
        }
        check(shape.path.contains(CGPoint(x: shape.body.midX, y: shape.body.midY)), "single outline fills panel interior")
        check(shape.bodyPath.boundingBoxOfPath == shape.body, "content clip stays body only")
    }

    static func main() {
        // Parent-provided interpolation: forward and reverse must be identical.
        for step in 0...100 {
            let t = CGFloat(step) / 100
            let body = CGRect(x: 100, y: 500 - (8 + 552*t), width: 32 + 728*t, height: 8 + 552*t)
            for offset: CGFloat in [-0.18, 0, 0.18] {
                let anchor = CGPoint(x: body.midX + body.width*offset, y: body.maxY + 30 + 14*t)
                let shape = GooShape(body: body, anchor: anchor)
                check(shape.body == body, "no internal body interpolation")
                inspect(shape, anchor: anchor)
            }
        }
        for size in [CGSize(width: 154, height: 88), CGSize(width: 320, height: 300), CGSize(width: 760, height: 560)] {
            let body = CGRect(origin: .zero, size: size)
            inspect(GooShape(body: body, anchor: CGPoint(x: size.width*0.4, y: size.height+36)), anchor: CGPoint(x: size.width*0.4, y: size.height+36))
        }
        check(GooShape.smooth(-1, 0, 1) == 0 && GooShape.smooth(2, 0, 1) == 1, "smooth clamps")
        check(GooShape.smooth(0.5, 0, 1) == 0.5, "smooth midpoint")
        check(GooShape.smooth(1, 1, 1) == 1, "smooth degenerate interval")
        var spring = GooSpring()
        spring.retarget(1)
        var peak = 0.0
        for _ in 0..<240 { spring.advance(1.0/240); peak = max(peak, spring.value) }
        check(peak > 1 && peak < 1.04, "slight bounded opening bounce")
        check(spring.isSettled, "opening settles")
        spring = GooSpring(); spring.retarget(1); spring.advance(0.075)
        let value = spring.value, velocity = spring.velocity
        spring.retarget(0)
        check(spring.value == value && spring.velocity == velocity, "reversal preserves instantaneous state")
        var one = spring
        one.advance(0.6)
        var varied = spring
        for dt in [0.003, 0.014, 0.08, 0.002, 0.19, 0.011, 0.3] { varied.advance(dt) }
        check(abs(one.value-varied.value) < 1e-12 && abs(one.velocity-varied.velocity) < 1e-12, "analytic samples independent of frame partition")
        for hz in [30.0, 60, 120, 144] {
            var sampled = spring
            for _ in 0..<Int(hz) { sampled.advance(1/hz) }
            var direct = spring; direct.advance(1)
            check(abs(sampled.value-direct.value) < 1e-12 && abs(sampled.velocity-direct.velocity) < 1e-12, "stable variable refresh rates")
        }
        let saved = spring
        for dt in [0.0, -1, Double.infinity, Double.nan] { spring.advance(dt) }
        check(spring.value == saved.value && spring.velocity == saved.velocity, "invalid delta ignored")
        spring.settle()
        check(spring.value == spring.target && spring.velocity == 0 && spring.isSettled, "explicit settle")
        print("PASS: \(checks) checks — continuous single-fill outline, rounded ceiling, monotonic tangency, small/large morphs, analytic spring reversal and frame rates")
    }
}
