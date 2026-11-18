import SwiftUI

/// Small, interior-only pixel animations for the component sprites.
///
/// Every recipe draws on the 28x28 grid the sprite art uses; the caller scales
/// it to the card size. The outer silhouette is never touched. Animations run
/// only for enabled components and are disabled by Reduce Motion.
struct SpriteMotion: View {
    let componentID: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.periodic(from: .now, by: 1.0 / 8.0)) { timeline in
                Canvas { context, size in
                    let frame = Int(timeline.date.timeIntervalSinceReferenceDate * 8)
                    SpriteMotion.draw(componentID: componentID, frame: frame,
                                      size: size, context: context)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Recipes

    private enum Kind {
        case scanline, bars, blink, bell, glow, clock, led, keys, sound, muted
        case keyhole, zipper, spark, battery, steam, twinkle, breath, arrow
        case sand, fan, eject, signal, date, cursor, ripple
    }

    private static let recipes: [String: (Kind, CGRect)] = [
        "agentScreen": (.scanline, CGRect(x: 8, y: 7, width: 12, height: 9)),
        "agentStatus": (.bars, CGRect(x: 10, y: 8, width: 8, height: 7)),
        "finishWorkThenSleep": (.blink, CGRect(x: 10, y: 8, width: 8, height: 3)),
        "agentNotifications": (.bell, CGRect(x: 9, y: 6, width: 10, height: 10)),
        "agentLight": (.glow, CGRect(x: 9, y: 7, width: 10, height: 6)),
        "sleepUntilReset": (.clock, CGRect(x: 9, y: 8, width: 10, height: 10)),
        "capsLock": (.led, CGRect(x: 12, y: 7, width: 4, height: 2)),
        "cleaningLock": (.keys, CGRect(x: 7, y: 12, width: 14, height: 6)),
        "lidCloseSound": (.sound, CGRect(x: 9, y: 8, width: 10, height: 10)),
        "quietClose": (.muted, CGRect(x: 9, y: 8, width: 10, height: 10)),
        "passwordAfterClose": (.keyhole, CGRect(x: 11, y: 11, width: 6, height: 6)),
        "bagCheck": (.zipper, CGRect(x: 9, y: 10, width: 10, height: 8)),
        "alwaysOnPluggedIn": (.spark, CGRect(x: 14, y: 8, width: 4, height: 6)),
        "homeServer": (.led, CGRect(x: 15, y: 8, width: 4, height: 12)),
        "lowPowerWhileClosed": (.battery, CGRect(x: 8, y: 12, width: 12, height: 4)),
        "batteryBudget": (.battery, CGRect(x: 9, y: 12, width: 10, height: 4)),
        "keepAwake": (.steam, CGRect(x: 11, y: 2, width: 7, height: 7)),
        "sleepMeansSleep": (.twinkle, CGRect(x: 12, y: 4, width: 10, height: 8)),
        "stayOffWhenOpened": (.breath, CGRect(x: 10, y: 8, width: 8, height: 6)),
        "finishJobsThenSleep": (.arrow, CGRect(x: 11, y: 10, width: 6, height: 8)),
        "sleepWhenIdle": (.clock, CGRect(x: 9, y: 8, width: 10, height: 10)),
        "sleepTimer": (.sand, CGRect(x: 11, y: 7, width: 6, height: 14)),
        "fanBoost": (.fan, CGRect(x: 9, y: 9, width: 10, height: 10)),
        "ejectOnSleep": (.eject, CGRect(x: 8, y: 10, width: 12, height: 5)),
        "bluetoothOffWhileClosed": (.breath, CGRect(x: 11, y: 6, width: 6, height: 12)),
        "awakeWhileConnected": (.cursor, CGRect(x: 9, y: 8, width: 10, height: 8)),
        "lidShortcuts": (.ripple, CGRect(x: 8, y: 10, width: 12, height: 7)),
        "armWhileAppRuns": (.breath, CGRect(x: 10, y: 8, width: 8, height: 7)),
        "armOnWiFi": (.signal, CGRect(x: 13, y: 5, width: 6, height: 10)),
        "armOnSchedule": (.date, CGRect(x: 9, y: 7, width: 10, height: 10)),
        "armWhenDriveConnects": (.spark, CGRect(x: 14, y: 10, width: 4, height: 6))
    ]

    private static let gold = Color(red: 0.98, green: 0.80, blue: 0.20)
    private static let amber = Color(red: 0.96, green: 0.62, blue: 0.08)
    private static let cream = Color(red: 1.0, green: 0.95, blue: 0.75)

    private static func draw(componentID: String, frame: Int, size: CGSize,
                             context: GraphicsContext) {
        guard let (kind, rect) = recipes[componentID] else { return }
        let unit = size.width / 28

        func pixel(_ x: CGFloat, _ y: CGFloat, _ color: Color,
                   width: CGFloat = 1, height: CGFloat = 1) {
            let r = CGRect(x: x * unit, y: y * unit,
                           width: width * unit, height: height * unit)
            context.fill(Path(r), with: .color(color))
        }

        switch kind {
        case .scanline:
            let y = rect.minY + CGFloat(frame % Int(rect.height))
            pixel(rect.minX, y, gold.opacity(0.32), width: rect.width)
            if frame % 8 < 4 {
                pixel(rect.maxX - 2, rect.minY + 2, cream, width: 1.5, height: 1.5)
            }
        case .bars:
            for index in 0..<3 {
                let height = CGFloat(1 + (frame / 2 + index * 2) % Int(rect.height))
                pixel(rect.minX + CGFloat(index) * 3, rect.maxY - height,
                      index == frame / 4 % 3 ? cream : gold, width: 2, height: height)
            }
        case .blink:
            if frame % 16 < 2 { return }
            pixel(rect.minX + 1, rect.midY, cream, width: 2, height: 1)
            pixel(rect.maxX - 3, rect.midY, cream, width: 2, height: 1)
        case .bell:
            let swing = CGFloat((frame / 2) % 3) - 1
            pixel(rect.midX + swing, rect.maxY - 2, amber, width: 1, height: 2)
            let radius = CGFloat(1 + frame % 3)
            pixel(rect.midX - radius, rect.midY, gold.opacity(0.5))
            pixel(rect.midX + radius, rect.midY, gold.opacity(0.5))
        case .glow:
            let pulse = [0.35, 0.55, 0.8, 0.55][frame / 2 % 4]
            pixel(rect.minX + 2, rect.minY + 1, cream.opacity(pulse), width: rect.width - 4, height: 2)
        case .clock:
            let angle = Double(frame % 32) / 32 * 2 * .pi
            let cx = rect.midX, cy = rect.midY
            let hx = cx + CGFloat(cos(angle)) * 2
            let hy = cy + CGFloat(sin(angle)) * 2
            pixel(cx, cy, amber)
            pixel(hx, hy, cream)
        case .led:
            let index = (frame / 3) % 3
            for step in 0..<3 {
                let y = rect.minY + CGFloat(step) * 3
                pixel(rect.minX, y, step == index ? cream : gold.opacity(0.25),
                      width: 2, height: 1)
            }
        case .keys:
            let column = (frame / 2) % Int(rect.width)
            pixel(rect.minX + CGFloat(column), rect.minY, gold.opacity(0.85),
                  height: rect.height)
        case .sound:
            let radius = CGFloat(1 + frame % 3)
            for step in 0..<2 {
                let r = radius + CGFloat(step)
                pixel(rect.midX + r, rect.midY - r, gold.opacity(0.65))
                pixel(rect.midX + r, rect.midY + r, gold.opacity(0.65))
            }
        case .muted:
            if frame % 12 < 6 {
                pixel(rect.minX + 1, rect.minY + 1, amber, width: rect.width - 2)
            }
        case .keyhole:
            let pulse = [0.35, 0.7, 0.35][frame / 3 % 3]
            pixel(rect.midX - 1, rect.minY, gold.opacity(pulse), width: 2, height: 2)
        case .zipper:
            let sway = CGFloat((frame / 3) % 3) - 1
            pixel(rect.midX + sway, rect.maxY - 2, cream, width: 1, height: 2)
        case .spark:
            if frame % 4 < 2 {
                pixel(rect.minX, rect.minY, cream, width: 1, height: 1)
                pixel(rect.maxX, rect.maxY, amber, width: 1, height: 1)
            }
        case .battery:
            let filled = 2 + (frame / 4) % 3
            for index in 0..<filled {
                pixel(rect.minX + CGFloat(index) * 2, rect.minY,
                      index == filled - 1 ? cream : gold, width: 1.5, height: rect.height)
            }
        case .steam:
            for wisp in 0..<3 {
                let x = rect.minX + CGFloat(wisp) * 2
                let y = rect.maxY - CGFloat((frame / 2 + wisp * 3) % Int(rect.height))
                pixel(x, y, cream.opacity(0.55))
                pixel(x + 0.5, y - 1, cream.opacity(0.3))
            }
        case .twinkle:
            let stars = [(0.0, 1.0), (3.0, 3.0), (6.0, 0.0)]
            for (index, star) in stars.enumerated() {
                let on = (frame / 3 + index) % 3 != 0
                if on {
                    pixel(rect.minX + star.0, rect.minY + star.1, cream)
                }
            }
        case .breath:
            let alpha = [0.25, 0.5, 0.85, 0.5][frame / 3 % 4]
            pixel(rect.midX - 1, rect.midY - 1, gold.opacity(alpha), width: 2, height: 2)
        case .arrow:
            let bob = CGFloat((frame / 2) % 2)
            pixel(rect.midX, rect.minY + bob, cream, width: 2, height: 2)
            pixel(rect.midX - 1, rect.minY + 2 + bob, cream, width: 4, height: 1)
        case .sand:
            let y = rect.minY + CGFloat((frame / 2) % Int(rect.height))
            pixel(rect.midX, y, cream)
            let pile = CGFloat(1 + (frame / 8) % 3)
            pixel(rect.midX - pile / 2, rect.maxY - 1, gold, width: pile, height: 1)
        case .fan:
            let angle = Double(frame) / 8 * 2 * .pi
            let radius: CGFloat = 3
            for blade in 0..<3 {
                let a = angle + Double(blade) * 2 * .pi / 3
                pixel(rect.midX + CGFloat(cos(a)) * radius,
                      rect.midY + CGFloat(sin(a)) * radius, cream)
            }
        case .eject:
            if frame % 6 < 4 {
                pixel(rect.midX - 2, rect.minY, amber, width: 5)
                pixel(rect.midX, rect.minY + 1, cream, width: 1, height: 2)
            }
        case .signal:
            let radius = CGFloat(1 + frame % 3)
            pixel(rect.midX + radius, rect.maxY - radius, gold.opacity(0.7))
            pixel(rect.midX + radius + 1, rect.maxY - radius - 1, gold.opacity(0.4))
        case .date:
            let flip = CGFloat((frame / 3) % 2)
            pixel(rect.minX + 1, rect.minY + 1 + flip, cream, width: rect.width - 2)
        case .cursor:
            if frame % 8 < 4 {
                pixel(rect.minX + 2, rect.maxY - 2, cream, width: 2, height: 1.5)
            }
        case .ripple:
            let column = (frame / 2) % Int(rect.width)
            pixel(rect.minX + CGFloat(column), rect.minY, gold.opacity(0.7),
                  height: rect.height)
        }
    }
}
