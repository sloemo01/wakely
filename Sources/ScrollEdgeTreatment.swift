import SwiftUI
import AppKit

/// An ordinary native ScrollView with stable, background-revealing pixel edges.
/// No paint colour is baked into the edge: fading the content exposes the exact
/// glass/opaque surface below, including Light/Dark/System and desktop changes.
struct EdgeScrollView<Content: View>: View {
    var topFade: CGFloat = 28
    var bottomFade: CGFloat = 64
    var onOffset: ((CGFloat) -> Void)?
    @ViewBuilder var content: Content
    @State private var edges = ScrollEdgeState()

    var body: some View {
        ScrollView(.vertical) {
            content.background {
                ScrollMetricsReader { offset, document, viewport in
                    let next = ScrollEdgeState(offset: offset, contentHeight: document,
                                               viewportHeight: viewport)
                    if next != edges { edges = next }
                    onOffset?(offset)
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .mask {
            ZStack {
                Color.white
                VStack(spacing: 0) {
                    PixelFade(edge: .top, color: .black)
                        .frame(height: topFade)
                        .opacity(edges.top)
                    Spacer(minLength: 0)
                    PixelFade(edge: .bottom, color: .black)
                        .frame(height: bottomFade)
                        .opacity(edges.bottom)
                }
                .blendMode(.destinationOut)
            }
            .compositingGroup()
            .transaction { $0.animation = nil }
        }
    }
}

/// Binary-alpha mask tile. Cached by height only rather than every intermediate
/// animated panel width, and colour is applied by SwiftUI rather than baked RGB.
struct PixelFade: View {
    enum Edge: Hashable { case top, bottom }
    var edge: Edge = .bottom
    var color: Color = Theme.window
    @Environment(\.displayScale) private var displayScale

    private struct Key: Hashable { let edge: Edge; let height: Int }
    private static let lock = NSLock()
    private static var cache: [Key: CGImage] = [:]

    var body: some View {
        GeometryReader { geometry in
            let scale = max(1, displayScale)
            let height = max(1, Int((geometry.size.height * scale).rounded()))
            color.mask {
                Image(decorative: Self.texture(edge: edge, height: height), scale: scale)
                    .resizable(capInsets: EdgeInsets(), resizingMode: .tile)
                    .interpolation(.none)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func texture(edge: Edge, height: Int) -> CGImage {
        let key = Key(edge: edge, height: height)
        lock.lock(); defer { lock.unlock() }
        if let image = cache[key] { return image }
        let width = 64
        let bayer = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let t = edge == .top ? Double(y) / Double(max(1, height - 1))
                : Double(height - 1 - y) / Double(max(1, height - 1))
            let coverage = 1 - min(1, max(0, t / 0.94))
            for x in 0..<width {
                let cx = x / 4, cy = y / 4
                let threshold = (Double(bayer[(cy & 3) * 4 + (cx & 3)]) + 0.5) / 16
                let index = (y * width + x) * 4
                let alpha: UInt8 = coverage > threshold ? 255 : 0
                bytes[index] = alpha; bytes[index + 1] = alpha
                bytes[index + 2] = alpha; bytes[index + 3] = alpha
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        if cache.count >= 24 { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }
}

private struct ScrollMetricsReader: NSViewRepresentable {
    let onChange: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: Probe, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: NSView {
        var onChange: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private weak var scroll: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false

        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleAttach() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleAttach() }
        private func scheduleAttach() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                self.attach()
            }
        }
        private func attach() {
            guard let next = enclosingScrollView else { return }
            guard scroll !== next else { sample(); return }
            detach()
            scroll = next
            next.hasVerticalScroller = false
            next.hasHorizontalScroller = false
            next.verticalScroller?.isHidden = true
            next.horizontalScroller?.isHidden = true
            next.contentView.postsBoundsChangedNotifications = true
            next.contentView.postsFrameChangedNotifications = true
            next.documentView?.postsFrameChangedNotifications = true
            for (name, object) in [
                (NSView.boundsDidChangeNotification, next.contentView),
                (NSView.frameDidChangeNotification, next.contentView),
                (NSView.frameDidChangeNotification, next.documentView)
            ] {
                guard let object else { continue }
                observers.append(NotificationCenter.default.addObserver(forName: name, object: object,
                    queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } })
            }
            sample()
        }
        private func sample() {
            guard let scroll, let document = scroll.documentView else { return }
            onChange?(max(0, scroll.contentView.bounds.minY - document.bounds.minY),
                      document.bounds.height, scroll.contentView.bounds.height)
        }
        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            scroll = nil
        }
    }
}
