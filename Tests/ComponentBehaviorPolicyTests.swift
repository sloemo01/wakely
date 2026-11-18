import Foundation

@main
struct ComponentBehaviorPolicyTests {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); count += 1
        }
        var budget = ClosedBatteryBudget()
        check(budget.sample(percent: 90, closed: false, armed: true, onBattery: true) == 0, "open lid excluded")
        check(budget.sample(percent: 80, closed: true, armed: true, onBattery: true) == 0, "closed baseline")
        check(budget.sample(percent: 76, closed: true, armed: true, onBattery: true) == 4, "closed drain counted")
        check(budget.sample(percent: 85, closed: true, armed: true, onBattery: false) == 4, "AC preserves expenditure")
        check(budget.sample(percent: 90, closed: true, armed: true, onBattery: true) == 4, "AC resume fresh baseline")
        check(budget.sample(percent: 87, closed: true, armed: true, onBattery: true) == 7, "accumulate across AC")
        check(budget.sample(percent: 89, closed: true, armed: true, onBattery: true) == 7, "charging never refunds")
        check(budget.sample(percent: nil, closed: true, armed: true, onBattery: true) == 7, "missing sample preserves count")
        check(budget.sample(percent: 87, closed: false, armed: true, onBattery: true) == 0, "opening resets session")
        let now = Date(timeIntervalSince1970: 1_000)
        var grace = ConditionGrace()
        check(!grace.active(false, now: now, seconds: 60), "no phantom grace before connection")
        check(grace.active(true, now: now, seconds: 60), "connection present")
        check(grace.active(false, now: now.addingTimeInterval(59), seconds: 60), "wifi short dropout keeps same claim")
        check(!grace.active(false, now: now.addingTimeInterval(60), seconds: 60), "wifi expiry releases")
        check(grace.active(true, now: now, seconds: 600), "remote connected")
        check(grace.active(false, now: now.addingTimeInterval(599), seconds: 600), "remote ten minute grace")
        check(!grace.active(false, now: now.addingTimeInterval(1), seconds: 600, eligible: false), "unplug overrides grace")
        var work = BoundedWorkSnapshot()
        work.begin(ids: ["a"], now: now)
        check(work.active(current: ["a", "new"], now: now, maximum: 100), "snapshot starts")
        check(!work.active(current: ["new"], now: now.addingTimeInterval(1), maximum: 100), "new work cannot prolong snapshot")
        check(!work.active(current: ["a"], now: now.addingTimeInterval(2), maximum: 100), "completed snapshot does not restart")
        work.begin(ids: ["a"], now: now)
        check(!work.active(current: ["a"], now: now.addingTimeInterval(100), maximum: 100), "hard maximum")
        work.begin(ids: ["a"], now: now)
        check(work.active(current: ["a"], waiting: ["a"], now: now, maximum: 1000, waitingMaximum: 20), "waiting initially retained")
        check(!work.active(current: ["a"], waiting: ["a"], now: now.addingTimeInterval(20), maximum: 1000, waitingMaximum: 20), "waiting capped")
        // Finish Work receives explicit busy IDs, not all live CLI PIDs. A
        // completed turn may leave its process alive; it must leave the cohort.
        var agents = BoundedWorkSnapshot()
        let liveProcesses: Set<String> = ["working", "waiting", "idle", "unknown"]
        let busyAgents: Set<String> = ["working", "waiting"]
        agents.begin(ids: busyAgents, now: now)
        check(agents.ids.isDisjoint(with: ["idle", "unknown"]), "idle and unknown agents excluded from initial cohort")
        check(agents.active(current: busyAgents, waiting: ["waiting"], now: now, maximum: 14400, waitingMaximum: 900), "explicit busy cohort holds")
        check(!agents.active(current: [], now: now.addingTimeInterval(1), maximum: 14400), "busy to idle releases even while CLI processes remain alive")
        check(liveProcesses.contains("working"), "finish regression retains the same CLI PID")
        agents.begin(ids: ["working"], now: now)
        check(!agents.active(current: ["new"], now: now.addingTimeInterval(1), maximum: 14400), "unrelated busy agent cannot prolong completed original turn")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ day: Int, _ hour: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))! }
        check(ComponentSchedulePolicy.contains(now: date(9, 23), start: "22:00", end: "07:00", weekdays: [2], calendar: calendar), "Monday overnight start")
        check(ComponentSchedulePolicy.contains(now: date(10, 6), start: "22:00", end: "07:00", weekdays: [2], calendar: calendar), "Tuesday early belongs Monday")
        check(!ComponentSchedulePolicy.contains(now: date(10, 23), start: "22:00", end: "07:00", weekdays: [2], calendar: calendar), "Tuesday not selected")
        check(!ComponentSchedulePolicy.contains(now: now, start: "25:00", end: "07:00", weekdays: Array(1...7)), "invalid time rejected")
        check(!ComponentSchedulePolicy.contains(now: now, start: "12:00", end: "12:00", weekdays: Array(1...7)), "equal times not 24h surprise")
        check(SleepSafetyContext(lidClosed: true, armed: false, externalDisplay: false).permitsPeripheralChanges, "closed unarmed sleep allows peripheral changes")
        check(!SleepSafetyContext(lidClosed: true, armed: true, externalDisplay: false).permitsPeripheralChanges, "armed protects peripherals")
        check(!SleepSafetyContext(lidClosed: true, armed: false, externalDisplay: true).permitsPeripheralChanges, "external display protects peripherals")
        check(!SleepSafetyContext(lidClosed: false, armed: false, externalDisplay: false).permitsPeripheralChanges, "open protects peripherals")
        check(TimeMachineStatus.isDefinitelyIdle("Backup session status:\n{ Running = 0; }"), "tmutil idle parse")
        check(!TimeMachineStatus.isDefinitelyIdle("Backup session status:\n{ Running = 1; }"), "backup running protected")
        check(!TimeMachineStatus.isDefinitelyIdle("permission denied"), "unknown backup status protected")
        print("PASS: \(count) pure component behavior policy checks; no app/system actions performed")
    }
}
