import Foundation

@main struct ScrollEdgeStateTests {
    static func main() {
        let empty = ScrollEdgeState()
        precondition(empty.top == 0 && empty.bottom == 0)
        let short = ScrollEdgeState(offset: 0, contentHeight: 120, viewportHeight: 500)
        precondition(short == empty)
        let top = ScrollEdgeState(offset: 0, contentHeight: 900, viewportHeight: 500)
        precondition(top.top == 0 && top.bottom == 1)
        let middle = ScrollEdgeState(offset: 200, contentHeight: 900, viewportHeight: 500)
        precondition(middle.top == 1 && middle.bottom == 1)
        let bottom = ScrollEdgeState(offset: 400, contentHeight: 900, viewportHeight: 500)
        precondition(bottom.top == 1 && bottom.bottom == 0)
        let fractional = ScrollEdgeState(offset: 12, contentHeight: 900, viewportHeight: 500)
        precondition(fractional.top == 0.5 && fractional.bottom == 1)
        let overscroll = ScrollEdgeState(offset: 600, contentHeight: 900, viewportHeight: 500)
        precondition(overscroll == bottom)
        let negative = ScrollEdgeState(offset: -30, contentHeight: 900, viewportHeight: 500)
        precondition(negative == top)
        let invalid = ScrollEdgeState(offset: .nan, contentHeight: 900, viewportHeight: 500)
        precondition(invalid == empty)
        print("PASS: 9 scroll edge boundary, short-content and overscroll checks")
    }
}
