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
        /// Runs in Anthropic's cloud. Local sessions already have a registry
        /// record and a process, so only cloud rows are added from here.
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
        guard let title = texts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let states = texts.dropFirst().compactMap(state(status:))
        guard let state = states.contains(.waiting) ? .waiting : states.first else { return nil }
        return Row(title: title, state: state, cloud: texts.dropFirst().contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "cloud" })
    }

    static func threads(_ rows: [Row], pid: Int32, excluding names: Set<String>) -> [AgentThread] {
        var seen = Set<String>()
        return rows.compactMap { row in
            guard row.cloud, !names.contains(row.title), seen.insert(row.title).inserted else { return nil }
            var thread = AgentThread(id: "claude-desktop-\(row.title)", provider: "Claude", pid: pid,
                                     state: row.state, displayName: row.title)
            thread.isApp = true
            return thread
        }
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
        // status plus the "Cloud" label makes a row count.
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
