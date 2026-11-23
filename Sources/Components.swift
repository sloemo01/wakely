// Components — the on-disk home of custom components: a component is two files,
// component.json and icon.txt, in ~/Library/Application Support/Wakely/Components/components/<id>/
// (that folder keeps its old name for compatibility; the UI calls it Components).
//
// The schema, the vocabulary and the semantics follow the shipped SDK reference
// (harvest/components-kit/sdk/reference.md) one for one.

import Foundation
import AppKit

struct ComponentSpec: Identifiable {
    let id: String
    let name: String
    let tagline: String
    let keywords: [String]
    let descriptionText: String
    let values: [String: [String: Any]]
    let rules: [[String: Any]]
    let directory: URL
    let iconLines: [String]

    @MainActor var displayDescription: String {
        var text = descriptionText
        for (key, spec) in values {
            text = text.replacingOccurrences(of: "{\(key)}", with: ComponentSpec.renderValue(componentID: id, key: key, spec: spec))
        }
        return text
    }

    @MainActor static func renderValue(componentID: String, key: String, spec: [String: Any]) -> String {
        let kind = spec["kind"] as? String ?? "number"
        let raw = ComponentStore.shared.storedValue(componentID: componentID, key: key) ?? spec["default"]
        switch kind {
        case "duration", "minutes":
            let minutes = (raw as? NSNumber)?.intValue ?? 0
            if minutes >= 60 {
                let hours = minutes / 60
                let rest = minutes % 60
                return rest == 0 ? "\(hours) hours" : "\(hours) h \(rest) min"
            }
            return "\(minutes) minutes"
        case "percent":
            return "\((raw as? NSNumber)?.intValue ?? 0)%"
        case "choice":
            if let index = (raw as? NSNumber)?.intValue, let options = spec["options"] as? [String], options.indices.contains(index) {
                return options[index]
            }
            return raw as? String ?? ""
        case "apps":
            guard let ids = raw as? [String], !ids.isEmpty else { return "+ add app" }
            return ids.map { ComponentSpec.appName(for: $0) }.joined(separator: " or ")
        default:
            let number = (raw as? NSNumber)?.intValue ?? 0
            let unit = spec["unit"] as? String ?? ""
            return unit.isEmpty ? "\(number)" : "\(number) \(unit)"
        }
    }

    static func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

@MainActor
final class ComponentStore: ObservableObject {
    static let shared = ComponentStore()

    @Published private(set) var components: [ComponentSpec] = []
    @Published private(set) var errors: [String: [String]] = [:]
    @Published private(set) var customComponentsEnabled = true

    private var watchTimer: Timer?
    private var fingerprint = ""
    private let supportDirectory: URL
    private let defaults: UserDefaults

    /// The default resolves through Diagnostics.supportDirectory, which is
    /// SupportPaths.baseDirectory: the directory rename and its one-time
    /// migration live in one place. The subfolders below keep their old names
    /// so components and kits already on disk keep working.
    init(supportDirectory: URL = Diagnostics.supportDirectory, defaults: UserDefaults = .standard) {
        self.supportDirectory = supportDirectory
        self.defaults = defaults
        LegacyVocabulary.migrateStorage(in: supportDirectory)
    }

    var componentsFolder: URL { supportDirectory.appendingPathComponent("Components", isDirectory: true) }

    private var enabledIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "enabledComponents") ?? []) }
        set { defaults.set(Array(newValue), forKey: "enabledComponents") }
    }

    var componentsDirectory: URL {
        let dir = supportDirectory.appendingPathComponent("Components/components", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Values

    private var valuesKey = "componentValues"

    func storedValue(componentID: String, key: String) -> Any? {
        let all = defaults.dictionary(forKey: valuesKey) ?? [:]
        guard let perComponent = all[componentID] as? [String: Any] else { return nil }
        return perComponent[key]
    }

    func setValue(componentID: String, key: String, value: Any) {
        var all = defaults.dictionary(forKey: valuesKey) ?? [:]
        var perComponent = all[componentID] as? [String: Any] ?? [:]
        perComponent[key] = value
        all[componentID] = perComponent
        defaults.set(all, forKey: valuesKey)
        objectWillChange.send()
    }

    // MARK: - Enablement

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        var ids = enabledIDs
        if on { ids.insert(id) } else { ids.remove(id) }
        enabledIDs = ids
        NotificationCenter.default.post(name: .componentEnablementChanged, object: id)
        objectWillChange.send()
    }

    // MARK: - Watching

    /// The app writes .status.json within a second of every change and picks the
    /// component up again without a restart. Same here: a one-second fingerprint check.
    func startWatching() {
        watchTimer?.invalidate()
        fingerprint = folderFingerprint()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = self.folderFingerprint()
                if current != self.fingerprint {
                    self.fingerprint = current
                    self.reload()
                }
            }
        }
    }

    private func folderFingerprint() -> String {
        let fm = FileManager.default
        var parts: [String] = []
        let folders = (try? fm.contentsOfDirectory(at: componentsDirectory,
                                                   includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders where folder.hasDirectoryPath {
            for name in ["component.json", "icon.txt"] {
                let file = folder.appendingPathComponent(name)
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let modified = attrs[.modificationDate] as? Date,
                   let size = attrs[.size] as? Int {
                    parts.append("\(folder.lastPathComponent):\(name):\(size):\(modified.timeIntervalSince1970)")
                } else {
                    parts.append("\(folder.lastPathComponent):\(name):missing")
                }
            }
        }
        return parts.sorted().joined(separator: "|")
    }

    // MARK: - Starter cleanup

    /// The four SDK examples that releases up to 2.0.12 copied into every install.
    static let starterIDs = ["desk-mode", "night-render", "session-budget", "short-sessions"]
    private static let starterCleanupKey = "starterComponentsRemoved"

    /// Runs once: removes the starter copies, edited or not, with their state.
    func removeStarterComponents() {
        guard !defaults.bool(forKey: Self.starterCleanupKey) else { return }
        defaults.set(true, forKey: Self.starterCleanupKey)
        var ids = enabledIDs
        var values = defaults.dictionary(forKey: valuesKey) ?? [:]
        for id in Self.starterIDs {
            let folder = componentsDirectory.appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                do { try FileManager.default.removeItem(at: folder) }
                catch {
                    Diagnostics.log("starter cleanup failed for \(id): \(error.localizedDescription)")
                    continue
                }
                Diagnostics.log("removed starter component \(id)")
            }
            ids.remove(id)
            values[id] = nil
        }
        enabledIDs = ids
        defaults.set(values, forKey: valuesKey)
    }

    // MARK: - Import / remove

    func importComponent(from source: URL) -> Bool {
        let destination = componentsDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            let data = try Data(contentsOf: source.appendingPathComponent("component.json"))
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  ComponentValidator.validate(json, folderID: source.lastPathComponent).isEmpty else {
                Diagnostics.log("import refused: invalid component manifest")
                return false
            }
            if source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
                reload()
                return true
            }
            // A URL import is not permission to delete a working component. Refuse
            // collisions, rather than destroying it before a fallible copy.
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                Diagnostics.log("import refused: component already exists; edit it in place")
                return false
            }
            try FileManager.default.copyItem(at: source, to: destination)
            reload()
            Diagnostics.log("imported component \(source.lastPathComponent)")
            return true
        } catch {
            Diagnostics.log("import failed: \(error.localizedDescription)")
            return false
        }
    }

    func remove(_ id: String) {
        // The URL endpoint supplies this string too, not just our card menu.
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\0") else {
            Diagnostics.log("remove refused: invalid component folder")
            return
        }
        let root = componentsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let folder = root.appendingPathComponent(id)
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root else {
            Diagnostics.log("remove refused: component is outside the components folder")
            return
        }
        do { try FileManager.default.removeItem(at: folder) }
        catch {
            Diagnostics.log("remove failed: \(error.localizedDescription)")
            return
        }
        var ids = enabledIDs
        ids.remove(id)
        enabledIDs = ids
        reload()
        Diagnostics.log("removed component \(id)")
    }

    // MARK: - Prompts for the user's agent

    var kitDirectory: URL { componentsFolder }

    /// Where the kit and the components live, said the way the rest of the app
    /// says it. The folder keeps its on-disk name ("Components") so kits already
    /// installed keep working, so copy locates it by its parent rather than
    /// printing that old path at the user.
    /// Names the real on-disk folder as well: an agent told to look for a folder
    /// called "Components" would not find one, because the directory is "Components".
    static let componentsFolderLocation = "~/Library/Application Support/Wakely/Components (the Components folder)"

    var newComponentPrompt: String {
        "Build me a Wakely component. First read AGENTS.md, sdk/reference.md and sdk/component.schema.json in \(Self.componentsFolderLocation), then ask me what I want it to do."
    }

    func editPrompt(for id: String) -> String {
        "Change my Wakely component \"\(id)\". First read AGENTS.md, sdk/reference.md and sdk/component.schema.json in \(Self.componentsFolderLocation), then ask me what to change."
    }

    func fixPrompt(for id: String) -> String {
        "Fix my Wakely component \"\(id)\". Read AGENTS.md, sdk/reference.md and sdk/component.schema.json in \(Self.componentsFolderLocation), run the check AGENTS.md describes on component \"\(id)\", and fix every error."
    }

    func copyPrompt(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Diagnostics.log("copied component prompt")
    }

    // MARK: - Loading

    func reload() {
        var loaded: [ComponentSpec] = []
        var found: [String: [String]] = [:]

        let entries = (try? FileManager.default.contentsOfDirectory(
            at: componentsDirectory, includingPropertiesForKeys: nil)) ?? []

        for folder in entries where folder.hasDirectoryPath {
            let manifest = folder.appendingPathComponent("component.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { continue }
            do {
                let data = try Data(contentsOf: manifest)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let problems = ComponentValidator.validate(json, folderID: folder.lastPathComponent)
                if problems.isEmpty {
                    loaded.append(makeSpec(json, folder: folder))
                } else {
                    // An invalid card shows the first line of this list, so each
                    // line says which file the problem is in and what to change.
                    found[folder.lastPathComponent] = problems.map { "This component's component.json — \($0)" }
                }
            } catch {
                found[folder.lastPathComponent] = ["This component's component.json is not valid JSON. Check commas, quotes and braces: \(error.localizedDescription)"]
            }
        }

        // A broken edit must not tear down the last valid running definition.
        // Deleted folders still disappear; errors remain visible on their cards.
        let loadedIDs = Set(loaded.map(\.id))
        loaded.append(contentsOf: components.filter { found[$0.id] != nil && !loadedIDs.contains($0.id) })
        components = loaded.sorted { $0.name < $1.name }
        errors = found
        writeStatusFiles()
        objectWillChange.send()
    }

    private func makeSpec(_ json: [String: Any], folder: URL) -> ComponentSpec {
        let description = json["description"] as? [String: Any] ?? [:]
        let iconURL = folder.appendingPathComponent("icon.txt")
        let icon = (try? String(contentsOf: iconURL, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        return ComponentSpec(
            id: json["id"] as? String ?? folder.lastPathComponent,
            name: json["name"] as? String ?? folder.lastPathComponent,
            tagline: json["tagline"] as? String ?? "",
            keywords: json["keywords"] as? [String] ?? [],
            descriptionText: json["description"] as? String ?? description["text"] as? String ?? "",
            values: description["values"] as? [String: [String: Any]] ?? [:],
            rules: json["rules"] as? [[String: Any]] ?? [],
            directory: folder,
            iconLines: icon)
    }

    private func writeStatusFiles() {
        for component in components {
            let payload: [String: Any] = ["state": "loaded", "name": component.name]
            write(payload, to: component.directory.appendingPathComponent(".status.json"))
        }
        for (id, list) in errors {
            let payload: [String: Any] = ["state": "invalid", "errors": list]
            write(payload, to: componentsDirectory.appendingPathComponent(id).appendingPathComponent(".status.json"))
        }
    }

    private func write(_ payload: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: url)
    }

    /// Install the SDK kit next to the components so "describe a component" works.
    ///
    /// The sdk carries the component-tool shim, so a version change rewrites the
    /// sdk and the shim together. A version change also refreshes the kit's
    /// documents, keeping a copy of the old ones. Only the kit's own files are
    /// replaced; the user's components folder is never touched. A missing helper
    /// is not fatal: the shim stays installed and explains the problem when it is
    /// run.
    func installKitIfNeeded() {
        let fm = FileManager.default
        let kit = supportDirectory.appendingPathComponent("Components", isDirectory: true)
        let versionFile = kit.appendingPathComponent(".kit-version")
        let installedVersion = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if installedVersion == ComponentKitLauncher.kitVersion { return }

        guard let source = Bundle.main.resourceURL?.appendingPathComponent("ComponentsKit", isDirectory: true),
              fm.fileExists(atPath: source.path) else {
            Diagnostics.log("component kit not refreshed: ComponentsKit is missing from the app bundle")
            return
        }

        try? fm.createDirectory(at: kit, withIntermediateDirectories: true)

        let sdk = kit.appendingPathComponent("sdk", isDirectory: true)
        let sourceSDK = source.appendingPathComponent("sdk", isDirectory: true)
        guard fm.fileExists(atPath: sourceSDK.path) else {
            Diagnostics.log("component kit sdk not refreshed: sdk is missing from the app bundle")
            return
        }

        // Stage the copy so a failed refresh leaves the old sdk in place, and
        // stop before recording the version if it fails: the next launch retries.
        let staging = kit.appendingPathComponent(".sdk-\(UUID().uuidString)", isDirectory: true)
        let previous = kit.appendingPathComponent(".sdk-previous-\(UUID().uuidString)", isDirectory: true)
        var movedPrevious = false
        do {
            try fm.copyItem(at: sourceSDK, to: staging)
            if fm.fileExists(atPath: sdk.path) {
                // Keep the old copy until the replacement is in place: a failed
                // move must not leave the user with no SDK at all.
                try fm.moveItem(at: sdk, to: previous)
                movedPrevious = true
            }
            try fm.moveItem(at: staging, to: sdk)
        } catch {
            try? fm.removeItem(at: staging)
            if movedPrevious, !fm.fileExists(atPath: sdk.path) {
                try? fm.moveItem(at: previous, to: sdk)
            }
            try? fm.removeItem(at: previous)
            Diagnostics.log("component kit sdk refresh failed: \(error.localizedDescription)")
            return
        }
        try? fm.removeItem(at: previous)

        guard installComponentToolLauncher(in: sdk) else {
            return
        }

        guard refreshKitDocuments(from: source, in: kit, previousVersion: installedVersion) else {
            // Leave the version unrecorded so the next launch retries, as with a
            // failed sdk or launcher refresh.
            Diagnostics.log("component kit documents not refreshed; the kit version stays at \(installedVersion ?? "unrecorded")")
            return
        }

        do {
            try ComponentKitLauncher.kitVersion.write(to: versionFile, atomically: true, encoding: .utf8)
            let verb = installedVersion == nil ? "installed" : "refreshed"
            Diagnostics.log("component kit \(verb) (version \(ComponentKitLauncher.kitVersion))")
        } catch {
            Diagnostics.log("component kit version file write failed: \(error.localizedDescription)")
        }

    }

    /// Refresh the kit's three documents from the app bundle on a version change.
    ///
    /// An existing document is copied into `.docs-before-<oldVersion>` before it
    /// is replaced, and a copy already in that folder is left alone: a retry must
    /// not overwrite the user's original text. A document the user deleted is
    /// simply installed, an unchanged one is left untouched, and one missing from
    /// the bundle is left as it is and logged. Nothing under `components/` is read
    /// or written.
    ///
    /// Returns false when a document is missing from the bundle or could not be
    /// written, so the caller leaves the version unrecorded and the next launch
    /// retries.
    private func refreshKitDocuments(from source: URL, in kit: URL, previousVersion: String?) -> Bool {
        let fm = FileManager.default
        let backup = kit.appendingPathComponent(".docs-before-\(Self.docsBackupLabel(previousVersion))", isDirectory: true)
        var complete = true

        for name in ["README.txt", "AGENTS.md", "CLAUDE.md"] {
            let origin = source.appendingPathComponent(name)
            let destination = kit.appendingPathComponent(name)
            guard let bundled = try? Data(contentsOf: origin) else {
                Diagnostics.log("component kit \(name) not refreshed: it is missing from the app bundle")
                complete = false
                continue
            }
            if let current = try? Data(contentsOf: destination), current == bundled { continue }
            if fm.fileExists(atPath: destination.path) {
                let saved = backup.appendingPathComponent(name)
                if !fm.fileExists(atPath: saved.path) {
                    do {
                        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
                        try fm.copyItem(at: destination, to: saved)
                    } catch {
                        Diagnostics.log("component kit \(name) not refreshed: its backup could not be written: \(error.localizedDescription)")
                        complete = false
                        continue
                    }
                }
            }
            do { try bundled.write(to: destination, options: .atomic) }
            catch {
                Diagnostics.log("component kit \(name) refresh failed: \(error.localizedDescription)")
                complete = false
            }
        }
        return complete
    }

    /// A stable, path-safe folder label for the version a backup came from.
    private static func docsBackupLabel(_ version: String?) -> String {
        guard let version, !version.isEmpty else { return "unversioned" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = version.components(separatedBy: allowed.inverted).joined(separator: "-")
        let label = String(cleaned.prefix(32))
        return label.isEmpty ? "unversioned" : label
    }

    /// Write the shim that points the installed kit at this app's helper.
    /// Returns false only when the launcher itself could not be written, so
    /// the kit version is not recorded and the next launch retries.
    private func installComponentToolLauncher(in sdk: URL) -> Bool {
        let fm = FileManager.default
        let bin = sdk.appendingPathComponent("bin", isDirectory: true)
        let launcher = bin.appendingPathComponent("wakely-component")
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/wakely-component")
        guard let script = ComponentKitLauncher.script(helperPath: helper.path) else {
            Diagnostics.log("component tool launcher not written: the app bundle path is not a valid helper path")
            return false
        }
        do {
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            try script.write(to: launcher, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        } catch {
            Diagnostics.log("component tool launcher install failed: \(error.localizedDescription)")
            return false
        }
        if !fm.fileExists(atPath: helper.path) {
            Diagnostics.log("component tool launcher installed; helper is missing at \(helper.path)")
        } else if !fm.isExecutableFile(atPath: helper.path) {
            Diagnostics.log("component tool launcher installed; helper is not executable at \(helper.path)")
        } else {
            Diagnostics.log("component tool launcher installed")
        }
        return true
    }
}

extension Notification.Name {
    static let componentEnablementChanged = Notification.Name("dev.wakely.componentEnablementChanged")
}
