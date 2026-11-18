import Foundation
import CoreGraphics

@main
struct CardMorphPresentationTests {
    static var checks = 0

    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }

    static func main() {
        var motion = CardMorphPresentation()
        motion.open()
        for _ in 0..<20 { _ = motion.advance(1.0 / 120.0) }
        let value = motion.progress
        let velocity = motion.velocity
        check(value > 0 && value < 1, "opening must be mid-flight")
        check(!motion.isSettled, "opening sample must still be moving")
        motion.close()
        check(motion.progress == value, "reversal preserves position exactly")
        check(motion.velocity == velocity, "reversal preserves velocity exactly")

        var reverse = motion
        var sawEndpoint = false
        for _ in 0..<600 {
            if reverse.advance(1.0 / 120.0) == .closed { sawEndpoint = true; break }
        }
        check(sawEndpoint, "reverse must report the card endpoint")
        check(reverse.progress == 0 && reverse.velocity == 0, "reverse settles exactly at zero")
        check(reverse.advance(1.0 / 120.0) == nil, "completion is reported at most once")

        var reopened = CardMorphPresentation()
        reopened.open()
        for _ in 0..<60 { _ = reopened.advance(1.0 / 120.0) }
        check(reopened.progress > 0.5, "opening has advanced")
        reopened.close()
        for _ in 0..<12 { _ = reopened.advance(1.0 / 120.0) }
        reopened.open()
        var openEndpoint: CardMorphEndpoint?
        for _ in 0..<600 {
            openEndpoint = reopened.advance(1.0 / 120.0)
            if openEndpoint != nil { break }
        }
        check(openEndpoint == .opened, "closing can re-open from the current sample")
        check(reopened.progress == 1, "re-open settles at the header")

        var malformed = CardMorphPresentation()
        malformed.open()
        let before = malformed.progress
        for delta in [0.0, -1.0, Double.infinity, -Double.infinity, Double.nan] {
            check(malformed.advance(delta) == nil, "invalid dt is ignored")
        }
        check(malformed.progress == before, "invalid dt cannot move progress")

        let source = CGRect(x: 20, y: 200, width: 320, height: 160)
        let destination = CGRect(x: 28, y: 74, width: 984, height: 112)
        let openingGeometry = CardMorphGeometry(source: source, destination: destination,
                                                direction: .opening)
        let closingGeometry = CardMorphGeometry(source: source, destination: destination,
                                                direction: .closing)
        for sample in [0.0, 0.01, 0.25, 0.5, 0.9, 1.0] {
            check(openingGeometry.surfaceFrame(presentation: sample)
                    == closingGeometry.surfaceFrame(presentation: sample),
                  "semantic geometry cannot change curve family on reversal")
            check(openingGeometry.cornerRadius(presentation: sample)
                    == closingGeometry.cornerRadius(presentation: sample),
                  "semantic radius cannot change on reversal")
        }

        motion.settle()
        check(motion.progress == 0 && motion.velocity == 0, "explicit settle reaches target")
        print("PASS: \(checks) reversible card presentation checks")
    }
}
