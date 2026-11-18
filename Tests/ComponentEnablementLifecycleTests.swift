import Foundation

// Compile with Sources/ComponentBehaviorPolicy.swift. Pure state transitions only:
// no app, helper, settings, permissions, processes, or hardware are touched.
@main
struct ComponentEnablementLifecycleTests {
    static func main() {
        var pending = PendingComponentEnablement()
        let first = pending.begin("fanBoost")!
        assert(pending.begin("fanBoost") == nil, "Repeated on coalesces pending probes")
        pending.cancel("fanBoost")
        assert(!pending.consume("fanBoost", token: first), "Off cancels before persisted on")
        let second = pending.begin("fanBoost")!
        assert(second != first)
        assert(!pending.consume("fanBoost", token: first), "Old completion cannot consume a new on request")
        assert(pending.consume("fanBoost", token: second), "Newest completion can commit")
        assert(!pending.consume("fanBoost", token: second), "Completion commits at most once")
        let third = pending.begin("lowPowerWhileClosed")!
        let fourth = pending.begin("stayOffWhenOpened")!
        pending.cancelAll()
        assert(!pending.consume("lowPowerWhileClosed", token: third), "Stop invalidates session enable")
        assert(!pending.consume("stayOffWhenOpened", token: fourth), "Stop invalidates persistent enable")
        let restarted = pending.begin("lowPowerWhileClosed")!
        assert(!pending.consume("lowPowerWhileClosed", token: third), "Stop/restart does not accept old reply")
        assert(pending.consume("lowPowerWhileClosed", token: restarted))

        func wanted(_ enabled: Bool = true, persistent: Bool = false,
                    shutdown: Bool = false, armed: Bool = true, closed: Bool = true,
                    epoch: Int = 7) -> Bool {
            ProtectedApplyLifetime.wanted(enabled: enabled, persistent: persistent,
                shuttingDown: shutdown, armed: armed, lidClosed: closed,
                requestedEpoch: 7, currentEpoch: epoch)
        }
        assert(wanted())
        assert(!wanted(closed: false), "Open lid prevents session apply and late commit")
        assert(!wanted(armed: false), "Disarm prevents session apply and late commit")
        assert(!wanted(false), "Disabled component rolls back")
        assert(!wanted(shutdown: true), "Quit invalidates session write")
        assert(!wanted(epoch: 8), "Open/reclose or disable/re-enable epoch rejects stale reply")
        assert(wanted(persistent: true, armed: false, closed: false, epoch: 8), "Persistent setting is independent of closed-session epochs")
        assert(wanted(persistent: true, shutdown: true), "Persistent settings survive ordinary quit by design")
        assert(!wanted(false, persistent: true), "Persistent disable still rolls back")
        print("PASS component enablement tokens and protected write lifetime (19 assertions; pure policy only)")
    }
}
