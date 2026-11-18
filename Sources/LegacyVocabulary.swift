import Foundation

/// The only place the retired "module" vocabulary is still spelled out.
///
/// It exists so a person upgrading from a build that used the old words keeps
/// their enabled components, saved values, protected leases, folders and wire
/// requests. Nothing outside this file, the helper's compatibility switch and
/// the URL alias table may reference these names.
enum LegacyVocabulary {
    // Preferences written by the old vocabulary.
    static let storeEnabledKey = "enabledModules"
    static let engineEnabledKey = "enabledModuleIDs"
    static let valuesKey = "moduleValues"
    static let protectedLeasesKey = "protectedModuleLeases.v1"
    static let savedComponentsKey = "savedModules"

    // On-disk contract.
    static let rootFolder = "Modules"
    static let componentsFolder = "modules"
    static let manifestName = "module.json"

    // Deep links and the settings tab written by older builds.
    static let urlComponentParameter = "module"
    static let settingsTab = "modules"
    static let removeCommand = "removemodule"
    static let importCommand = "importmodule"

    // Privileged helper wire spelling understood by older daemons.
    static let restoreWireOperation = "restoreModule"

    /// Copies every old preference to its new key once. Existing new values
    /// always win, so a launch after migration never overwrites a fresh setting.
    static func migratePreferences(_ defaults: UserDefaults = .standard) {
        copy(storeEnabledKey, to: "enabledComponents", in: defaults)
        copy(engineEnabledKey, to: "enabledComponentIDs", in: defaults)
        copy(valuesKey, to: "componentValues", in: defaults)
        copy(protectedLeasesKey, to: "protectedComponentLeases.v1", in: defaults)
        copy(savedComponentsKey, to: "savedComponents", in: defaults)
    }

    private static func copy(_ old: String, to new: String, in defaults: UserDefaults) {
        guard defaults.object(forKey: new) == nil,
              let value = defaults.object(forKey: old) else { return }
        defaults.set(value, forKey: new)
    }

    /// Moves the old component folders and manifests into the new names.
    /// Never deletes: each step is skipped when the new name already exists.
    static func migrateStorage(in supportDirectory: URL) {
        let fm = FileManager.default
        let newRoot = supportDirectory.appendingPathComponent("Components", isDirectory: true)
        let oldRoot = supportDirectory.appendingPathComponent(rootFolder, isDirectory: true)
        merge(from: oldRoot, into: newRoot, fm: fm)

        let newDir = newRoot.appendingPathComponent("components", isDirectory: true)
        let oldDir = newRoot.appendingPathComponent(componentsFolder, isDirectory: true)
        merge(from: oldDir, into: newDir, fm: fm)

        let legacyDir = oldRoot.appendingPathComponent(componentsFolder, isDirectory: true)
        merge(from: legacyDir, into: newDir, fm: fm)

        let entries = (try? fm.contentsOfDirectory(at: newDir, includingPropertiesForKeys: nil)) ?? []
        for folder in entries where folder.hasDirectoryPath {
            let current = folder.appendingPathComponent("component.json")
            let legacy = folder.appendingPathComponent(manifestName)
            guard !fm.fileExists(atPath: current.path),
                  fm.fileExists(atPath: legacy.path) else { continue }
            try? fm.moveItem(at: legacy, to: current)
        }
    }

    /// Moves children that the destination does not already have, leaving the
    /// old directory in place as the safety net.
    private static func merge(from old: URL, into new: URL, fm: FileManager) {
        guard fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        let children = (try? fm.contentsOfDirectory(at: old, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            let destination = new.appendingPathComponent(child.lastPathComponent)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try? fm.moveItem(at: child, to: destination)
        }
        // Remove the old directory only when it is now empty; a non-empty one
        // is a merge that could not complete and is kept for the next launch.
        if let left = try? fm.contentsOfDirectory(atPath: old.path), left.isEmpty {
            try? fm.removeItem(at: old)
        }
    }
}
