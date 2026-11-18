import SwiftUI

/// A one-shot perimeter trace owned only by the component's committed on/off
/// state. The ordinary border stays underneath; hover and focus are separate.
/// Using the trim's animatable endpoint lets an interrupted transition reverse
/// from its current position without timers, tasks or a perpetual drawing loop.
struct ComponentActivationStroke<Outline: InsettableShape>: View {
    let shape: Outline
    let isOn: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        shape.inset(by: 0.5)
            .trim(from: 0, to: isOn ? 1 : 0)
            .stroke(color, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            .animation(reduceMotion ? nil : .easeInOut(duration: isOn ? 0.46 : 0.30), value: isOn)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A distinct, neutral keyboard-focus cue. Four short pixel brackets cannot be
/// mistaken for the continuous on-state perimeter, even while the card is off.
struct ComponentFocusCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let arm = min(8, min(rect.width, rect.height) / 4)
        var path = Path()
        for (x, y, dx, dy) in [
            (rect.minX, rect.minY, CGFloat(1), CGFloat(1)),
            (rect.maxX, rect.minY, CGFloat(-1), CGFloat(1)),
            (rect.maxX, rect.maxY, CGFloat(-1), CGFloat(-1)),
            (rect.minX, rect.maxY, CGFloat(1), CGFloat(-1))
        ] {
            path.move(to: CGPoint(x: x + dx * arm, y: y))
            path.addLine(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + dy * arm))
        }
        return path
    }
}
