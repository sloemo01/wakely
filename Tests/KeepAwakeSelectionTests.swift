import Foundation

@main
struct KeepAwakeSelectionTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fatalError(message) }
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let active = KeepAwakeSnapshot(active: true, durationMinutes: 120, durationKnown: true,
                                       source: .menu, deadline: now.addingTimeInterval(3720),
                                       lastMenuMinutes: 120)
        check(KeepAwakeMenuPresentation.isChecked(minutes: 120, snapshot: active), "2 hours checked")
        check(!KeepAwakeMenuPresentation.isChecked(minutes: 60, snapshot: active), "1 hour unchecked")
        check(!KeepAwakeMenuPresentation.isChecked(minutes: 0, snapshot: active), "indefinite unchecked")
        check(KeepAwakeMenuPresentation.statusText(snapshot: active, now: now)
              == "2 hours · 1 hr 2 min remaining", "remaining duration is truthful")

        let indefinite = KeepAwakeSnapshot(active: true, durationMinutes: nil, durationKnown: true,
                                           source: .menu, deadline: nil, lastMenuMinutes: 0)
        check(KeepAwakeMenuPresentation.isChecked(minutes: 0, snapshot: indefinite), "indefinite checked")
        check(KeepAwakeMenuPresentation.statusText(snapshot: indefinite, now: now)
              == "Indefinitely · active", "indefinite status")

        let custom = KeepAwakeSnapshot(active: true, durationMinutes: 30, durationKnown: true,
                                       source: .settings, deadline: now.addingTimeInterval(600),
                                       lastMenuMinutes: nil)
        check(KeepAwakeMenuPresentation.choices.allSatisfy {
            !KeepAwakeMenuPresentation.isChecked(minutes: $0.minutes, snapshot: custom)
        }, "custom duration never fabricates a standard selection")
        check(KeepAwakeMenuPresentation.statusText(snapshot: custom, now: now)?.hasPrefix("30 minutes")
              == true, "custom duration is named truthfully")

        let expired = KeepAwakeSnapshot(active: false, durationMinutes: 60, durationKnown: true,
                                        source: .menu, deadline: nil, lastMenuMinutes: 60)
        check(KeepAwakeMenuPresentation.choices.allSatisfy {
            !KeepAwakeMenuPresentation.isChecked(minutes: $0.minutes, snapshot: expired)
        }, "expired session cannot leave an active check")
        check(KeepAwakeMenuPresentation.statusText(snapshot: expired, now: now)
              == "Last used: 1 hour", "inactive history is labelled separately")

        let failed = KeepAwakeSnapshot(active: false, durationMinutes: 120, durationKnown: true,
                                       source: .menu, deadline: now.addingTimeInterval(7200),
                                       lastMenuMinutes: nil)
        check(!KeepAwakeMenuPresentation.isChecked(minutes: 120, snapshot: failed),
              "assertion failure never appears selected")

        let unknown = KeepAwakeSnapshot(active: true, durationMinutes: nil, durationKnown: false,
                                        source: .savedDefault, deadline: nil, lastMenuMinutes: nil)
        check(KeepAwakeMenuPresentation.statusText(snapshot: unknown, now: now) == "Keep Awake active",
              "unknown-duration activity stays active without a false choice")
        print("PASS: \(checks) truthful Keep Awake snapshot and selection checks")
    }
}