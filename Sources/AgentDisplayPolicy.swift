// AgentDisplayPolicy — pure, injectable display eligibility.
//
// Evidence status: the earlier implementation has `AgentThread.needsDisplay(now:within:
// kinds:)` and `DisplayToolKind`. Decompilation confirms the shape (only a
// non-stopped activity, a tool-kind membership test, and an active call or a
// completion inside a configured interval) but not the five raw
// kind values, its default selected set, or its default interval. The values
// below are explicit OSS policy, not historical defaults.
//
// OSS policy: a display is held only for an explicitly working thread whose
// last tool call is screen or browser work, and only while that call is active
// or completed within `defaultGrace` (120s). Terminal/other tool calls never
// qualify. This file is pure: callers inject `now`, `grace`, and the selected
// kinds so the policy can be tested without processes, I/O, or AppKit.

import Foundation

/// OSS classification of a tool call in terms of what it needs from the
/// display. The earlier implementation exposes a five-value `DisplayToolKind`; this
/// OSS model deliberately collapses it to three buckets so that terminal-only
/// tool calls never hold the screen. The selected default set is OSS policy,
/// not a historical default.
enum DisplayToolKind: String, CaseIterable, Equatable, Sendable {
    case screen, browser, other
}

extension AgentDisplayActivity {
    /// Classification is derived from the raw tool name, so the transcript
    /// model stays policy-free and the classifier has exactly one home.
    var kind: DisplayToolKind { AgentDisplayTools.kind(of: tool) }
}

/// Name-based classifier for tool calls.
///
/// A tool name is untrusted transcript metadata. Classification only
/// lowercases it and tests substrings; the name itself is never logged or
/// displayed. Unknown names stay `.other`.
enum AgentDisplayTools {
    private static let screenTokens = ["computer", "screenshot", "screencapture", "screen_capture", "desktop"]
    private static let browserTokens = ["browser", "chrome", "safari", "playwright", "puppeteer"]

    static func kind(of tool: String) -> DisplayToolKind {
        let name = tool.lowercased()
        if screenTokens.contains(where: name.contains) { return .screen }
        if browserTokens.contains(where: name.contains) { return .browser }
        return .other
    }
}

/// Pure decision used by both the Agent Screen display assertion and the
/// armed-close display-sleep path.
enum AgentDisplayPolicy {
    /// OSS policy, not a historical default.
    static let defaultSelectedKinds: Set<DisplayToolKind> = [.screen, .browser]

    /// OSS policy. No configured interval is documented;
    /// 120s matches the existing Agent Screen release hysteresis.
    static let defaultGrace: TimeInterval = 120

    /// Small future timestamps are treated as clock skew rather than as a
    /// call that should pin the display indefinitely.
    static let maximumClockSkew: TimeInterval = 60

    static func threadNeedsDisplay(_ thread: AgentThread,
                                   selectedKinds: Set<DisplayToolKind> = defaultSelectedKinds,
                                   now: Date,
                                   grace: TimeInterval = defaultGrace) -> Bool {
        // Process-only agents expose no task state, so their running process
        // is the only signal: keep the screen usable while one is running.
        if Set(AgentProcessDescriptor.processOnlyProviders.values).contains(thread.provider) { return true }
        // `waiting` and `unknown` are deliberately not display-using work.
        guard thread.state == .working,
              let activity = thread.activity,
              selectedKinds.contains(activity.kind) else { return false }
        if activity.isActive {
            // A timestamp far in the future is malformed metadata, not a call
            // that should pin the display forever.
            return activity.startedAt.timeIntervalSince(now) < maximumClockSkew
        }
        guard let ended = activity.endedAt else { return false }
        let age = now.timeIntervalSince(ended)
        return age < grace && age > -maximumClockSkew
    }

    /// Diagnostics helper: the threads that would justify holding the display.
    /// Preserves input order and never duplicates a thread.
    static func displayEligibleThreads(threads: [AgentThread],
                                       selectedKinds: Set<DisplayToolKind> = defaultSelectedKinds,
                                       now: Date,
                                       grace: TimeInterval = defaultGrace) -> [AgentThread] {
        threads.filter {
            threadNeedsDisplay($0, selectedKinds: selectedKinds, now: now, grace: grace)
        }
    }

    static func shouldHoldDisplay(threads: [AgentThread],
                                  selectedKinds: Set<DisplayToolKind> = defaultSelectedKinds,
                                  now: Date,
                                  grace: TimeInterval = defaultGrace) -> Bool {
        threads.contains {
            threadNeedsDisplay($0, selectedKinds: selectedKinds, now: now, grace: grace)
        }
    }
}

@MainActor
extension AgentMonitor {
    /// The shared decision for Agent Screen and armed-close display sleep.
    func needsDisplay(now: Date = Date(),
                      grace: TimeInterval = AgentDisplayPolicy.defaultGrace,
                      selectedKinds: Set<DisplayToolKind> = AgentDisplayPolicy.defaultSelectedKinds) -> Bool {
        AgentDisplayPolicy.shouldHoldDisplay(threads: threads,
                                             selectedKinds: selectedKinds,
                                             now: now,
                                             grace: grace)
    }

    /// Diagnostics seam: which threads currently justify a display.
    func displayEligibleThreads(now: Date = Date(),
                                grace: TimeInterval = AgentDisplayPolicy.defaultGrace,
                                selectedKinds: Set<DisplayToolKind> = AgentDisplayPolicy.defaultSelectedKinds) -> [AgentThread] {
        AgentDisplayPolicy.displayEligibleThreads(threads: threads,
                                                  selectedKinds: selectedKinds,
                                                  now: now,
                                                  grace: grace)
    }
}
