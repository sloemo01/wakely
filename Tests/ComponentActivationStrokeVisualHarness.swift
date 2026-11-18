import AppKit
import SwiftUI

// Standalone visual regression harness; compiles only with ComponentActivationStroke.swift.
// Never imports the app or changes component/system state. Window is prohibited-activation,
// borderless, and placed offscreen. Captures are view-local, not screen recordings.
@MainActor
private final class StrokeState: ObservableObject {
    @Published var isOn: Bool
    init(_ isOn: Bool) { self.isOn = isOn }
}

private struct StrokeFixture: View {
    @ObservedObject var state: StrokeState
    var body: some View {
        ComponentActivationStroke(shape: RoundedRectangle(cornerRadius: 16),
                                  isOn: state.isOn, color: .red)
            .frame(width: 220, height: 100)
            .padding(10)
            .background(Color.black)
    }
}

@main
struct ComponentActivationStrokeVisualHarness {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
                         ?? "/tmp/component-activation-stroke-visual", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL") \(message)")
            if !condition { failures.append(message) }
        }
        func pump(_ seconds: Double) {
            let end = Date().addingTimeInterval(seconds)
            repeat { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.004))) }
            while Date() < end
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        print("ENVIRONMENT accessibilityDisplayShouldReduceMotion=\(reduced)")
        func make(_ on: Bool) -> (StrokeState, NSHostingView<StrokeFixture>, NSWindow) {
            let state = StrokeState(on)
            let view = NSHostingView(rootView: StrokeFixture(state: state))
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 240, height: 120),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            view.layoutSubtreeIfNeeded()
            return (state, view, window)
        }
        func capture(_ view: NSView, _ name: String) throws -> Int {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw NSError(domain: "StrokeCapture", code: 1)
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "StrokeCapture", code: 2)
            }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            var red = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   c.redComponent > 0.25 && c.redComponent > c.greenComponent * 2 && c.redComponent > c.blueComponent * 2 {
                    red += 1
                }
            }}
            print("CAPTURE \(name) redPixels=\(red) size=\(rep.pixelsWide)x\(rep.pixelsHigh)")
            return red
        }
        let (state, view, window) = make(false)
        pump(0.1)
        let off = try capture(view, "off-settled")
        check(off == 0, "settled off has no colored perimeter")
        state.isOn = true
        pump(0.10)
        let draw = try capture(view, "on-100ms")
        pump(0.55)
        let on = try capture(view, "on-settled")
        check(on > 300, "settled on has colored perimeter")
        check(reduced ? draw == on : (draw > off && draw < on),
              reduced ? "Reduce Motion on is settled at 100ms" : "100ms on is a genuinely intermediate rendered perimeter")
        state.isOn = false
        pump(0.10)
        let erase = try capture(view, "off-100ms")
        check(reduced ? erase == off : (erase > off && erase < on),
              reduced ? "Reduce Motion off is settled at 100ms" : "100ms off is a genuinely intermediate rendered perimeter")
        state.isOn = true
        pump(0.08)
        let reverse = try capture(view, "reversal-80ms")
        check(reduced ? reverse == on : (reverse > erase && reverse < on),
              reduced ? "Reduce Motion reversal is settled at 80ms" : "off-to-on reversal advances from intermediate perimeter")
        pump(0.6)
        _ = try capture(view, "reversal-settled")
        state.isOn = false
        pump(0.45)
        check(try capture(view, "off-final") == 0, "off animation finishes empty")
        window.close()

        let (_, initialView, initialWindow) = make(true)
        let initial = try capture(initialView, "initial-on-immediate")
        pump(0.12)
        let initialLater = try capture(initialView, "initial-on-120ms")
        pump(0.5)
        let initialSettled = try capture(initialView, "initial-on-settled")
        check(initial == initialSettled && initialLater == initialSettled && initialSettled > 300,
              "already-on initial mount has no draw-in")
        initialWindow.close()

        print("LIMIT Reduce Motion environment is read-only in this macOS SwiftUI SDK; not overridden or system-toggled. Runtime motion samples use current system preference.")
        print("OUTPUT \(output.path)")
        print("SUMMARY \(failures.count) failed assertion(s); no foreground activation requested")
        if !failures.isEmpty { exit(1) }
    }
}
