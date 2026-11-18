"""Read-only structural regressions for the orderly-termination integration.

These checks do not launch the app or prove hardware/XPC restoration. Runtime
coverage still requires a mocked helper or an explicitly authorized live test.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ShutdownLifecycleTests(unittest.TestCase):
    def test_application_defers_exit_until_restore_drain(self):
        source = (ROOT / "Sources/AppDelegate.swift").read_text()
        body = source.split("func applicationShouldTerminate(", 1)[1].split("\n    func application(", 1)[0]
        self.assertIn("guard terminationTask == nil else { return .terminateLater }", body)
        self.assertNotIn("return .terminateNow", body)
        self.assertEqual(body.count("reply(toApplicationShouldTerminate: true)"), 1)
        self.assertLess(body.index("PowerEngine.shared.shutDown()"), body.index("await ComponentEngine.shared.awaitShutdownRestoration"))
        self.assertLess(body.index("await ComponentEngine.shared.awaitShutdownRestoration"), body.index("await PowerEngine.shared.awaitShutdownCleanup(timeout: 3)"))
        self.assertLess(body.index("await PowerEngine.shared.awaitShutdownCleanup(timeout: 3)"), body.index("reply(toApplicationShouldTerminate: true)"))

    def test_shutdown_freezes_new_helper_applies_and_drains_pending_work(self):
        source = (ROOT / "Sources/ComponentBehaviors.swift").read_text()
        stop = source.split("    func stop() {", 1)[1].split("    private func teardown", 1)[0]
        self.assertLess(stop.index("ProtectedComponents.shared.beginShutdown()"), stop.index("ProtectedComponents.shared.restoreSessionScoped"))
        apply = source.split("    private func apply(steps:", 1)[1].split("    private func perform(", 1)[0]
        self.assertIn("guard !shuttingDown else { return }", apply)
        # Capture before the Task can queue or suspend, then recheck the complete
        # lifetime after reachability and again after the write. A pre-await
        # shutdown check alone cannot prevent a late mutation after quit/open.
        self.assertLess(apply.index("let generation = sessionGeneration"),
                        apply.index("let task = Task"))
        preflight = apply.split("guard ProtectedApplyLifetime.wanted(", 1)[1].split(
            "let receipt = await self.perform(step)", 1)[0]
        self.assertLess(apply.index("await HelperClient.shared.isReachable()"),
                        apply.index("guard ProtectedApplyLifetime.wanted("))
        postflight = apply.split("let stillWanted = ProtectedApplyLifetime.wanted(", 1)[1].split(
            "guard stillWanted else", 1)[0]
        for lifetime in (preflight, postflight):
            for argument in ("enabled: ComponentEngine.shared.isEnabled(id)",
                             "persistent: persistent", "shuttingDown: self.shuttingDown",
                             "armed: PowerEngine.shared.isArmed", "lidClosed: PowerEngine.shared.lidClosed",
                             "requestedEpoch: generation", "currentEpoch: self.sessionGeneration"):
                self.assertIn(argument, lifetime)
        self.assertLess(apply.index("let receipt = await self.perform(step)"),
                        apply.index("let stillWanted = ProtectedApplyLifetime.wanted("))
        self.assertIn("let rollback = await self.api.restore(component: id)", apply)
        self.assertIn("if rollback.reply.ok { self.applied.remove(id) }", apply)
        drain = source.split("    func awaitShutdownRestoration(timeout:", 2)[2].split("    private var retryAfter", 1)[0]
        self.assertIn("applying.isEmpty && probeTask == nil", drain)
        self.assertIn("restoring.isEmpty", drain)
        self.assertIn("ProcessInfo.processInfo.systemUptime < deadline", drain)
        self.assertIn("restorePlan(applied: applied, limit: .session).isEmpty", drain)
        # The final session sweep is one authoritative restoreSession request,
        # not per-component restoreComponent calls, and is not awaited past the deadline.
        self.assertIn("scheduleFinalSessionRestore()", drain)
        self.assertIn("api.restoreSession()", drain)
        self.assertNotIn('restoreSessionScoped(reason: "termination drain")', drain)
        self.assertIn("finalRestoreTask == nil", drain)

    def test_fan_requests_are_tracked_and_late_replies_are_generation_guarded(self):
        source = (ROOT / "Sources/ComponentBehaviors.swift").read_text()

        # Every fan mutation registers its UUID before it can suspend.
        tracked = source.split("    private func setFanPercentTracked(", 1)[1].split(
            "    // MARK: Fan governor", 1)[0]
        self.assertIn("fanInFlight[requestID] = sessionGeneration", tracked)
        self.assertLess(
            tracked.index("fanInFlight[requestID] = sessionGeneration"),
            tracked.index("await api.setFanPercent"),
            "the in-flight UUID must be visible before the XPC call suspends",
        )
        self.assertIn('receipt.reply.details["transportUncertain"]', tracked)

        # The initial apply goes through the tracked path, not a bare setFanPercent.
        perform = source.split("    private func perform(_ step:", 1)[1].split(
            "    /// Registers the fan request UUID", 1)[0]
        self.assertIn("setFanPercentTracked(ProtectedComponentPolicy.fanPercent(from: raw))", perform)
        self.assertNotIn("api.setFanPercent(ProtectedComponentPolicy.fanPercent(from: raw))", perform)

        # The governor uses the same path for force and automatic control.
        governor = source.split("    private func startFanGovernorIfNeeded(", 1)[1].split(
            "    private func stopFanGovernor", 1)[0]
        self.assertGreaterEqual(governor.count("setFanPercentTracked("), 2)
        self.assertGreaterEqual(governor.count("let generation = self.sessionGeneration"), 2)
        self.assertGreaterEqual(governor.count("guard generation == self.sessionGeneration"), 2)
        self.assertIn("!self.shuttingDown", governor)

        # The initial apply reply is generation-guarded too.
        apply = source.split("    private func apply(steps:", 1)[1].split("    private func perform(", 1)[0]
        self.assertIn("let generation = sessionGeneration", apply)
        self.assertLess(apply.index("let generation = sessionGeneration"),
                        apply.index("let task = Task"))
        self.assertLess(apply.index("let generation = sessionGeneration"),
                        apply.index("await prior?.value"))
        self.assertIn("generation == self.sessionGeneration", apply)
        self.assertIn("fanForcedAfterInitialApply", apply)

        # Cancelling the governor loop must not forget already-issued writes.
        stop_governor = source.split("    private func stopFanGovernor()", 1)[1].split(
            "    // MARK: Restoration", 1)[0]
        self.assertNotIn("fanInFlight.remove", stop_governor)
        self.assertNotIn("fanInFlight =", stop_governor)

        # Restores/shutdown invalidate replies; periodic session retries must not
        # invalidate one another. Bootstrap still needs a post-await epoch/lid gate.
        begin = source.split("    func beginShutdown() {", 1)[1].split("\n    }", 1)[0]
        self.assertIn("sessionGeneration += 1", begin)
        session = source.split("    func sessionDidStart() {", 2)[2].split("\n    }", 1)[0]
        self.assertNotIn("sessionGeneration += 1", session)
        self.assertLess(session.index("let generation = sessionGeneration"),
                        session.index("Task {"))
        self.assertLess(session.index("await self.bootstrap()"),
                        session.index("guard generation == self.sessionGeneration"))
        self.assertIn("PowerEngine.shared.isArmed, PowerEngine.shared.lidClosed else { return }", session)
        self.assertLess(session.index("guard generation == self.sessionGeneration"),
                        session.index("self.apply(steps: steps)"))
        restore = source.split("    private func restore(ids:", 1)[1].split("\n    }", 1)[0]
        self.assertIn("sessionGeneration += 1", restore)

    def test_shutdown_drain_counts_unresolved_fan_requests(self):
        source = (ROOT / "Sources/ComponentBehaviors.swift").read_text()
        drain = source.split("    func awaitShutdownRestoration(timeout:", 2)[2].split(
            "    private var retryAfter", 1)[0]
        self.assertIn("finalRestoreTask == nil, restoring.isEmpty, fanInFlight.isEmpty", drain)
        self.assertIn("pendingReconciliation.keys.contains", drain)
        self.assertIn("ProtectedComponentPolicy.scope(of: $0) == .session", drain)

    def test_ordinary_quit_never_restores_persistent_leases(self):
        source = (ROOT / "Sources/ComponentBehaviors.swift").read_text()
        stop = source.split("    func stop() {", 1)[1].split("    private func teardown", 1)[0]
        self.assertIn('restoreSessionScoped(reason: "app quit")', stop)
        self.assertNotIn("restoreAll", stop)
        helper_uninstall = source.split("    func helperWillUninstall()", 1)[1].split(
            "\n    }", 1)[0]
        self.assertIn("restoreAll", helper_uninstall)

        app = (ROOT / "Sources/AppDelegate.swift").read_text()
        termination = app.split("func applicationShouldTerminate(", 1)[1].split(
            "\n    func application(", 1)[0]
        self.assertNotIn("restoreAll", termination)

    def test_display_sleep_does_not_block_main_actor(self):
        source = (ROOT / "Sources/PowerEngine.swift").read_text()
        body = source.split("    private func sleepDisplaysUnlessAgentsNeedThem()", 1)[1].split("    private func beginClosedSession()", 1)[0]
        self.assertNotIn("waitUntilExit", body)
        self.assertIn("DispatchQueue.global(qos: .utility).async", body)
        self.assertIn("process.terminationHandler", body)
        self.assertIn("process.terminate()", body)


if __name__ == "__main__":
    unittest.main()
