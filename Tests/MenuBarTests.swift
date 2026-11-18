import AppKit

// Headless menu-construction check. Builds the status menu against a stub
// delegate (the real app's delegate implements the same selectors), installs no
// status item, and changes no power state.
final class MenuStubDelegate: NSObject, NSApplicationDelegate {
    @objc func armFromMenu() {}
    @objc func disarmFromMenu() {}
    @objc func openSettings() {}
    @objc func showAbout() {}
    @objc func quit() {}
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let stub = MenuStubDelegate()
    app.delegate = stub
    let controller = MenuBarController()
    controller.rebuild()
    guard let menu = controller.debugMenu else { print("FAIL: no menu built"); exit(1) }
    let titles = menu.items.map { item -> String in
        if item.isSeparatorItem { return "--" }
        let sub = item.submenu.map { " > [" + $0.items.map(\.title).joined(separator: ", ") + "]" } ?? ""
        return item.title + sub
    }
    for title in titles { print("  \(title)") }
    let flat = titles.joined(separator: "|")
    for needle in ["Arm Wakely", "Settings…", "About Wakely", "Quit Wakely"] where !flat.contains(needle) {
        print("MISSING: \(needle)"); exit(1)
    }
    // Every row with an action must actually reach someone; a nil target with no
    // submenu is a dead click in the real menu.
    for item in menu.items where !item.isSeparatorItem {
        if item.submenu == nil, item.action != nil, item.target == nil {
            print("DEAD ACTION: \(item.title)"); exit(1)
        }
        if let submenu = item.submenu {
            for child in submenu.items where child.action != nil && child.target == nil {
                print("DEAD SUBMENU ACTION: \(child.title)"); exit(1)
            }
        }
    }
    // Agent rows prefer the per-session display name and fall back to the
    // provider; they never contain transcript text.
    let namedThread = AgentThread(id: "named", provider: "Claude Code", pid: 1,
                                  state: .working, displayName: "Fix login")
    guard MenuBarController.agentRowTitle(for: namedThread) == "Fix login — working" else {
        print("WRONG LABEL: \(MenuBarController.agentRowTitle(for: namedThread))"); exit(1)
    }
    let fallbackThread = AgentThread(id: "fallback", provider: "Codex", pid: 2, state: .waiting)
    guard MenuBarController.agentRowTitle(for: fallbackThread) == "Codex — waiting" else {
        print("WRONG FALLBACK: \(MenuBarController.agentRowTitle(for: fallbackThread))"); exit(1)
    }
    let blankThread = AgentThread(id: "blank", provider: "Claude Code", pid: 3,
                                  state: .unknown, displayName: "   ")
    guard MenuBarController.agentRowTitle(for: blankThread) == "Claude Code — unknown" else {
        print("WRONG BLANK FALLBACK: \(MenuBarController.agentRowTitle(for: blankThread))"); exit(1)
    }
    print("PASS: status menu builds with \(menu.items.count) rows")
    exit(0)
}
