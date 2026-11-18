import SwiftUI
import CoreGraphics

/// A presentation route for the component detail page. The model owns only
/// route intent and sampled geometry; it never reads settings, permissions or
/// menu state and never starts permission work itself.
@MainActor
final class CardMorphPresentationModel: ObservableObject {
    enum Phase: Equatable {
        case catalog
        case opening
        case detail
        case closing
    }

    struct Session: Equatable {
        let id: UUID
        let componentID: String
        var source: CGRect
        var destination: CGRect
        let returnQuery: String
        let returnOnOnly: Bool
        let returnScrollOffset: CGFloat
    }

    struct SettledEvent: Equatable {
        let serial: Int
        let endpoint: CardMorphEndpoint
        let componentID: String
        let sessionID: UUID
        let returnQuery: String
        let returnOnOnly: Bool
        let returnScrollOffset: CGFloat
    }

    @Published private(set) var phase: Phase = .catalog
    @Published private(set) var progress: Double = 0
    @Published private(set) var session: Session?
    @Published private(set) var settledEvent: SettledEvent?
    /// A closed endpoint keeps its final overlay frame until the host clears
    /// the real detail page in the same transaction. This prevents a one-frame
    /// blank between overlay removal and card restoration.
    @Published private(set) var awaitingCloseCommit = false

    private var motion = CardMorphPresentation()
    private var eventSerial = 0

    var isActive: Bool { phase == .opening || phase == .closing }
    var isAnimating: Bool { isActive && motion.isAnimating }
    var componentID: String? { session?.componentID }
    var destination: CGRect? { session?.destination }

    /// Starts a measured detail route. Re-requesting the same component while
    /// closing reuses the live surface and its velocity.
    @discardableResult
    func beginOpen(componentID: String, source: CGRect, destination: CGRect,
                   query: String, onOnly: Bool, scrollOffset: CGFloat) -> Bool {
        guard source.width > 8, source.height > 1,
              destination.width > 8, destination.height > 1 else { return false }
        if let session, session.componentID != componentID {
            // The visible card list is inert while a detail is active. Refuse
            // an impossible second hero rather than retarget it to another card.
            return false
        }
        if phase == .opening { return true }
        if phase == .closing, var current = session {
            current.source = source
            self.session = current
            phase = .opening
            motion.open()
            return true
        }
        if phase == .detail, session?.componentID == componentID { return true }
        session = Session(id: UUID(), componentID: componentID,
                          source: source, destination: destination,
                          returnQuery: query, returnOnOnly: onOnly,
                          returnScrollOffset: scrollOffset)
        progress = 0
        motion = CardMorphPresentation()
        motion.open()
        phase = .opening
        return true
    }

    /// Reverses from the current sample. A Back during opening therefore never
    /// waits for the opening animation to finish.
    @discardableResult
    func beginClose(measuredSource: CGRect? = nil) -> Bool {
        guard session != nil else { return false }
        switch phase {
        case .opening:
            phase = .closing
            motion.close()
            return true
        case .detail:
            if let measuredSource, measuredSource.width > 8, measuredSource.height > 1 {
                self.session?.source = measuredSource
            }
            phase = .closing
            motion.close()
            return true
        case .closing:
            return true
        case .catalog:
            return false
        }
    }

    /// Presents a detail opened directly by a URL or test fixture. It has no
    /// floating hero; close uses a real measured card if one is supplied.
    /// Updates the live destination after a host layout change. The caller
    /// decides whether to settle or continue; no geometry is fabricated.
    func rebaseDestination(_ destination: CGRect) {
        guard destination.width > 8, destination.height > 1 else { return }
        session?.destination = destination
    }

    func showSettled(componentID: String, destination: CGRect,
                     query: String, onOnly: Bool, scrollOffset: CGFloat) {
        session = Session(id: UUID(), componentID: componentID,
                          source: .zero, destination: destination,
                          returnQuery: query, returnOnOnly: onOnly,
                          returnScrollOffset: scrollOffset)
        motion = CardMorphPresentation()
        motion.open()
        motion.settle()
        progress = 1
        phase = .detail
    }

    /// Advances from a display-link timestamp delta.
    func advance(dt: Double) {
        guard isActive else { return }
        if let endpoint = motion.advance(dt) {
            progress = motion.progress
            finish(endpoint)
        } else {
            progress = motion.progress
        }
    }

    /// Accessibility/long-frame settling uses the current requested target,
    /// never an older route.
    func settle() {
        guard isActive else { return }
        let endpoint: CardMorphEndpoint = motion.target >= 0.5 ? .opened : .closed
        motion.settle()
        progress = motion.progress
        finish(endpoint)
    }

    private func finish(_ endpoint: CardMorphEndpoint) {
        guard let session else { return }
        if endpoint == .opened {
            phase = .detail
        } else {
            // Keep the 0-progress overlay and the real page mounted until the
            // host consumes the event. The host then swaps both atomically.
            awaitingCloseCommit = true
        }
        eventSerial &+= 1
        settledEvent = SettledEvent(serial: eventSerial, endpoint: endpoint,
                                    componentID: session.componentID,
                                    sessionID: session.id,
                                    returnQuery: session.returnQuery,
                                    returnOnOnly: session.returnOnOnly,
                                    returnScrollOffset: session.returnScrollOffset)
    }

    func commitClosed() {
        guard awaitingCloseCommit else { return }
        awaitingCloseCommit = false
        phase = .catalog
        session = nil
    }
}
