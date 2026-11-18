import Foundation
import CoreGraphics

@main struct GooPanelMotionTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }
    static func settle(_ motion: inout GooPanelMotion) {
        for _ in 0..<240 { motion.advance(1 / 120) }
        check(motion.isSettled, "transition must settle")
    }
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 1120)
        let layout = GooPanelLayout(anchor: CGPoint(x: 1250, y: 1120), visibleScreen: screen, compactHeight: 300)
        check(layout.compact.size == CGSize(width: 320, height: 300), "compact is a real small panel")
        check(layout.settings.size == CGSize(width: 760, height: 560), "settings size")
        check(layout.compact.midX == layout.anchor.x && layout.settings.midX == layout.anchor.x, "directly under icon")
        check(layout.compact.maxY == layout.settings.maxY, "top edge remains fixed on morph")
        var motion = GooPanelMotion()
        motion.toggle()
        check(motion.route == .compact, "icon opens compact first")
        settle(&motion)
        check(layout.body(for: motion) == layout.compact, "settled compact body")
        motion.request(.settings)
        for _ in 0..<12 { motion.advance(1 / 120) }
        let value = motion.expansion.value
        let velocity = motion.expansion.velocity
        motion.back()
        check(motion.route == .compact, "cross must return to compact, not hide")
        check(motion.expansion.value == value && motion.expansion.velocity == velocity, "back preserves momentum")
        motion.advance(1 / 120)
        motion.request(.settings)
        settle(&motion)
        check(layout.body(for: motion) == layout.settings, "settled settings body")
        motion.back()
        settle(&motion)
        check(layout.body(for: motion) == layout.compact, "complete reverse")
        motion.back()
        settle(&motion)
        check(motion.route == .hidden && motion.visibility.value == 0, "compact cross hides")
        let hidden = layout.body(for: motion)
        check(hidden.width == 0 && hidden.height == 0, "hidden shell has no lingering nub")
        check(hidden.origin == layout.anchor, "hidden shell converges to the status anchor")
        for v in [0.000001, 0.00001, 0.0001, 0.001, 0.01] {
            var nearHidden = motion
            nearHidden.visibility.value = v
            let rect = layout.body(for: nearHidden)
            check(abs(rect.width - layout.compact.width * v) < 1e-9,
                  "closing tail converges continuously in width")
            check(abs(rect.height - layout.compact.height * v) < 1e-9,
                  "closing tail converges continuously in height")
        }
        motion.toggle()
        settle(&motion)
        check(motion.route == .compact, "reopen is compact")
        for fps in [30.0, 60, 120, 144] {
            for x: CGFloat in [20, 200, 900, 1700, 1780] {
                let l = GooPanelLayout(anchor: CGPoint(x: x, y: 1120), visibleScreen: screen, compactHeight: 620)
                var m = GooPanelMotion()
                for target in [GooPanelRoute.compact, .settings, .compact, .settings, .hidden, .compact] {
                    m.request(target)
                    for _ in 0..<Int(fps) {
                        m.advance(1 / fps)
                        let body = l.body(for: m)
                        check(body.width.isFinite && body.height.isFinite && body.height >= 0,
                              "finite intermediate or zero-area hidden rect")
                        check(l.surface.contains(body), "surface contains spring overshoot")
                        check(body.maxY <= l.anchor.y, "never enters menu bar")
                        let shape = GooShape(body: body, anchor: l.anchor, flare: min(190, body.width * 0.42))
                        check(shape.path.boundingBoxOfPath.maxY <= l.anchor.y + 0.01, "path remains below icon")
                    }
                }
            }
        }
        print("PASS: \(checks) panel routing, reverse, interruption, layout, and bounds checks")
    }
}
