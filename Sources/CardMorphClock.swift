import AppKit
import QuartzCore
import SwiftUI

/// One display-link host for a card morph. The view exists only while the
/// presentation is active, so no hidden timer or second animation owner runs
/// after the route settles.
struct CardMorphClock: NSViewRepresentable {
    let isRunning: Bool
    let onTick: (Double) -> Void

    func makeNSView(context: Context) -> ClockHostView {
        let view = ClockHostView()
        view.onTick = onTick
        view.isRunning = isRunning
        return view
    }

    func updateNSView(_ nsView: ClockHostView, context: Context) {
        nsView.onTick = onTick
        nsView.isRunning = isRunning
    }

    static func dismantleNSView(_ nsView: ClockHostView, coordinator: ()) {
        nsView.isRunning = false
        nsView.onTick = nil
    }

    final class ClockHostView: NSView {
        var onTick: ((Double) -> Void)?
        var isRunning = false {
            didSet {
                guard oldValue != isRunning else { return }
                isRunning ? start() : stop()
            }
        }

        private var link: CADisplayLink?
        private var lastTimestamp: CFTimeInterval?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
            else if isRunning { start() }
        }

        private func start() {
            guard link == nil, let window else { return }
            lastTimestamp = nil
            let next = window.displayLink(target: self, selector: #selector(step(_:)))
            link = next
            next.add(to: .main, forMode: .common)
        }

        private func stop() {
            link?.invalidate()
            link = nil
            lastTimestamp = nil
        }

        @objc private func step(_ link: CADisplayLink) {
            let previous = lastTimestamp
            lastTimestamp = link.timestamp
            guard let previous else { return }
            let dt = link.timestamp - previous
            guard dt.isFinite, dt > 0 else { return }
            onTick?(dt)
        }
    }
}
