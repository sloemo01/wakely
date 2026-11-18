import SwiftUI
import AppKit

/// Original sprites are authored at 28×28, displayed at exactly 2× logical pixels.
/// State changes swap frames; no rotation, crossfade, or fractional sprite scaling.
struct ComponentSprite: View {
    let componentID: String
    let isOn: Bool
    var isHovered = false
    var size: CGFloat = 56
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.wakelyPaneIsActive) private var paneIsActive
    @Environment(\.colorScheme) private var colorScheme
    @State private var reveal: CGFloat

    init(componentID: String, isOn: Bool, isHovered: Bool = false, size: CGFloat = 56) {
        self.componentID = componentID
        self.isOn = isOn
        self.isHovered = isHovered
        self.size = size
        _reveal = State(initialValue: isOn ? 1 : 0)
    }

    private static let animatedComponents: Set<String> = [
        "agentScreen", "agentStatus", "agentLight",
        "homeServer", "keepAwake", "finishJobsThenSleep", "sleepTimer",
        "sleepMeansSleep", "sleepWhenIdle",
        "fanBoost", "awakeWhileConnected", "armWhileAppRuns", "armOnWiFi",
        "armWhenDriveConnects"
    ]

    var body: some View {
        let animatesIdle = isOn && paneIsActive && !reduceMotion && Self.animatedComponents.contains(componentID)
        // Keep the same view hierarchy on both sides of a toggle. Swapping a
        // static view for a TimelineView let the enclosing card crossfade the
        // entire sprite in addition to revealing its pixels.
        TimelineView(.animation(minimumInterval: 0.20, paused: !animatesIdle)) { timeline in
            let offset = componentID.utf8.reduce(0) { ($0 + Int($1)) % 8 }
            let frame = animatesIdle
                ? (Int(timeline.date.timeIntervalSinceReferenceDate * 5) + offset) % 8 : 0
            sprite(frame: frame)
        }
        .frame(width: size, height: size)
        .transaction { $0.animation = nil }
        .onChange(of: isOn) { _, on in
            guard !reduceMotion else { reveal = on ? 1 : 0; return }
            // A fully lit sprite is already revealed: do not reset it to zero
            // first, or toggling on flashes transparent before lighting up.
            if on, reveal >= 1 { return }
            reveal = on ? 1 : 0
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { reveal = isOn ? 1 : 0 }
        }
        .accessibilityHidden(true)
    }

    private func sprite(frame: Int) -> some View {
        // Authored hover material is used instead of whole-sprite brightness.
        // Hover never alters the mask/reveal hierarchy.
        let hoverFrame = frame % 2
        let onState = reduceMotion ? "on"
            : (isHovered ? "hover-on-\(hoverFrame)" : (isOn ? "idle-on-\(frame)" : "on"))
        let offState = isHovered ? "hover-off-\(hoverFrame)" : "off"
        return ZStack {
            styled(offState, on: false)
            styled(onState, on: true)
                .mask(
                    PixelRevealMask(progress: reveal)
                        // Only the mask animates, not the image/idle timeline.
                        .animation(reduceMotion ? nil : .linear(duration: AppMotion.pixelRevealDuration), value: reveal)
                )
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(width: size, height: size)
    }

    private func styled(_ state: String, on: Bool) -> some View {
        Image(nsImage: ComponentSpriteImages.image(componentID: componentID,
                                                   state: state,
                                                   appearance: colorScheme))
            .renderingMode(.original)
            .resizable()
            .interpolation(.none)
    }
}

@MainActor
private enum ComponentSpriteImages {
    private static var cache: [String: NSImage] = [:]

    static func image(componentID: String, state: String, appearance: ColorScheme) -> NSImage {
        let light = appearance == .light
        let key = "\(componentID)-\(state)-\(light ? "light" : "dark")"
        if let image = cache[key] { return image }
        let resource = key.replacingOccurrences(of: "-\(light ? "light" : "dark")", with: "")
            + (light ? "-light" : "")
        guard let url = AppResources.url(name: resource, extension: "png", subdirectory: "Sprites"),
              let image = NSImage(contentsOf: url) else {
            Diagnostics.log("missing component sprite: \(key)")
            return ComponentIcon.image(named: componentID)
        }
        image.size = NSSize(width: 28, height: 28)
        cache[key] = image
        return image
    }
}

/// User-authored SDK icons retain their original 32×32 grid. Render directly
/// to the canvas at 2×, instead of rasterizing at 52 and stretching to 56.
struct CustomComponentSprite: View {
    let lines: [String]
    let isOn: Bool
    var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    private var grid: [[Character]] {
        lines.map { $0.split(separator: "|").last.map(String.init) ?? $0 }
            .filter { $0.count >= 32 }
            .prefix(32)
            .map { Array($0.prefix(32)) }
    }

    var body: some View {
        Canvas { context, _ in
            let colors = GoldenSpritePalette.colors(on: isOn, appearance: colorScheme)
            for (y, row) in grid.enumerated() {
                for (x, character) in row.enumerated() {
                    guard let color = colors[character] else { continue }
                    context.fill(Path(CGRect(x: x * 2, y: y * 2, width: 2, height: 2)),
                                 with: .color(color), style: FillStyle(antialiased: false))
                }
            }
        }
        .frame(width: 64, height: 64)
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}


/// A deterministic pixel dissolve. `progress` 0 is fully hidden, 1 is fully
/// revealed; each cell snaps on in a fixed shuffled order so it reads as
/// pixels appearing, not a smooth fade.
private struct PixelRevealMask: View, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }
    private static let columns = 28
    private static let order: [Int] = {
        let count = columns * columns
        var cells = Array(0..<count)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for index in stride(from: count - 1, through: 1, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let swap = Int(seed % UInt64(index + 1))
            cells.swapAt(index, swap)
        }
        return cells
    }()

    var body: some View {
        Canvas { context, size in
            let columns = Self.columns
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(columns)
            let amount = min(max(progress, 0), 1)
            let revealed = Int((amount * CGFloat(Self.order.count)).rounded(.up))
            for index in 0..<min(revealed, Self.order.count) {
                let cell = Self.order[index]
                let rect = CGRect(x: CGFloat(cell % columns) * cellWidth,
                                  y: CGFloat(cell / columns) * cellHeight,
                                  width: cellWidth, height: cellHeight)
                context.fill(Path(rect), with: .color(.white), style: FillStyle(antialiased: false))
            }
        }
    }
}
