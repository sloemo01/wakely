import Foundation

/// Scroll-linked edge presence, not an animation. Short content has no shadow;
/// an edge appears only while content is hidden beyond that edge.
struct ScrollEdgeState: Equatable {
    let top: Double
    let bottom: Double

    init(offset: CGFloat = 0, contentHeight: CGFloat = 0, viewportHeight: CGFloat = 0) {
        guard offset.isFinite, contentHeight.isFinite, viewportHeight.isFinite else {
            top = 0; bottom = 0; return
        }
        let overflow = max(0, contentHeight - viewportHeight)
        guard overflow > 0.5 else { top = 0; bottom = 0; return }
        let y = min(overflow, max(0, offset))
        top = min(1, Double(y / 24))
        bottom = min(1, Double((overflow - y) / 24))
    }
}
