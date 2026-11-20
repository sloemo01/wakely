// UninstallWatcherPolicyTests — the deletion watcher's decision table.
//
// Compiled standalone against UninstallWatcher/Policy.swift: no launchd,
// no file system, no processes. The I/O side is covered by the live test.

import Foundation

@main
struct UninstallWatcherPolicyTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        if condition {
            print("ok - \(name)")
        } else {
            print("FAIL - \(name)")
            failures += 1
        }
    }

    static func main() {
        let wipe = UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: false, deletionConfirmed: true,
                                                consecutiveAbsentChecks: UninstallWatcherPolicy.absentChecksBeforeWipe)
        check(wipe == .wipe, "app absent for the full grace wipes")

        check(UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: false, deletionConfirmed: true,
                                            consecutiveAbsentChecks: UninstallWatcherPolicy.absentChecksBeforeWipe - 1) == .keepWatching,
              "one check short of the grace keeps watching")

        check(UninstallWatcherPolicy.decide(appRunning: true, appCandidatesPresent: false, deletionConfirmed: true,
                                            consecutiveAbsentChecks: 999) == .keepWatching,
              "a running Wakely process always keeps everything")

        check(UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: true, deletionConfirmed: true,
                                            consecutiveAbsentChecks: 999) == .keepWatching,
              "an installed app at a candidate location always keeps everything")

        check(UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: false, deletionConfirmed: true,
                                            consecutiveAbsentChecks: 0) == .keepWatching,
              "the first absent probe never wipes")

        check(UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: false, deletionConfirmed: true,
                                            consecutiveAbsentChecks: 3,
                                            requiredAbsentChecks: 3) == .wipe,
              "the daemon threshold parameterises the same decision")

        check(UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: false, deletionConfirmed: true,
                                            consecutiveAbsentChecks: 2,
                                            requiredAbsentChecks: 3) == .keepWatching,
              "below the daemon threshold keeps watching")

        check(UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: false,
                                            deletionConfirmed: false,
                                            consecutiveAbsentChecks: 999) == .keepWatching,
              "absence alone never wipes: without Trash evidence a moved or unindexed app keeps everything")

        check(UninstallWatcherPolicy.decide(appRunning: false, appCandidatesPresent: false,
                                            deletionConfirmed: true,
                                            consecutiveAbsentChecks: 999,
                                            requiredAbsentChecks: 1000) == .keepWatching,
              "Trash evidence still waits for the full grace")

        // Test-only seams: absent or malformed values fall back to production cadence.
        check(UninstallWatcherPolicy.pollIntervalFromEnvironment([:]) == UninstallWatcherPolicy.pollInterval,
              "no env override keeps the production poll interval")
        check(UninstallWatcherPolicy.pollIntervalFromEnvironment(["WAKELY_UNINSTALL_WATCHER_POLL_SECONDS": "5"]) == 5,
              "env override shortens the poll interval")
        check(UninstallWatcherPolicy.pollIntervalFromEnvironment(["WAKELY_UNINSTALL_WATCHER_POLL_SECONDS": "0"]) == UninstallWatcherPolicy.pollInterval,
              "a zero poll override is rejected")
        check(UninstallWatcherPolicy.pollIntervalFromEnvironment(["WAKELY_UNINSTALL_WATCHER_POLL_SECONDS": "junk"]) == UninstallWatcherPolicy.pollInterval,
              "a non-numeric poll override is rejected")
        check(UninstallWatcherPolicy.absentChecksFromEnvironment([:]) == UninstallWatcherPolicy.absentChecksBeforeWipe,
              "no env override keeps the production grace")
        check(UninstallWatcherPolicy.absentChecksFromEnvironment(["WAKELY_UNINSTALL_WATCHER_ABSENT_CHECKS": "2"]) == 2,
              "env override shortens the grace")
        check(UninstallWatcherPolicy.absentChecksFromEnvironment(["WAKELY_UNINSTALL_WATCHER_ABSENT_CHECKS": "0"]) == UninstallWatcherPolicy.absentChecksBeforeWipe,
              "a zero grace override is rejected")

        // Identity constants the app, watcher, helper and tests all agree on.
        check(UninstallWatcherPolicy.bundleID == "dev.wakely.app", "bundle id is the shipped one")
        check(UninstallWatcherPolicy.agentLabel == "dev.wakely.uninstall-watcher", "watcher label is distinct from the crash agent")
        check(UninstallWatcherPolicy.agentLabel != "dev.wakely.agent", "watcher label must not collide with the crash watchdog")
        check(UninstallWatcherPolicy.agentPlistName == "dev.wakely.uninstall-watcher.plist", "watcher plist name matches its label")
        check(UninstallWatcherPolicy.installRecordFileName == "install.json", "install record name is stable")
        check(UninstallWatcherPolicy.daemonPollInterval > UninstallWatcherPolicy.pollInterval,
              "the root daemon polls more slowly than the user watcher")
        check(Double(UninstallWatcherPolicy.daemonAbsentChecksBeforeWipe) * UninstallWatcherPolicy.daemonPollInterval
              > Double(UninstallWatcherPolicy.absentChecksBeforeWipe) * UninstallWatcherPolicy.pollInterval,
              "the daemon grace is longer than the user watcher grace")

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("all uninstall watcher policy checks passed")
    }
}
