// Claude desktop's Code tab lists its sessions in the sidebar with a status
// line ("Running", "Awaiting input"). Cloud sessions keep no local process,
// registry record, or transcript, so the sidebar, read through Accessibility,
// is their only local signal. Titles are only shown in the menu; nothing
// read here is logged.
import AppKit
import ApplicationServices

enum ClaudeDesktopSidebar {
    struct Row: Equatable, Sendable {
        let title: String
        let state: AgentTaskState
        /// Runs in Anthropic's cloud rather than on this Mac.
        var cloud = false
    }

    /// Sidebar status lines. Anything else (no status, "Cloud", a time) is not
    /// evidence of work and is ignored.
    static func state(status: String) -> AgentTaskState? {
        switch status.trimmingCharacters(in: .whitespaces).lowercased() {
        case "running", "thinking", "working": return .working
        case "awaiting input", "needs input", "needs approval", "asked a question", "waiting": return .waiting
        default: return nil
        }
    }

    /// A session button's text children: its title first, then status and
    /// location labels.
    static func row(texts: [String]) -> Row? {
        // The location label comes last on a sidebar row.
        let cloud = texts.count > 1 && texts.last?.trimmingCharacters(in: .whitespaces).lowercased() == "cloud"
        // The open session's banner ("Waiting", title, "Asked a question") leads
        // with a status and never says "Cloud"; it repeats a sidebar row, so it is skipped.
        guard let title = texts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              cloud || state(status: title) == nil else { return nil }
        let states = texts.dropFirst().compactMap(state(status:))
        guard let state = states.contains(.waiting) ? .waiting : states.first else { return nil }
        return Row(title: title, state: state, cloud: cloud)
    }

    /// Folds the sidebar into the registry-backed Claude rows. A local Code-tab
    /// session's registry status can read "idle" while it runs, so the sidebar's
    /// status wins for a matching title; every other session, cloud or local,
    /// gets its own app row.
    static func merge(_ rows: [Row], into threads: [AgentThread], pid: Int32) -> [AgentThread] {
        var merged = threads
        var matched = Set<Int>()
        var counts: [String: Int] = [:]
        for row in rows {
            if let index = merged.indices.first(where: {
                !matched.contains($0) && merged[$0].provider == "Claude" && merged[$0].displayName == row.title
            }) {
                matched.insert(index)
                merged[index].state = row.state
                continue
            }
            // Sessions can share a title; each keeps its own row.
            let count = counts[row.title, default: 0]
            counts[row.title] = count + 1
            var thread = AgentThread(id: "claude-desktop-\(row.title)" + (count == 0 ? "" : "-\(count)"), provider: "Claude",
                                     pid: pid, state: row.state, displayName: row.title)
            thread.isApp = true
            merged.append(thread)
            matched.insert(merged.count - 1)
        }
        return merged
    }

    /// Reads the sidebar of the Claude app at `pid`. Without Accessibility
    /// access, or with the sidebar hidden, this returns nothing.
    static func read(pid: Int32, nodeLimit: Int = 3000) -> [Row] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        // Chromium builds its web accessibility tree only once asked to.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        var visited = 0
        var rows: [Row] = []
        // The "Sidebar" landmark doesn't contain the session list in the
        // accessibility tree, so every button is checked; only a recognised
        // status after the title makes a row count.
        func find(_ element: AXUIElement, depth: Int) {
            visited += 1
            guard visited <= nodeLimit, depth < 64 else { return }
            if string(element, kAXRoleAttribute) == kAXButtonRole {
                if let row = row(texts: texts(in: element)) { rows.append(row) }
                return
            }
            for child in children(element) { find(child, depth: depth + 1) }
        }
        for window in (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            find(window, depth: 0)
        }
        return rows
    }

    private static func texts(in button: AXUIElement) -> [String] {
        var found: [String] = []
        func collect(_ element: AXUIElement, depth: Int) {
            guard depth < 6, found.count < 8 else { return }
            if string(element, kAXRoleAttribute) == kAXStaticTextRole, let text = string(element, kAXValueAttribute) {
                found.append(text)
            }
            for child in children(element) { collect(child, depth: depth + 1) }
        }
        for child in children(button) { collect(child, depth: 0) }
        return found
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var result: AnyObject?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
}
