import Foundation

@MainActor
@main
struct CustomScreensTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakely-screens-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CustomScreenStore(directory: root)
        check(store.screens.isEmpty, "a fresh store is empty")

        var screen = CustomScreen.blank()
        screen.title = "  Work  "
        screen.subtitle = "  My working day  "
        screen.sections[0].blocks = [.note("Focus"), .components(["keepAwake", "sleepMeansSleep"])]
        let save = store.save(screen)
        check((try? save.get()) != nil, "a named screen with content saves")
        check(store.screens.count == 1, "the saved screen is published")
        check(store.screens[0].title == "Work", "the title is trimmed")
        check(store.screens[0].sections[0].blocks[1].componentIDs == ["keepAwake", "sleepMeansSleep"],
              "component references round-trip")
        check(store.screen(with: screen.id)?.subtitle == "My working day", "the screen is addressable by its stable id")
        check(store.screen(for: CustomScreenRoute.tab(for: screen.id))?.id == screen.id,
              "the navigation tab resolves back to the screen")
        check(FileManager.default.fileExists(atPath: store.fileURL(for: screen.id).path),
              "each screen is a folder/screen.json an agent can write")

        let prompt = CustomScreenStore.prompt(for: nil,
                                              request: "A live weather screen",
                                              screensFolder: store.screensFolder)
        check(prompt.contains("screen.json") && prompt.contains("Screen.swift") && prompt.contains("Screen.dylib"),
              "the prompt names the native source and bundle")
        check(prompt.contains("A live weather screen"), "the prompt carries the user's request")
        check(prompt.contains("Open-Meteo"), "the prompt gives a keyless live-data path")
        check(prompt.contains("Native SwiftUI + AppKit"), "the prompt requires a native Swift screen")
        check(prompt.contains("makeViewController"), "the prompt defines the loader contract")
        check(prompt.contains("Set a goal before writing code"), "the prompt requires a tracked goal")
        check(prompt.contains("Mark your goal complete only after verification"),
              "the prompt requires verification before completion")
        let editPrompt = CustomScreenStore.prompt(for: screen,
                                                  screensFolder: store.screensFolder)
        check(editPrompt.contains(screen.id.uuidString.lowercased()), "editing preserves the screen id")
        check(editPrompt.contains("Current screen JSON"), "editing includes the current file")

        let reloaded = CustomScreenStore(directory: root)
        check(reloaded.screens == store.screens, "screens survive a store reload")

        let agentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("wakely-agent-screen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: agentRoot) }
        var agentScreen = CustomScreen.blank()
        agentScreen.title = "Agent Made"
        agentScreen.sections[0].blocks = [.status()]
        let agentFolder = agentRoot
            .appendingPathComponent("Screens/screens/\(agentScreen.id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: agentFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(agentScreen).write(to: agentFolder.appendingPathComponent("screen.json"))
        let scanned = CustomScreenStore(directory: agentRoot)
        check(scanned.screens.map(\.title) == ["Agent Made"],
              "a screen written by a coding agent appears without a manual import")

        var swiftScreen = CustomScreen.blank()
        swiftScreen.title = "Swift Weather"
        swiftScreen.sections = []
        swiftScreen.swift = CustomScreenSwift(library: "Screen.dylib",
                                              className: "WakelyScreen_TestBundle")
        let swiftFolder = agentRoot
            .appendingPathComponent("Screens/screens/\(swiftScreen.id.uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: swiftFolder, withIntermediateDirectories: true)
        let encodedSwift = try JSONEncoder().encode(swiftScreen)
        try encodedSwift.write(to: swiftFolder.appendingPathComponent("screen.json"))
        check(String(data: encodedSwift, encoding: .utf8)?.contains("\"class\"") == true,
              "the Swift controller key uses the documented class spelling")
        try Data("not-a-real-dylib".utf8).write(to: swiftFolder.appendingPathComponent("Screen.dylib"))
        let scannedSwift = CustomScreenStore(directory: agentRoot)
        check(scannedSwift.screens.contains { $0.title == "Swift Weather" && $0.swift?.library == "Screen.dylib" },
              "an agent Swift screen loads with its compiled bundle")

        let missingFolder = agentRoot
            .appendingPathComponent("Screens/screens/\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: missingFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(swiftScreen).write(to: missingFolder.appendingPathComponent("screen.json"))
        let withMissing = CustomScreenStore(directory: agentRoot)
        check(withMissing.screens.count == 2, "a Swift screen without its dylib is not shown")
        check(withMissing.lastError != nil, "a missing web file reports a readable error")

        var duplicate = CustomScreen.blank()
        duplicate.title = "work"
        duplicate.sections[0].blocks = [.note("Second")]
        if case .failure(let error) = reloaded.save(duplicate) {
            check(error.localizedDescription.contains("already uses that name"), "screen names are unique")
        } else {
            check(false, "a duplicate name must be refused")
        }

        var reserved = CustomScreen.blank()
        reserved.title = "General"
        reserved.sections[0].blocks = [.status()]
        if case .failure(let error) = reloaded.save(reserved) {
            check(error.localizedDescription.contains("built-in tab"), "built-in tab names are reserved")
        } else {
            check(false, "a screen cannot shadow a built-in tab")
        }

        var statusOnly = CustomScreen.blank()
        statusOnly.title = "Status"
        statusOnly.sections[0].blocks = [.status()]
        if (try? reloaded.save(statusOnly).get()) != nil {
            check(true, "a status block is useful content on its own")
            reloaded.remove(statusOnly.id)
        } else {
            check(false, "a status block should be enough to save")
        }

        var empty = CustomScreen.blank()
        empty.title = "Empty"
        if case .failure(let error) = reloaded.save(empty) {
            check(error.localizedDescription.contains("Add a note"), "an empty screen is refused")
        } else {
            check(false, "an empty screen must not save")
        }

        var normalized = CustomScreen.blank()
        normalized.title = String(repeating: "A", count: 60)
        normalized.icon = "not-a-symbol"
        normalized.sections = Array(repeating: CustomScreenSection(id: UUID(), title: "S", blocks: [.note("x")]), count: 10)
        let clean = CustomScreenStore.normalized(normalized)
        check(clean.title.count == 24, "titles are bounded")
        check(clean.icon == "sparkles", "unknown icons fall back safely")
        check(clean.sections.count == 6, "sections are bounded")

        reloaded.remove(screen.id)
        check(reloaded.screens.isEmpty, "deleting a screen leaves no layout behind")
        check(CustomScreenStore(directory: root).screens.isEmpty, "deletion reaches disk")

        let corruptRoot = root.appendingPathComponent("corrupt")
        let badFolder = corruptRoot.appendingPathComponent("Screens/screens/bad", isDirectory: true)
        try FileManager.default.createDirectory(at: badFolder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: badFolder.appendingPathComponent("screen.json"))
        let corrupt = CustomScreenStore(directory: corruptRoot)
        check(corrupt.screens.isEmpty, "a corrupt screen file does not crash or load partial pages")
        check(corrupt.lastError != nil, "a corrupt screen file reports a recoverable error")

        print("PASS: \(checks) custom-screen round-trip, validation, normalization and corruption checks; no UI or system settings")
    }
}
