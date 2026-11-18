import Foundation

// Compile only the loader, not the engine: no app launch or live preferences.
enum Diagnostics {
    static let supportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("unused-component-test-support")
    static func log(_ message: String) {}
}

@main struct ComponentStoreTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wakely-store-tests-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "wakely-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ComponentStore(supportDirectory: root, defaults: defaults)
        let folder = store.componentsDirectory.appendingPathComponent("test-component", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var json: [String: Any] = ["format": 1, "id": "test-component", "name": "Test Component", "tagline": "Notify when the Mac wakes.", "description": "Notifies you when the Mac wakes up.", "rules": [["on": "wake", "do": [["notify": "Awake now"]]]]]
        func save() throws { try JSONSerialization.data(withJSONObject: json).write(to: folder.appendingPathComponent("component.json")) }
        try save()
        store.reload()
        precondition(store.components.count == 1 && store.errors.isEmpty)
        precondition(store.components[0].descriptionText == json["description"] as? String, "plain descriptions must render")
        json["rules"] = [["on": "typo", "do": [["notify": "Awake now"]]]]
        try save()
        store.reload()
        precondition(store.components.count == 1 && store.errors["test-component"] != nil, "broken edit retains last valid component")
        precondition(store.components[0].rules[0]["on"] as? String == "wake", "do not run invalid edit")
        let status = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(".status.json"))) as! [String: Any]
        precondition(status["state"] as? String == "invalid", "status still reports broken edit")
        precondition(!store.importComponent(from: folder), "invalid self import must be rejected")
        json["rules"] = [["on": "wake", "do": [["notify": "Awake now"]]]]
        try save()
        precondition(store.importComponent(from: folder), "valid self import is non-destructive")
        let external = root.appendingPathComponent("incoming/test-component", isDirectory: true)
        try fm.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: folder, to: external)
        precondition(!store.importComponent(from: external), "collision cannot delete installed component")
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        for id in ["..", "../..", "../../sentinel", ".", "", "/"] { store.remove(id) }
        precondition(fm.fileExists(atPath: sentinel.path) && fm.fileExists(atPath: folder.path), "URL path traversal must be rejected")
        let link = store.componentsDirectory.appendingPathComponent("escape")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        store.remove("escape")
        precondition(fm.fileExists(atPath: sentinel.path), "symlink cannot escape component directory")
        store.remove("test-component")
        precondition(store.components.isEmpty && !fm.fileExists(atPath: folder.path))
        print("Component store: load, invalid edit retention, description, import, traversal, symlink and remove PASS")
    }
}
