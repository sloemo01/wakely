import Foundation

enum KeepAwakeSource: String, Equatable {
    case none, menu, settings, savedDefault
}

/// Read-only truth for menu presentation. `active` always reflects a live
/// system assertion; the requested duration is retained separately rather
/// than inferred from time remaining.
struct KeepAwakeSnapshot: Equatable {
    let active: Bool
    let durationMinutes: Int?
    let durationKnown: Bool
    let source: KeepAwakeSource
    let deadline: Date?
    let lastMenuMinutes: Int?
}

struct KeepAwakeMenuPresentation {
    static let choices: [(title: String, minutes: Int)] = [
        ("Indefinitely", 0), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240)
    ]

    static func isChecked(minutes: Int, snapshot: KeepAwakeSnapshot) -> Bool {
        guard snapshot.active, snapshot.durationKnown else { return false }
        return snapshot.durationMinutes == (minutes == 0 ? nil : minutes)
    }

    static func statusText(snapshot: KeepAwakeSnapshot, now: Date = Date()) -> String? {
        guard snapshot.active else {
            guard let last = snapshot.lastMenuMinutes else { return nil }
            return "Last used: \(durationTitle(last))"
        }
        guard snapshot.durationKnown else { return "Keep Awake active" }
        let choice = snapshot.durationMinutes.map(durationTitle) ?? "Indefinitely"
        guard let deadline = snapshot.deadline else {
            return "\(choice) · active"
        }
        let remaining = max(0, Int(deadline.timeIntervalSince(now)))
        guard remaining > 0 else { return "\(choice) · finishing" }
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        let tail = hours > 0
            ? "\(hours) hr \(minutes) min remaining"
            : "\(max(1, minutes)) min remaining"
        return "\(choice) · \(tail)"
    }

    static func durationTitle(_ minutes: Int) -> String {
        choices.first(where: { $0.minutes == minutes })?.title
            ?? (minutes > 0 ? "\(minutes) minutes" : "Indefinitely")
    }
}