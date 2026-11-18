import SwiftUI
import CoreGraphics

@main
struct CardMorphPresentationModelTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }

    @MainActor
    static func main() {
        let source = CGRect(x: 20, y: 300, width: 320, height: 160)
        let destination = CGRect(x: 28, y: 74, width: 984, height: 112)
        let model = CardMorphPresentationModel()
        check(model.beginOpen(componentID: "agentScreen", source: source,
                              destination: destination, query: "screen",
                              onOnly: true, scrollOffset: 64),
              "measured open starts")
        check(model.phase == .opening && model.progress == 0, "opening starts at the card")
        for _ in 0..<30 { model.advance(dt: 1.0 / 120.0) }
        let p = model.progress
        check(p > 0 && p < 1, "open is mid-flight")
        let sessionID = model.session?.id
        check(model.beginClose(), "Back retargets while opening")
        check(model.phase == .closing && model.progress == p, "close preserves progress")
        check(model.session?.id == sessionID, "reversal keeps the same hero session")
        check(!model.beginOpen(componentID: "agentStatus", source: source,
                               destination: destination, query: "", onOnly: false,
                               scrollOffset: 0),
              "a second hero is refused while one is live")

        var reopened = false
        for _ in 0..<600 {
            model.advance(dt: 1.0 / 120.0)
            if model.progress == 0 {
                reopened = true
                break
            }
        }
        check(reopened, "closing reaches the card endpoint")
        check(model.settledEvent?.endpoint == .closed, "closed endpoint is reported")
        check(model.awaitingCloseCommit, "overlay is retained until host handoff")
        let event = model.settledEvent
        check(event?.returnQuery == "screen" && event?.returnOnOnly == true,
              "return context survives the route")
        model.commitClosed()
        check(model.phase == .catalog && model.session == nil, "close commit clears the route")

        check(model.beginOpen(componentID: "agentScreen", source: source,
                              destination: destination, query: "", onOnly: false,
                              scrollOffset: 0), "open after catalog starts")
        for _ in 0..<600 {
            model.advance(dt: 1.0 / 120.0)
            if model.phase == .detail { break }
        }
        check(model.phase == .detail, "open settles at detail")
        check(model.settledEvent?.endpoint == .opened, "open endpoint is reported once")

        check(model.beginClose(measuredSource: source), "Back from detail starts close")
        for _ in 0..<600 {
            model.advance(dt: 1.0 / 120.0)
            if model.awaitingCloseCommit { break }
        }
        check(model.progress == 0 && model.awaitingCloseCommit, "detail reverses to its card")
        model.commitClosed()
        check(model.phase == .catalog && model.session == nil, "detail close commits cleanly")

        let deepLink = CardMorphPresentationModel()
        deepLink.showSettled(componentID: "fanBoost", destination: destination,
                             query: "", onOnly: false, scrollOffset: 0)
        check(deepLink.phase == .detail && deepLink.progress == 1,
              "deep link presents a settled detail")
        check(deepLink.beginClose(measuredSource: source), "deep link can return to a measured card")
        for _ in 0..<600 {
            deepLink.advance(dt: 1.0 / 120.0)
            if deepLink.awaitingCloseCommit { break }
        }
        check(deepLink.awaitingCloseCommit, "deep-link close reaches the card")

        let invalid = CardMorphPresentationModel()
        check(!invalid.beginOpen(componentID: "x", source: .zero, destination: destination,
                                 query: "", onOnly: false, scrollOffset: 0),
              "missing sources never animate toward a fabricated rect")
        print("PASS: \(checks) card route model checks")
    }
}
