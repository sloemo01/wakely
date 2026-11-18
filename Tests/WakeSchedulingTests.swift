// WakeSchedulingTests — owned one-off wake foundation (M6a).
//
// Foundation only. Every test injects its own command runner and uses a fresh
// temporary directory: no pmset (or any other process) is executed, and no real
// power schedule is read or changed.
//
// Standalone compile+run:
//   xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 \
//     -module-cache-path build/componentcache \
//     Sources/HelperProtocol.swift Helper/WakeStore.swift \
//     Tests/WakeSchedulingTests.swift -o /tmp/wakely-wake-tests
//   /tmp/wakely-wake-tests

import Foundation

@main
struct WakeSchedulingTests {
    static func main() {
        do {
            try dateFormatting()
            try datePolicyRejections()
            try scheduleParser()
            try ownershipCancellation()
            try schedulingOutcomes()
            try retention()
            protocolRoundTrip()
        } catch {
            fatalError("Wake scheduling tests failed: \(error)")
        }
        print("Wake scheduling tests passed (date bounds, pmset parser, ownership, "
            + "schedule/cancel outcomes, retention, protocol 3; no pmset execution)")
    }

    // MARK: - Fixtures

    struct Call: Equatable {
        var executable: String
        var arguments: [String]
    }

    /// Records every argv and answers with the test's closure. The production
    /// scheduler is never given this runner; nothing here launches a process.
    final class FakePmset {
        private(set) var calls: [Call] = []
        private let handler: (Call) -> WakeCommandResult

        init(_ handler: @escaping (Call) -> WakeCommandResult) {
            self.handler = handler
        }

        func runner(_ executable: String, _ arguments: [String]) -> WakeCommandResult {
            let call = Call(executable: executable, arguments: arguments)
            calls.append(call)
            return handler(call)
        }

        var arguments: [[String]] { calls.map(\.arguments) }
    }

    static func commandOK(_ stdout: String = "") -> WakeCommandResult {
        WakeCommandResult(status: 0, stdout: stdout, stderr: "",
                          timedOut: false, launchError: nil)
    }

    static func commandFailure(_ message: String = "pmset refused") -> WakeCommandResult {
        WakeCommandResult(status: 1, stdout: "", stderr: message,
                          timedOut: false, launchError: nil)
    }

    static func schedLine(_ kind: String, _ text: String, owner: String? = nil) -> String {
        let suffix = owner.map { " by '\($0)'" } ?? ""
        return " [0]  \(kind) at \(text)\(suffix)"
    }

    static func makeTemporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "wakely-wake-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return path
    }

    static func removeDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String,
                        file: StaticString = #file, line: UInt = #line) {
        guard condition() else { fatalError(message, file: file, line: line) }
    }

    // MARK: - Date format, parser, presence

    static func dateFormatting() throws {
        let now = 1_800_000_000.0  // fixed; these tests never read the wall clock
        let target = (now + 7_200).rounded(.down)
        let text = PmsetSchedule.format(target)
        require(text.range(of: #"^\d{2}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$"#,
                           options: .regularExpression) != nil,
                "format must be MM/dd/yy HH:mm:ss, got '\(text)'")
        guard let parsed = PmsetSchedule.parseDate(text) else {
            fatalError("formatted date did not parse: \(text)")
        }
        require(abs(parsed - target) < 1, "format/parse must round-trip")

        // pmset -g sched has been observed to print a four-digit year even
        // though its input syntax documents MM/dd/yy. Both name one instant.
        guard let long = PmsetSchedule.parseDate("11/11/2026 22:25:23"),
              let short = PmsetSchedule.parseDate("11/11/26 22:25:23") else {
            fatalError("both pmset year spellings must parse")
        }
        require(abs(long - short) < 1, "two- and four-digit years must agree")
        require(PmsetSchedule.canonicalText("11/11/2026 22:25:23") == "11/11/2026 22:25:23",
                "four-digit canonical form")
        require(PmsetSchedule.canonicalText("11/11/26 22:25:23") == "11/11/2026 22:25:23",
                "two-digit year normalizes to the current century")

        // A non-finite instant is never formatted into a real date.
        require(PmsetSchedule.format(.nan) == "", "NaN must not format")
        require(PmsetSchedule.format(.infinity) == "", "infinity must not format")
    }

    static func datePolicyRejections() throws {
        let now = 1_800_000_000.0

        for bad in [nil, Double.nan, Double.infinity, -Double.infinity] as [Double?] {
            guard case .rejected = WakeSchedulePolicy.plan(dateValue: bad, now: now) else {
                fatalError("a non-finite or missing date was accepted")
            }
        }
        for bad in [now - 1, now - 3_600, now + 5, now + 29] {
            guard case .rejected = WakeSchedulePolicy.plan(dateValue: bad, now: now) else {
                fatalError("a past or too-soon date was accepted (\(bad - now) s)")
            }
        }
        guard case .rejected(let horizon) =
                WakeSchedulePolicy.plan(dateValue: now + 30 * 86_400 + 60, now: now) else {
            fatalError("a date beyond 30 days was accepted")
        }
        require(horizon.contains("30 days"), "horizon rejection must explain itself")

        guard case .accepted(let text, let at) =
                WakeSchedulePolicy.plan(dateValue: now + 30, now: now) else {
            fatalError("exactly 30 s ahead must be accepted")
        }
        require(at == now + 30, "accepted instant is preserved")
        require(text == PmsetSchedule.format(now + 30), "accepted text uses the fixed formatter")

        // Strict parsing rejects anything that would have to be normalized to
        // round-trip: impossible dates, non-canonical widths, bad fields.
        for bad in [
            "02/30/26 10:00:00",
            "1/1/26 1:1:1",
            "13/01/26 10:00:00",
            "11/11/26 25:00:00",
            "11/11/26 10:00",
            "not a date",
            "11/11/2026 22:25:23 ",
            "11/11/26\t22:25:23",
        ] {
            require(PmsetSchedule.parseDate(bad) == nil,
                    "a date that does not round-trip was accepted: '\(bad)'")
        }
    }

    static func scheduleParser() throws {
        let header = """
        Repeating power events:
          wakepoweron at 11:30PM every day
        Scheduled power events:
        [0]  wake at 11/11/2026 22:25:23 by 'com.apple.alarm'
        [1]  sleep at 11/12/2026 01:00:00
        """
        let events = PmsetSchedule.parse(header)
        require(events.count == 2, "headers and repeating events are not scheduled events")
        require(events[0].kind == "wake", "kind is parsed")
        require(events[0].owner == "com.apple.alarm", "by '...' suffix is parsed")
        require(events[1].kind == "sleep", "other event types are retained")
        require(events[1].owner == nil, "an absent owner is nil, not an empty string")

        let messy = """
        garbage
        [0] wake at 11/11/26 22:25:23
        [1]  poweron at 11/12/26 07:00:00 by 'com.apple.foo bar'
          
        [2]  shutdown at 11/13/26 09:30:00
        [3]  wake at 11/11/26 22:25:23
        [4]  nonsense at 11/13/26 09:30:00
        [5]  wake at 99/99/99 99:99:99
        [6]  wake at 11/13/26 31:00:00
        """
        let parsed = PmsetSchedule.parse(messy)
        require(parsed.count == 4, "blank, garbage and impossible lines are skipped, got \(parsed.count)")
        require(parsed.filter { $0.kind == "wake" }.count == 2,
                "duplicate dates are kept as separate events")
        require(parsed[1].owner == "com.apple.foo bar", "quoted owners may contain spaces")

        let duplicate = parsed.first { $0.kind == "wake" }!.at
        require(PmsetSchedule.contains(parsed, kind: "wake", at: duplicate),
                "presence matches by kind and instant")
        require(PmsetSchedule.contains(parsed, kind: "wake", at: duplicate + 0.5),
                "presence tolerance is one second")
        require(!PmsetSchedule.contains(parsed, kind: "wake", at: duplicate + 2),
                "presence does not match a different second")
        require(!PmsetSchedule.contains(parsed, kind: "sleep", at: duplicate),
                "presence does not match another kind")
    }

    // MARK: - Ownership and cancellation

    static func ownershipCancellation() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = WakeStore(directoryPath: directory)
        let now = 1_800_000_000.0
        let target = now + 3_600
        let text = PmsetSchedule.format(target)

        // An unowned date is refused and pmset is never run.
        let unowned = FakePmset { _ in
            fatalError("cancel of an unowned date must not run pmset")
        }
        let unownedScheduler = WakeScheduler(store: store, now: { now }, run: unowned.runner)
        let unownedOutcome = unownedScheduler.cancel(dateValue: target)
        require(!unownedOutcome.ok, "an unowned date must be refused")
        require(unownedOutcome.message.contains("owns no wake"), "refusal names ownership")
        require(unowned.calls.isEmpty, "an unowned cancel runs no command")

        // Owned but already absent: satisfied, claim removed, no cancel argv.
        let entry = WakeEntry(id: UUID(), at: target, kind: .wake, createdBy: "sleepUntilReset")
        try store.save(entry, now: Date(timeIntervalSince1970: now))

        let absent = FakePmset { call in
            require(call.arguments == ["-g", "sched"], "already-absent path only lists")
            return commandOK("Scheduled power events:\n")
        }
        let absentScheduler = WakeScheduler(store: store, now: { now }, run: absent.runner)
        let absentOutcome = absentScheduler.cancel(dateValue: target)
        require(absentOutcome.ok, "an already-absent owned event is satisfied")
        require(absent.arguments == [["-g", "sched"]], "no cancellation is attempted when absent")
        let afterAbsent = try store.load()
        require(afterAbsent.isEmpty, "the ownership record is removed after satisfaction")

        // Owned and present: exact fixed argv, re-verified, then removed.
        try store.save(entry, now: Date(timeIntervalSince1970: now))
        var present = true
        let live = FakePmset { call in
            switch call.arguments {
            case ["-g", "sched"]:
                return commandOK(present ? schedLine("wake", text) + "\n" : "")
            case ["schedule", "cancel", "wake", text]:
                present = false
                return commandOK()
            default:
                fatalError("unexpected argv in cancel test: \(call.arguments)")
            }
        }
        let liveScheduler = WakeScheduler(store: store, now: { now }, run: live.runner)
        require(liveScheduler.owns(at: target), "the ownership probe sees the owned instant")
        require(!liveScheduler.owns(at: target + 5), "the ownership probe is exact to one second")
        let liveOutcome = liveScheduler.cancel(dateValue: target + 0.5)
        require(liveOutcome.ok, "an owned, present event is canceled")
        require(live.arguments == [
            ["-g", "sched"],
            ["schedule", "cancel", "wake", text],
            ["-g", "sched"],
        ], "cancel uses the fixed subcommand and the exact owned date")
        let afterLive = try store.load()
        require(afterLive.isEmpty, "the claim is removed only after verified cancellation")

        // Cancel failure: the claim is retained.
        try store.save(entry, now: Date(timeIntervalSince1970: now))
        let failing = FakePmset { call in
            call.arguments == ["-g", "sched"]
                ? commandOK(schedLine("wake", text) + "\n")
                : commandFailure("Operation not permitted")
        }
        let failingScheduler = WakeScheduler(store: store, now: { now }, run: failing.runner)
        let failedCancel = failingScheduler.cancel(dateValue: target)
        require(!failedCancel.ok, "a failed pmset cancel is a failure")
        require(failedCancel.message.contains("retained"), "failure says the claim is retained")
        let afterFailure = try store.load()
        require(afterFailure == [entry], "a failed cancel keeps the ownership record")

        // Cancel "success" without the event disappearing is not success.
        let lying = FakePmset { call in
            call.arguments == ["-g", "sched"]
                ? commandOK(schedLine("wake", text) + "\n")
                : commandOK()
        }
        let lyingScheduler = WakeScheduler(store: store, now: { now }, run: lying.runner)
        let stillThere = lyingScheduler.cancel(dateValue: target)
        require(!stillThere.ok, "unverified cancellation is never reported as success")
        require(stillThere.message.contains("still listed"), "the unverified state is named")
        let afterLying = try store.load()
        require(afterLying == [entry], "the claim survives an unverified cancellation")

        // The one-second tolerance is a match, two seconds is not.
        let tolerance = FakePmset { _ in commandOK("") }
        let toleranceScheduler = WakeScheduler(store: store, now: { now }, run: tolerance.runner)
        require(!toleranceScheduler.cancel(dateValue: target + 2).ok,
                "a date two seconds away is not the owned event")
        require(tolerance.calls.isEmpty, "a non-matching date runs no command")
    }

    // MARK: - Schedule outcomes

    static func schedulingOutcomes() throws {
        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }

        let store = WakeStore(directoryPath: directory)
        let now = 1_800_000_000.0
        let target = now + 3_600
        let text = PmsetSchedule.format(target)

        // Invalid bounds are rejected before the store and before any command.
        let rejected = FakePmset { _ in
            fatalError("an invalid date must not run pmset")
        }
        let rejectedScheduler = WakeScheduler(store: store, now: { now }, run: rejected.runner)
        let badDate = rejectedScheduler.schedule(dateValue: now + 5, createdBy: "sleepUntilReset")
        require(!badDate.ok, "a too-soon date is refused")
        require(rejected.calls.isEmpty, "no command runs for an invalid date")
        let afterRejection = try store.load()
        require(afterRejection.isEmpty, "no claim is written for an invalid date")

        // A store that cannot be written fails closed before pmset runs.
        let blocker = directory + "/blocked"
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: blocker))
        let brokenStore = WakeStore(directoryPath: blocker)
        let storeFailure = FakePmset { _ in
            fatalError("a store failure must not run pmset")
        }
        let brokenScheduler = WakeScheduler(store: brokenStore, now: { now }, run: storeFailure.runner)
        let unwritable = brokenScheduler.schedule(dateValue: target, createdBy: "sleepUntilReset")
        require(!unwritable.ok, "an unsavable ownership record refuses the schedule")
        require(unwritable.message.contains("without recording"), "the refusal explains ownership")
        require(storeFailure.calls.isEmpty, "the store failure happens before any command")
        require(brokenScheduler.owns(at: target),
                "an unreadable ownership record is never reported as nothing-owned")

        // pmset refuses: the just-written claim is removed and failure reported.
        let refused = FakePmset { call in
            require(call.arguments == ["schedule", "wake", text], "the exact create argv")
            return commandFailure("not permitted")
        }
        let refusedScheduler = WakeScheduler(store: store, now: { now }, run: refused.runner)
        let commandFailed = refusedScheduler.schedule(dateValue: target, createdBy: "sleepUntilReset")
        require(!commandFailed.ok, "a refused schedule is a failure")
        require(commandFailed.message.contains("not permitted"), "the pmset error is visible")
        require(commandFailed.message.contains("removed"), "the discarded claim is reported")
        let afterRefusal = try store.load()
        require(afterRefusal.isEmpty, "a failed schedule leaves no ownership claim")

        // pmset says success but the event is not in `-g sched`: not success.
        let unverified = FakePmset { call in
            call.arguments == ["schedule", "wake", text]
                ? commandOK()
                : commandOK("Scheduled power events:\n")
        }
        let unverifiedScheduler = WakeScheduler(store: store, now: { now }, run: unverified.runner)
        let verifyFailed = unverifiedScheduler.schedule(dateValue: target, createdBy: "sleepUntilReset")
        require(!verifyFailed.ok, "an unverified schedule is never a success")
        require(verifyFailed.message.contains("not verified"), "the unverified state is named")
        let afterVerify = try store.load()
        require(afterVerify.isEmpty, "an unverified schedule leaves no ownership claim")

        // Success: claim persisted first, exact argv, verified present.
        var scheduled = false
        let good = FakePmset { call in
            switch call.arguments {
            case ["schedule", "wake", text]:
                // The ownership record must exist before the event is created.
                let claims = (try? store.load()) ?? []
                require(claims.count == 1, "the claim is persisted before pmset runs")
                require(claims[0].at == target, "the claim names the requested instant")
                scheduled = true
                return commandOK()
            case ["-g", "sched"]:
                return commandOK(scheduled ? schedLine("wake", text, owner: "dev.wakely.helper") + "\n" : "")
            default:
                fatalError("unexpected argv in schedule test: \(call.arguments)")
            }
        }
        let goodScheduler = WakeScheduler(store: store, now: { now }, run: good.runner)
        let success = goodScheduler.schedule(dateValue: target, createdBy: "sleepUntilReset")
        require(success.ok, "a created and verified wake succeeds")
        require(success.details["at"] == text, "the reply reports the scheduled text")
        require(success.details["kind"] == "wake", "the reply reports the kind")
        require(good.arguments == [["schedule", "wake", text], ["-g", "sched"]],
                "success runs only the fixed create and list argv")

        let owned = try store.load()
        require(owned.count == 1, "one owned wake is recorded")
        require(owned[0].at == target, "the record stores the absolute instant")
        require(owned[0].kind == .wake, "the record stores the closed kind")
        require(owned[0].createdBy == "sleepUntilReset", "the record names its creator")

        // Same root-only posture as BackupStore.
        let fileMode = (try FileManager.default.attributesOfItem(atPath: store.filePath)[.posixPermissions]
            as? NSNumber)?.intValue
        require(fileMode == 0o600, "the wake record is 0600")
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions]
            as? NSNumber)?.intValue
        require(directoryMode == 0o700, "the wake record directory is 0700")

        // Listing is read-only and reports presence from the parsed output.
        let listing = goodScheduler.list()
        require(listing.ok, "listing succeeds with a readable schedule")
        let key = "wake.\(owned[0].id.uuidString)"
        require(listing.details["\(key).present"] == "yes", "a present owned wake reports yes")
        require(listing.details["\(key).kind"] == "wake", "listing carries the kind")
        let afterList = try store.load()
        require(afterList == owned, "wakeSchedules never mutates the ownership record")

        // An unreadable schedule is reported as unknown, never as absent.
        let blind = FakePmset { _ in commandFailure("pmset unavailable") }
        let blindScheduler = WakeScheduler(store: store, now: { now }, run: blind.runner)
        let blindListing = blindScheduler.list()
        require(!blindListing.ok, "an unreadable schedule is not a successful listing")
        require(blindListing.details["\(key).present"] == "unknown",
                "unknown presence is not guessed as no")
        let afterBlind = try store.load()
        require(afterBlind == owned, "a failed listing does not mutate the ownership record")
    }

    // MARK: - Retention

    static func retention() throws {
        let now = 1_800_000_000.0
        let future = WakeEntry(id: UUID(), at: now + 3_600, kind: .wake,
                               createdBy: "sleepUntilReset")
        let recentPast = WakeEntry(id: UUID(), at: now - 3_600, kind: .wake,
                                   createdBy: "sleepUntilReset")
        let stalePast = WakeEntry(id: UUID(), at: now - 8 * 86_400, kind: .wake,
                                  createdBy: "sleepUntilReset")

        require(WakeStore.retained([future, recentPast, stalePast], now: now) == [future, recentPast],
                "future and recent-past entries are retained; only week-old events expire")
        require(WakeStore.retained([future], now: .nan) == [future],
                "an unusable clock never prunes")

        let directory = try makeTemporaryDirectory()
        defer { removeDirectory(directory) }
        let store = WakeStore(directoryPath: directory)

        // A stale entry written directly is pruned by the next save, which is
        // the only mutating retention point.
        try store.save(stalePast, now: Date(timeIntervalSince1970: now))
        try store.save(future, now: Date(timeIntervalSince1970: now))
        let stored = try store.load()
        require(stored == [future], "the next write prunes only the expired event")

        let pruned = try store.prune(now: Date(timeIntervalSince1970: now))
        require(pruned == 0, "pruning an already-bounded record removes nothing")
        let afterPrune = try store.load()
        require(afterPrune == [future], "a future event survives retention")

        // A symlinked record is never read: it could redirect root writes.
        let symlinkDirectory = try makeTemporaryDirectory()
        defer { removeDirectory(symlinkDirectory) }
        let symlinkStore = WakeStore(directoryPath: symlinkDirectory)
        let linkedTarget = symlinkDirectory + "/elsewhere.json"
        try Data("[]".utf8).write(to: URL(fileURLWithPath: linkedTarget))
        try FileManager.default.createSymbolicLink(
            atPath: symlinkStore.filePath,
            withDestinationPath: linkedTarget
        )
        do {
            _ = try symlinkStore.load()
            fatalError("a symlinked wake record must not be read")
        } catch {
            require(error.localizedDescription.contains("not a regular file"),
                    "the symlink refusal names the reason")
        }
    }

    // MARK: - Protocol

    static func protocolRoundTrip() {
        let at = 1_800_000_000.5
        let request = HelperRequest(operation: .scheduleWake, componentID: "sleepUntilReset",
                                    dateValue: at)
        guard let decoded = HelperCoding.decode(
            HelperRequest.self, from: HelperCoding.encode(request)
        ) else {
            fatalError("a wake request did not round-trip")
        }
        require(decoded.operation == .scheduleWake, "operation round-trips")
        require(decoded.dateValue == at, "dateValue round-trips as epoch seconds")
        require(decoded.componentID == "sleepUntilReset", "componentID round-trips")
        require(HelperService.protocolVersion == "5", "protocol 5 advertises wake-source suppression alongside owned wakes")
        require(HelperOperation(rawValue: "wakeSchedules") == .wakeSchedules,
                "wakeSchedules is a wire operation")
        require(HelperOperation(rawValue: "cancelWake") == .cancelWake,
                "cancelWake is a wire operation")
        require(HelperRestoreScope.scope(for: .scheduleWake) == nil,
                "wake scheduling owns no BackupStore lease scope")

        let legacy = Data("""
        {"id":"\(UUID().uuidString)","operation":"cancelWake","componentID":"sleepUntilReset"}
        """.utf8)
        guard let old = HelperCoding.decode(HelperRequest.self, from: legacy) else {
            fatalError("old request JSON without dateValue no longer decodes")
        }
        require(old.dateValue == nil, "a missing dateValue decodes as nil")
        require(old.protocolVersion == nil, "a missing protocolVersion still decodes as nil")
    }
}
