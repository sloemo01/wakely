// Pure planner/script tests. Never calls apply(), restore(), osascript, pmset,
// administrator authorization, or changes any system/UserDefaults setting.
import Foundation

@main
struct PrivilegedComponentServiceTests {
    @MainActor static func main() throws {
        let text = """
        Battery Power:
         lowpowermode 0
         powernap 1
         womp 0
         sleep 3
         proximitywake 1
        AC Power:
         lowpowermode 2
         autorestart 0
         powernap 1
        """
        let snapshot = PrivilegedComponentService.parseSnapshot(text)
        precondition(snapshot.value(.lowpowermode, .ac) == 2)
        let low = try PrivilegedComponentService.makeLease(componentID: "lowPowerWhileClosed", snapshot: snapshot, resetDate: nil)
        precondition(low.changes.count == 1)
        precondition(low.changes[0].source == .battery)
        precondition(low.changes[0].previous == 0 && low.changes[0].requested == 1)
        let lowScript = try PrivilegedComponentService.script(for: low, restoring: false)
        precondition(lowScript.contains("/usr/bin/pmset -b lowpowermode 1"))
        precondition(lowScript.contains("apply refused"))
        let restoreScript = try PrivilegedComponentService.script(for: low, restoring: true)
        precondition(restoreScript.contains("/usr/bin/pmset -b lowpowermode 0"))

        let sleep = try PrivilegedComponentService.makeLease(componentID: "sleepMeansSleep", snapshot: snapshot, resetDate: nil)
        precondition(Set(sleep.changes.map { $0.setting }) == Set([.powernap, .proximitywake]))
        precondition(sleep.changes.allSatisfy { $0.source == .battery && $0.requested == 0 })
        let sleepScript = try PrivilegedComponentService.script(for: sleep, restoring: false)
        precondition(!sleepScript.contains("schedule cancelall"))

        let home = try PrivilegedComponentService.makeLease(componentID: "homeServer", snapshot: snapshot, resetDate: nil)
        precondition(home.changes.count == 1 && home.changes[0].setting == .autorestart && home.changes[0].source == .ac)
        expectFailure { _ = try PrivilegedComponentService.makeLease(componentID: "homeServer", snapshot: .init(), resetDate: nil) }
        for unsupported in ["passwordAfterClose", "fanBoost", "stayOffWhenOpened", "arbitrary; reboot"] {
            expectFailure { _ = try PrivilegedComponentService.makeLease(componentID: unsupported, snapshot: snapshot, resetDate: nil) }
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        expectFailure { _ = try PrivilegedComponentService.makeLease(componentID: "sleepUntilReset", snapshot: snapshot, resetDate: nil, now: now) }
        expectFailure { _ = try PrivilegedComponentService.makeLease(componentID: "sleepUntilReset", snapshot: snapshot, resetDate: now.addingTimeInterval(-1), now: now) }
        let reset = try PrivilegedComponentService.makeLease(componentID: "sleepUntilReset", snapshot: snapshot, resetDate: now.addingTimeInterval(3600), now: now)
        precondition(reset.wake != nil && PrivilegedComponentService.validWake(reset.wake!))
        let cancellation = try PrivilegedComponentService.script(for: reset, restoring: true)
        precondition(cancellation.contains("schedule cancel wake"))
        precondition(cancellation.contains(reset.wake!.owner))
        precondition(!cancellation.contains("cancelall"))
        let injected = PrivilegedComponentService.Lease(componentID: "sleepUntilReset", changes: [], wake: .init(dateText: "'; /bin/evil", owner: "dev.wakely.reset.x"), createdAt: now)
        expectFailure { _ = try PrivilegedComponentService.script(for: injected, restoring: false) }
        let badValue = PrivilegedComponentService.Lease(componentID: "lowPowerWhileClosed", changes: [.init(source: .battery, setting: .lowpowermode, previous: -99, requested: 1)], wake: nil, createdAt: now)
        expectFailure { _ = try PrivilegedComponentService.script(for: badValue, restoring: true) }
        // Recovery data written before the vocabulary change spells the
        // component identifier "moduleID"; it must still decode.
        let legacyData = Data("""
        {"moduleID":"lowPowerWhileClosed","changes":[],"createdAt":688889600}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let legacyLease = try decoder.decode(PrivilegedComponentService.Lease.self, from: legacyData)
        precondition(legacyLease.componentID == "lowPowerWhileClosed")
        print("PASS: protected-component parsing, legacy recovery data, allowlist, snapshots, restore values, owned wake scheduling, cancellation scope, unsupported operations, and injection rejection. No system commands executed.")
    }
    static func expectFailure(_ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected rejection") }
        catch { /* expected */ }
    }
}
