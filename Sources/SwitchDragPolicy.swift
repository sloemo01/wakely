import Foundation

/// Match the endpoint of a native switch, not the signless drag distance.
enum SwitchDragPolicy {
    static func desiredState(isOn: Bool, translation: Double, travel: Double) -> Bool {
        guard translation.isFinite, travel.isFinite, travel > 0 else { return isOn }
        let position = min(travel, max(0, (isOn ? travel : 0) + translation))
        return position >= travel / 2
    }
}
