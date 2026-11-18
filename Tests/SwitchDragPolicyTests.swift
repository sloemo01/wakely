import Foundation

@main struct SwitchDragPolicyTests {
    static func main() {
        func want(_ on: Bool, _ translation: Double) -> Bool {
            SwitchDragPolicy.desiredState(isOn: on, translation: translation, travel: 22)
        }
        precondition(!want(false, -80), "Dragging off left must stay off")
        precondition(want(true, 80), "Dragging on right must stay on")
        precondition(want(false, 15), "Off can drag to on")
        precondition(!want(true, -15), "On can drag to off")
        precondition(!want(false, 5) && want(true, -5), "Short drag returns to its original endpoint")
        precondition(want(true, .nan), "Nonfinite input does not change state")
        precondition(!SwitchDragPolicy.desiredState(isOn: false, translation: 50, travel: 0))
        print("PASS: switch direction, endpoint intent, short-drag settling and invalid input")
    }
}
