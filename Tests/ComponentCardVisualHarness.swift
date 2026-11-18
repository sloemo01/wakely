import AppKit
import SwiftUI

// Uses the shipped ComponentCard, catalog, theme, sprite, and switch. No engine is
// instantiated: enablement belongs only to this local observable fixture.
@MainActor private final class CardVisualState: ObservableObject {
    @Published var isOn = false
}
private struct CardVisualFixture: View {
    @ObservedObject var state: CardVisualState
    var body: some View {
        ComponentCard(component: ComponentCatalog.all.first { $0.id == "agentStatus" }!,
                      isOn: state.isOn, onToggle: { state.isOn.toggle() }, onOpen: {})
            .frame(width: 260, height: 180)
            .padding(10)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
    }
}

@main struct ComponentCardVisualHarness {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let state = CardVisualState()
        let view = NSHostingView(rootView: CardVisualFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 280, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.close() }
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures += 1 }
        }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            repeat { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.004))) }
            while Date() < end
        }
        func capture(_ name: String) throws -> Int {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "CardCapture", code: 1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "CardCapture", code: 2)
            }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            var accent = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                let px = (CGFloat(x) + 0.5) * 280 / CGFloat(rep.pixelsWide)
                let py = (CGFloat(y) + 0.5) * 200 / CGFloat(rep.pixelsHigh)
                // Only the perimeter band: sprite, switch and text cannot affect
                // this metric. Include outside the card to catch outset rings.
                let inOuter = px >= 6 && px <= 274 && py >= 6 && py <= 194
                let inInner = px > 14 && px < 266 && py > 14 && py < 186
                if inOuter && !inInner,
                   let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.redComponent > 0.25, c.greenComponent > 0.15,
                   c.redComponent > c.blueComponent * 1.6,
                   c.greenComponent > c.blueComponent * 1.3 {
                    accent += 1
                }
            }}
            print("CAPTURE \(name) perimeterAccentPixels=\(accent) size=\(rep.pixelsWide)x\(rep.pixelsHigh)")
            return accent
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        print("ENVIRONMENT accessibilityDisplayShouldReduceMotion=\(reduced)")
        pump(0.15)
        let off = try capture("normal-off")
        check(off == 0, "actual disabled card has no accent perimeter")
        state.isOn = true
        pump(0.10)
        let draw = try capture("on-100ms")
        pump(0.55)
        let on = try capture("on-settled")
        check(on > 300, "actual enabled card has accent perimeter")
        check(reduced ? draw == on : draw > off && draw < on,
              "actual on-100ms matches motion preference (intermediate unless reduced)")
        state.isOn = false
        pump(0.10)
        let erase = try capture("off-100ms")
        check(reduced ? erase == off : erase > off && erase < on,
              "actual off-100ms matches motion preference (intermediate unless reduced)")
        pump(0.5)
        check(try capture("off-settled") == 0, "actual disabled card retracts completely")
        state.isOn = true
        pump(0.65)
        state.isOn = false
        pump(0.10)
        let reverseStart = try capture("reversal-start")
        state.isOn = true
        pump(0.08)
        let reverse = try capture("reversal-80ms")
        check(reduced ? reverse == on : reverse > off && reverse < on && reverseStart > off && reverseStart < on,
              "actual reversal retains an intermediate frame before settling")
        print("OBSERVATION reversal accent count \(reverseStart) -> \(reverse); immediate monotonic direction is not asserted")
        pump(0.6)
        check(try capture("reversal-settled") == on, "actual reversal settles enabled")
        state.isOn = false
        pump(0.5)
        check(try capture("off-final") == 0, "actual final off leaves no persistent gold stroke")
        print("LIMIT No hover or keyboard focus input is synthesized; focus may be assigned automatically by SwiftUI, but focused/unfocused states are not controlled separately. Hover/focus styling has source contracts. Current Reduce Motion preference is read, never changed. App bundle sprite resources are not loaded; perimeter measurements exclude the sprite.")
        print("OUTPUT \(output.path)")
        print("SUMMARY \(failures) failed assertion(s); no foreground activation or system actions requested")
        if failures != 0 { exit(1) }
    }
}
