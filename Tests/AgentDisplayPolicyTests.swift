// Pure policy tests. No processes, I/O, AppKit, or real transcripts.
// Compile with Sources/{AgentTaskState,AgentMonitor,AgentDisplayPolicy}.swift.
import Foundation

@MainActor
enum Diagnostics { static func log(_ message: String) {} }

@main
struct AgentDisplayPolicyTests {
    private static var checks = 0
    private static func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(name)") }
    }

    private static func thread(id: String = "same",
                               state: AgentTaskState,
                               tool: String? = nil,
                               startedAt: Date? = nil,
                               endedAt: Date? = nil) -> AgentThread {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let activity = tool.map {
            AgentDisplayActivity(tool: $0,
                                 startedAt: startedAt ?? (endedAt ?? now).addingTimeInterval(-30),
                                 endedAt: endedAt)
        }
        return AgentThread(id: id, provider: "Claude Code", pid: 1, state: state, activity: activity)
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        expect(AgentDisplayPolicy.defaultSelectedKinds == [.screen, .browser],
               "OSS default selected kinds are screen and browser")
        expect(AgentDisplayPolicy.defaultGrace == 120, "OSS default grace is 120s")

        // Classifier: names only, never transcript content.
        for name in ["mcp__computer__screenshot", "screencapture", "screen_capture",
                     "desktop_click", "Computer Use", "SCREENSHOT"] {
            expect(AgentDisplayTools.kind(of: name) == .screen, "screen classifier: \(name)")
        }
        for name in ["browser_navigate", "mcp__claude-in-chrome__click", "safari_open",
                     "playwright_click", "Puppeteer", "BROWSER"] {
            expect(AgentDisplayTools.kind(of: name) == .browser, "browser classifier: \(name)")
        }
        for name in ["Bash", "exec_command", "mcp_tool_call", "", "glob", "read_file"] {
            expect(AgentDisplayTools.kind(of: name) == .other, "other classifier: \(name)")
        }
        // Screen tokens win over browser tokens, matching the documented order.
        expect(AgentDisplayTools.kind(of: "chrome computer") == .screen, "screen precedence")

        // Active calls.
        let pi = AgentThread(id: "pi", provider: "Pi", pid: 9, state: .unknown)
        expect(AgentDisplayPolicy.threadNeedsDisplay(pi, now: now), "process-only agent holds the display while running")
        expect(!AgentDisplayPolicy.threadNeedsDisplay(AgentThread(id: "c", provider: "Claude Code", pid: 8, state: .unknown), now: now), "unknown Claude thread still does not hold the display")
        expect(AgentDisplayPolicy.threadNeedsDisplay(thread(state: .working, tool: "computer_click"),
                                                     now: now), "active screen call holds")
        expect(AgentDisplayPolicy.threadNeedsDisplay(thread(state: .working, tool: "browser_navigate"),
                                                     now: now), "active browser call holds")

        // Recent vs stale completions and the grace boundary.
        let recent = thread(state: .working, tool: "browser_navigate",
                            endedAt: now.addingTimeInterval(-10))
        expect(AgentDisplayPolicy.threadNeedsDisplay(recent, now: now), "recent completion holds")
        let justInside = thread(state: .working, tool: "browser_navigate",
                                endedAt: now.addingTimeInterval(-119))
        expect(AgentDisplayPolicy.threadNeedsDisplay(justInside, now: now), "completion inside grace holds")
        let exactBoundary = thread(state: .working, tool: "browser_navigate",
                                   endedAt: now.addingTimeInterval(-120))
        expect(!AgentDisplayPolicy.threadNeedsDisplay(exactBoundary, now: now), "grace boundary is exclusive")
        let stale = thread(state: .working, tool: "browser_navigate",
                           endedAt: now.addingTimeInterval(-300))
        expect(!AgentDisplayPolicy.threadNeedsDisplay(stale, now: now), "stale completion releases")
        expect(!AgentDisplayPolicy.threadNeedsDisplay(stale, now: now, grace: 60),
               "stale for a shorter grace too")

        // Non-working states never hold, even with an active screen call.
        expect(!AgentDisplayPolicy.threadNeedsDisplay(thread(state: .idle, tool: "computer_click"), now: now),
               "idle never holds")
        expect(!AgentDisplayPolicy.threadNeedsDisplay(thread(state: .waiting, tool: "computer_click"), now: now),
               "waiting never holds")
        expect(!AgentDisplayPolicy.threadNeedsDisplay(thread(state: .unknown, tool: "computer_click"), now: now),
               "unknown never holds")

        // Wrong or absent kind.
        expect(!AgentDisplayPolicy.threadNeedsDisplay(thread(state: .working, tool: "Bash"), now: now),
               "terminal-only work does not hold")
        expect(!AgentDisplayPolicy.threadNeedsDisplay(thread(state: .working), now: now),
               "nil activity does not hold")

        // Selected-set changes.
        expect(AgentDisplayPolicy.threadNeedsDisplay(thread(state: .working, tool: "Bash"), selectedKinds: [.other], now: now),
               "explicit other selection holds")
        expect(!AgentDisplayPolicy.threadNeedsDisplay(thread(state: .working, tool: "computer_click"), selectedKinds: [], now: now),
               "empty selection holds nothing")

        // Clock skew tolerance is bounded.
        let futureActive = thread(state: .working, tool: "computer_click",
                                  startedAt: now.addingTimeInterval(600))
        expect(!AgentDisplayPolicy.threadNeedsDisplay(futureActive, now: now),
               "far-future active call ignored")
        let slightlyFutureActive = thread(state: .working, tool: "computer_click",
                                          startedAt: now.addingTimeInterval(10))
        expect(AgentDisplayPolicy.threadNeedsDisplay(slightlyFutureActive, now: now),
               "small future active timestamp tolerated")
        let slightlyFuture = thread(state: .working, tool: "browser_navigate",
                                    endedAt: now.addingTimeInterval(10))
        expect(AgentDisplayPolicy.threadNeedsDisplay(slightlyFuture, now: now), "small future timestamp tolerated")
        let farFuture = thread(state: .working, tool: "browser_navigate",
                               endedAt: now.addingTimeInterval(120))
        expect(!AgentDisplayPolicy.threadNeedsDisplay(farFuture, now: now), "far-future timestamp does not pin")

        // Diagnostics list preserves order and filters exactly.
        let eligibleSource = [
            thread(id: "idle", state: .idle, tool: "computer_click"),
            thread(id: "other", state: .working, tool: "Bash"),
            thread(id: "active", state: .working, tool: "computer_click"),
            thread(id: "recent", state: .working, tool: "browser_navigate",
                   endedAt: now.addingTimeInterval(-5)),
            thread(id: "stale", state: .working, tool: "browser_navigate",
                   endedAt: now.addingTimeInterval(-600)),
        ]
        expect(AgentDisplayPolicy.displayEligibleThreads(threads: eligibleSource, now: now).map(\.id)
               == ["active", "recent"], "eligible threads filtered in order")
        expect(!AgentDisplayPolicy.shouldHoldDisplay(threads: eligibleSource.filter { $0.id == "stale" }, now: now),
               "single stale thread does not hold")
        expect(AgentDisplayPolicy.shouldHoldDisplay(threads: eligibleSource, now: now),
               "one eligible thread is enough")
        expect(!AgentDisplayPolicy.shouldHoldDisplay(threads: [], now: now), "no threads no hold")

        print("PASS: \(checks) pure display-policy checks")
    }
}
