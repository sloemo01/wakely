import Foundation
import Combine

// A user-authored page. Layout is deliberately declarative and bounded: it can
// arrange existing Wakely controls and text, but cannot add executable content.
struct CustomScreen: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var subtitle: String
    var icon: String
    var sections: [CustomScreenSection]
    /// A compiled SwiftUI screen bundle. When present, Wakely loads this
    /// native screen instead of the legacy declarative blocks.
    var swift: CustomScreenSwift? = nil

    static let icons = ["sparkles", "briefcase", "airplane", "house", "leaf",
                        "bolt", "moon.stars", "sun.max", "cloud.sun", "cup.and.saucer",
                        "terminal", "book", "figure.run"]

    static func blank() -> CustomScreen {
        CustomScreen(id: UUID(), title: "", subtitle: "", icon: "sparkles",
                     sections: [CustomScreenSection(id: UUID(), title: "My controls", blocks: [])])
    }
}

struct CustomScreenSwift: Codable, Equatable {
    var library: String
    var className: String

    enum CodingKeys: String, CodingKey {
        case library
        case className = "class"
    }
}

struct CustomScreenSection: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var blocks: [CustomScreenBlock]
}

struct CustomScreenBlock: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case note, components, status
    }

    var id: UUID
    var kind: Kind
    var note: String
    var componentIDs: [String]

    static func note(_ text: String = "") -> CustomScreenBlock {
        CustomScreenBlock(id: UUID(), kind: .note, note: text, componentIDs: [])
    }

    static func components(_ ids: [String] = []) -> CustomScreenBlock {
        CustomScreenBlock(id: UUID(), kind: .components, note: "", componentIDs: ids)
    }

    static func status() -> CustomScreenBlock {
        CustomScreenBlock(id: UUID(), kind: .status, note: "", componentIDs: [])
    }
}

enum CustomScreenRoute {
    static let prefix = "screen:"

    static func tab(for id: UUID) -> String { prefix + id.uuidString.lowercased() }

    static func id(from tab: String) -> UUID? {
        guard tab.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(tab.dropFirst(prefix.count)))
    }
}

/// Screens are authored by the user's coding agent, one folder per screen:
/// ~/Library/Application Support/Wakely/Screens/screens/<uuid>/screen.json
/// The store watches that folder so a newly written screen appears without a
/// relaunch. It never executes code from a screen file.
@MainActor
final class CustomScreenStore: ObservableObject {
    static let shared = CustomScreenStore()

    @Published private(set) var screens: [CustomScreen] = []
    @Published private(set) var errors: [String: [String]] = [:]
    @Published private(set) var lastError: String?

    private let baseDirectory: URL
    private let screenRoot: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private var watchTimer: Timer?
    private var fingerprint = ""

    var screensFolder: URL { screenRoot }

    init(directory: URL? = nil) {
        baseDirectory = (directory ?? SupportPaths.baseDirectory)
            .appendingPathComponent("Screens", isDirectory: true)
        screenRoot = baseDirectory.appendingPathComponent("screens", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
        startWatching()
    }

    deinit { watchTimer?.invalidate() }

    func screen(with id: UUID) -> CustomScreen? {
        screens.first { $0.id == id }
    }

    func screen(for tab: String) -> CustomScreen? {
        CustomScreenRoute.id(from: tab).flatMap(screen(with:))
    }

    var canCreateAnother: Bool { screens.count < 8 }

    func folderURL(for id: UUID) -> URL {
        screenRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func fileURL(for id: UUID) -> URL {
        folderURL(for: id).appendingPathComponent("screen.json")
    }

    func swiftURL(for screen: CustomScreen) -> URL? {
        guard let swift = screen.swift, !swift.library.isEmpty else { return nil }
        return folderURL(for: screen.id).appendingPathComponent(swift.library)
    }

    @discardableResult
    func save(_ screen: CustomScreen) -> Result<Void, Error> {
        let normalized = Self.normalized(screen)
        if let problem = Self.validationProblem(normalized, screens: screens) {
            lastError = problem
            return .failure(CustomScreenError.message(problem))
        }
        do {
            try write(normalized)
        } catch {
            lastError = "Couldn’t save this screen: \(error.localizedDescription)"
            return .failure(error)
        }
        var next = screens.filter { $0.id != normalized.id }
        next.append(normalized)
        screens = Self.sorted(next)
        errors[normalized.id.uuidString.lowercased()] = nil
        lastError = nil
        fingerprint = currentFingerprint()
        return .success(())
    }

    func remove(_ id: UUID) {
        let folder = screenRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.removeItem(at: folder)
            }
            screens.removeAll { $0.id == id }
            errors[id.uuidString.lowercased()] = nil
            lastError = nil
            fingerprint = currentFingerprint()
        } catch {
            lastError = "Couldn’t remove this screen: \(error.localizedDescription)"
        }
    }

    static func normalized(_ screen: CustomScreen) -> CustomScreen {
        var copy = screen
        copy.title = limited(screen.title.trimmingCharacters(in: .whitespacesAndNewlines), 24)
        copy.subtitle = limited(screen.subtitle.trimmingCharacters(in: .whitespacesAndNewlines), 90)
        if !CustomScreen.icons.contains(copy.icon) { copy.icon = "sparkles" }
        if let swift = copy.swift {
            copy.swift = CustomScreenSwift(
                library: limited(swift.library.trimmingCharacters(in: .whitespacesAndNewlines), 80),
                className: limited(swift.className.trimmingCharacters(in: .whitespacesAndNewlines), 80)
            )
        }
        copy.sections = screen.sections.prefix(6).map { section in
            var copy = section
            copy.title = limited(section.title.trimmingCharacters(in: .whitespacesAndNewlines), 28)
            copy.blocks = section.blocks.prefix(8).map { block in
                var copy = block
                copy.note = limited(block.note.trimmingCharacters(in: .whitespacesAndNewlines), 280)
                copy.componentIDs = Array(block.componentIDs.prefix(8))
                return copy
            }
            return copy
        }
        return copy
    }

    static func validationProblem(_ screen: CustomScreen, screens: [CustomScreen]) -> String? {
        guard !screen.title.isEmpty else { return "Give the screen a name." }
        guard !["components", "general", "about"].contains(screen.title.lowercased()) else {
            return "That name belongs to a built-in tab. Choose another."
        }
        guard screens.count < 8 || screens.contains(where: { $0.id == screen.id }) else {
            return "You can have up to eight screens."
        }
        if screens.contains(where: {
            $0.id != screen.id && $0.title.caseInsensitiveCompare(screen.title) == .orderedSame
        }) {
            return "Another screen already uses that name."
        }
        if let swift = screen.swift {
            let library = swift.library
            let className = swift.className
            guard !library.isEmpty, library.hasSuffix(".dylib"),
                  !library.contains("/"), !library.contains("\\"), !library.contains(".."),
                  library.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                return "The Swift screen must point at a local .dylib file in its folder."
            }
            guard !className.isEmpty,
                  className.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
                return "The Swift screen needs a valid controller class name."
            }
            return nil
        }
        let drawingBlocks = screen.sections.reduce(0) { total, section in
            total + section.blocks.filter {
                $0.kind == .status || !$0.note.isEmpty || !$0.componentIDs.isEmpty
            }.count
        }
        guard drawingBlocks > 0 else { return "Add a note, status or some components before saving." }
        return nil
    }

    /// Prompt handed to the user's coding agent. Screens are native SwiftUI
    /// bundles, so the agent can build the complete screen the user asked for.
    static func prompt(for screen: CustomScreen?,
                       id requestedID: UUID? = nil,
                       request: String = "",
                       screensFolder: URL) -> String {
        let id = (screen?.id ?? requestedID ?? UUID()).uuidString.lowercased()
        let folder = screensFolder.appendingPathComponent(id, isDirectory: true)
        let jsonPath = folder.appendingPathComponent("screen.json").path
        let swiftPath = folder.appendingPathComponent("Screen.swift").path
        let libraryPath = folder.appendingPathComponent("Screen.dylib").path
        let icons = CustomScreen.icons.joined(separator: ", ")
        let current = screen.flatMap { try? JSONEncoder.pretty.encode($0) }
        let action = screen == nil ? "Create" : "Edit"
        let requestText = request.trimmingCharacters(in: .whitespacesAndNewlines)
        let classSuffix = String(id.filter { $0 != "-" }.prefix(10))
        let className = "WakelyScreen_\(classSuffix)"
        return """
        \(action) a native Wakely screen in Swift. A screen becomes its own tab beside Components, General and About.

        What the user wants:
        "\(requestText.isEmpty ? "A useful native screen. Choose a clear purpose." : requestText)"

        Build exactly what the user asked for as a complete SwiftUI screen. Treat the request as the product: choose the layout, data sources and interactions that make it useful. Do not reduce it to a fixed component list, status counters or generic Wakely controls.

        Set a goal before writing code. Use your coding agent's goal or plan feature if it has one; otherwise keep a written checklist. State the goal explicitly, keep it active until the screen is verified, and update it as you work. Do not stop after scaffolding or after writing files.

        Goal example:
        "Build a native Wakely screen that [the user's request], compiles into Screen.dylib, loads in Wakely, and handles loading, offline and error states."

        Acceptance criteria:
        - A complete native SwiftUI/AppKit screen, not a placeholder or component list.
        - screen.json and Screen.swift written in the exact folder above.
        - Screen.dylib compiles with the command below and the controller class is present.
        - The screen does not use fake live data; unavailable data is shown as unavailable.
        - The screen loads in Wakely and its tab opens without a runtime error.
        - No unrelated files, components, settings or user data are changed.

        Verify before reporting success: run the compile command, reopen Wakely, open the new tab, and confirm the screen appears and behaves. If verification is impossible, say exactly what remains unverified instead of claiming success. Mark your goal complete only after verification.

        Write these files inside:
        \(folder.path)

        1. \(jsonPath)
        2. \(swiftPath)

        screen.json:
        {
          "id": "\(id)",
          "title": "Short tab name",
          "subtitle": "One short sentence",
          "icon": "sparkles",
          "sections": [],
          "swift": { "library": "Screen.dylib", "class": "\(className)" }
        }

        Screen.swift requirements:
        - Native SwiftUI + AppKit. No HTML, WKWebView, JavaScript, Electron or web app.
        - Define this public @objc controller and a SwiftUI view. The no-argument
          initializer is inherited from NSObject; do not add an async initializer.
        - Use exactly this controller name so Wakely can find it:
        - The screen is displayed inside Wakely's pane; do not create an
          NSApplication, NSWindow, menu bar item, login item or helper.
        - The screen is native code running in Wakely. Do not access credentials,
          keychain items, private files or unrelated app state. Do not enable or
          disable components. Only run code the user trusts.
        - Use Swift concurrency/URLSession for live data. Handle loading, empty,
          offline and error states. Never show invented placeholder values as
          current. Include a refresh action when useful.
        - Follow the source-based visual contract below; native SwiftUI alone is
          not enough to match Wakely.
        - Use macOS 14 APIs or guard newer APIs with availability checks.
        - No third-party dependencies. No server you control.

        Source-based design/reference inspection (before implementation):
        - Inspect the current screen's Screen.swift and supporting files first when
          editing. Inventory every working feature, data source, action, setting,
          permission flow, persistence key, refresh path and error/empty state.
        - If the Wakely checkout is available, READ Sources/Typography.swift,
          Sources/PixelUI.swift, Theme + ComponentCard + WakelySwitch + GeneralPane
          in Sources/SettingsUI.swift, and Sources/CustomScreenUI.swift. Inspect
          Sources/AppAppearance.swift and Sources/GlassSurfacePolicy.swift for
          appearance/material behavior if available. Do not infer the design from
          legacy bundled fonts, marketing screenshots or the word "native".
        - Compare the running built-in Components cards and General pane with the
          custom screen, including Light, Dark and material/glass appearances.
          If source or UI inspection is unavailable, explicitly report that limit
          and use the self-contained recipes here; do not claim you inspected it.

        Wakely visual contract (implement locally in Screen.swift):
        - Plugins cannot import Wakely's internal WakelyType, Theme, PixelShape,
          PixelButtonStyle, WakelySwitch or EdgeScrollView. Define private equivalents;
          do not reference those internal symbols or link against app sources.
        - ALL text uses Pixel Operator, already registered by the host. Geist is a
          legacy bundled font, NOT the active UI. No system-font body/live content.
          Body: Font.custom("PixelOperator", size: max(11, requested + 1.25)); use
          "PixelOperator-Bold" for semibold/bold body. Titles/names: the bold face
          at max(13, requested), typically 15. Section labels: "PixelOperator8-Bold"
          at 9.5 with tracking(1), uppercase; regular labels use "PixelOperator8".
          Values/code: "PixelOperatorMono" or "PixelOperatorMono-Bold", minimum 9.
          Typical body request 13 resolves to 14.25; secondary 11.5 to 12.75.
          Use actual bold face names, not synthetic .bold(). System fonts are only
          for SF Symbol images, not text; keep symbols small and subordinate.
        - Host owns the pane title/subtitle, top inset (82 points), Edit/Delete
          controls and floating bottom navigation. Return content only: no duplicate
          page title, hero header, sidebar, toolbar or navigation shell; do not add
          another 82-point spacer. Use a transparent root/NSHostingController view
          so the host's solid OR material surface remains visible. No full-pane
          dark fill, forced colorScheme/preferredColorScheme or private preference
          reads. Inherit the host's effective appearance, including live changes.
          The host draws the subtitle 6 points under the title and morphs both
          title and subtitle glyphs with the same animation when the tab changes.
          Never draw a second title or subtitle inside the plugin, add space for
          one, or animate your own header copy; keep the subtitle to one line
          (90 characters maximum) and begin content below the host's reserved header.
        - Reproduce Theme with dynamic NSColor providers, not a startup snapshot
          of NSApp or only the OS theme (Wakely can override it). Local helper:
          func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
              Color(nsColor: NSColor(name: nil) { appearance in
                  let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
                  return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                                 green: Double((hex >> 8) & 255) / 255,
                                 blue: Double(hex & 255) / 255, alpha: 1)
              })
          }
          Define these local token pairs as adaptive(light, dark), in hex:
          window F7F7F8/09090B (host-owned); card FFFFFF/0B0B0E;
          cardHover F4F0E5/1A1812; stroke C7C7CE/27272A;
          strokeHover A99568/6A5930; hoverOutline 8C8C96/70707A;
          ink 202024/FAFAFA; textSecondary 41414B/C4C4CC;
          textTertiary 55555F/A6A6B0; control E5E5EB/1B1B1F;
          controlHover D0D0D9/34343C; controlPressed CBCBD4/3A3A42;
          gold 856000/EAB308; goldSoft 795500/FACC15;
          accentInk FFFFFF/1A1305; switchTrack C4C4CE/27272A;
          switchTrackHover B5B5C1/2E2E33. Keep cards opaque for readable content
          over glass; do not add a full-pane material or opaque reading wash.
        - General-pane recipe: ScrollView with a leading VStack(spacing: 26),
          horizontal padding 28, top padding 14, bottom padding 96 so the final
          control scrolls clear of navigation. Hide scroll indicators. Each section
          is a label plus 8-point gap then one flat panel. Panel rows have 14-point
          padding, 10–12-point horizontal gaps, 3–4-point title/description gaps;
          separators are 1 point with 14-point horizontal inset. Let long copy wrap
          and narrow panes scroll; do not fix the page height or clip controls.
        - Scroll edges use the same dithered shadow as every built-in pane. Wrap the
          vertical scroll in a mask with top 28-point and bottom 68-point fades
          drawn through a 4x4 Bayer checker (4-point cells, binary alpha); the
          cut-away edge must reveal the host surface, never a solid gradient or
          opaque scrim. Derive visibility from the real NSScrollView offset: hide
          both when content does not overflow, top 0 at the start, bottom 0 at the
          end, and ramp each over 24 points. Attach an NSViewRepresentable probe
          to the enclosing NSScrollView (bounds/frame notifications) for the
          offset; do not hard-code a one-off value. A plain ScrollView or
          .scrollIndicators(.hidden) alone is not enough.
        - General panels use a local cut-corner Shape: trace the eight perimeter
          points (minX+c,minY), (maxX-c,minY), (maxX,minY+c), (maxX,maxY-c),
          (maxX-c,maxY), (minX+c,maxY), (minX,maxY-c), (minX,minY+c), close.
          Construct ONE closed subpath: move(to:) once, then seven explicit
          addLine(to:) calls, then closeSubpath(). Do NOT call addLines after
          move(to:): it starts a new subpath, drops the first corner, and produces
          a diagonal top border. Use exactly this local path implementation:
          func path(in rect: CGRect) -> Path {
              let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
              let c = max(0, min(cut, min(r.width, r.height) / 3))
              var p = Path()
              p.move(to: CGPoint(x: r.minX + c, y: r.minY))
              p.addLine(to: CGPoint(x: r.maxX - c, y: r.minY))
              p.addLine(to: CGPoint(x: r.maxX, y: r.minY + c))
              p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
              p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
              p.addLine(to: CGPoint(x: r.minX + c, y: r.maxY))
              p.addLine(to: CGPoint(x: r.minX, y: r.maxY - c))
              p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
              p.closeSubpath()
              return p
          }
          Use InsettableShape with insetAmount accumulated by inset(by:), so
          strokeBorder stays inside the bounds. Verify the path has exactly one
          move, seven lines and one close, including after a 0.5-point inset.
          Top/bottom edges must be horizontal, sides vertical, and all four corner
          cuts equal at button, menu and panel sizes; no slanted/skewed boxes.
          Use cut 4 for section panels, 2 for controls, flat card fill and a 1-point
          stroke. Built-in ComponentCard instead uses a compact continuous rounded
          card: inspect its current metrics when reproducing that specific pattern;
          do not turn all panels into oversized rounded dashboard tiles.
        - Buttons: a local ButtonStyle, PixelOperator body request 12, horizontal
          padding 10 / vertical 5, cut 2, 1-point border; control/controlHover/
          controlPressed fills, ink text. A genuinely primary action may use gold
          with accentInk and goldSoft hover. Show a 2-point gold keyboard-focus
          border, pressed/hover feedback and disabled state; no shadows or bounce.
        - Switches: custom pixel control, NOT Toggle with the native .switch style.
          Use a 40x20 cut-2 track, gold when on or switchTrack when off (hover uses
          switchTrackHover), 1-point stroke; a 14x14 square FAFAFA thumb with black
          0.45-opacity 1-point border, leading inset 2 and 22-point travel. Bind to
          the real state/action, not a decorative copy. Keep tap and drag commits
          single-fire; preserve drag behavior if present. Supply an accessible
          label, on/off value, action and keyboard activation; honor disabled state.
          Never nest the switch inside another clickable card/button.
        - Menus/fields use plain native behavior with local pixel bezels (cut 2,
          control fill, 1-point stroke); menu labels use compact PixelOperator text
          and a small chevron, not a rounded native picker. Sliders may remain
          native with gold tint and PixelOperatorMono value labels. Preserve
          accessibility, keyboard focus, selection and real bindings throughout.
        - Quiet utility UI, NOT a dashboard/SaaS aesthetic: no giant KPI numbers,
          decorative charts, gradients, soft pill stacks, gratuitous badges, heavy
          shadows, giant SF Symbol heroes or repeated nested cards. Use the accent
          sparingly for actions/state. Keep domain-specific content and useful
          charts when actually requested; visual restraint must not remove features.

        Editing and verification contract:
        - For visual-only edits, preserve ALL existing functionality: data sources,
          controls, actions, settings, persistence, permissions, refresh behavior,
          loading/offline/error states and accessibility. Restyle/reorganize rather
          than replace the screen with a simpler mockup. Do not remove a feature
          merely to match a reference; explain conflicts and ask before dropping it.
        - Before reporting success, compare the feature inventory before/after,
          exercise each control and confirm data remains real. Compare typography,
          spacing, surfaces and controls against the built-in references, check
          Light/Dark and transparent material hosting, resizing, keyboard access
          and bottom-navigation clearance. Report compile, runtime, visual and
          functional checks separately, and name anything not actually verified.

        Controller shape:
        import SwiftUI
        import AppKit

        @objc(\(className))
        public final class \(className): NSObject {
            @objc public func makeViewController() -> NSViewController {
                NSHostingController(rootView: MyScreenView())
            }
        }

        private struct MyScreenView: View {
            var body: some View { Text("Build the requested screen here") }
        }

        Compile the bundle after writing the files:
        xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -emit-library \
          -o "\(libraryPath)" "\(swiftPath)" \
          -framework SwiftUI -framework AppKit -framework Foundation

        Live weather guidance:
        - Open-Meteo is keyless:
          https://api.open-meteo.com/v1/forecast?latitude=22.57&longitude=88.36&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day&hourly=temperature_2m,weather_code,precipitation_probability&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=5
        - Use CoreLocation if you want current location; Wakely already has the
          location usage description and permission flow. Otherwise provide a
          city search with:
          https://geocoding-api.open-meteo.com/v1/search?name=Kolkata&count=5&language=en&format=json
        - Show "Weather data by Open-Meteo" with a link to https://open-meteo.com/.
        - Never claim a location or forecast that was not returned by the service.

        Rules:
        - Keep the screen id exactly "\(id)" and use the exact paths above.
        - title: 24 characters maximum. subtitle: 90 characters maximum. icon: one of \(icons).
        - Do not edit other Wakely source files, components or settings.
        - When editing, preserve the current id, controller class and working content unless the request requires a change.

        Wakely watches this folder and adds the tab automatically after screen.json and Screen.dylib both exist. For an existing screen, quit and reopen Wakely after replacing its dylib.
        """
        + (current.map { "\nCurrent screen JSON (preserve its id and class):\n\($0)" } ?? "")
    }

    private static func sorted(_ screens: [CustomScreen]) -> [CustomScreen] {
        screens.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func limited(_ text: String, _ maximum: Int) -> String {
        String(text.prefix(maximum))
    }

    private func load() {
        let manager = FileManager.default
        try? manager.createDirectory(at: screenRoot, withIntermediateDirectories: true)

        var loaded: [CustomScreen] = []
        var problems: [String: [String]] = [:]
        if let folders = try? manager.contentsOfDirectory(at: screenRoot,
                                                          includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles]) {
            for folder in folders {
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                let url = folder.appendingPathComponent("screen.json")
                guard manager.fileExists(atPath: url.path) else { continue }
                do {
                    let data = try Data(contentsOf: url)
                    var screen = try decoder.decode(CustomScreen.self, from: data)
                    if screen.id.uuidString.lowercased() != folder.lastPathComponent.lowercased() {
                        screen.id = UUID(uuidString: folder.lastPathComponent) ?? screen.id
                    }
                    let normalized = Self.normalized(screen)
                    if let swift = normalized.swift,
                       !manager.fileExists(atPath: folder.appendingPathComponent(swift.library).path) {
                        problems[folder.lastPathComponent] = ["The compiled Swift screen is missing. Run its build command again."]
                    } else if let problem = Self.validationProblem(normalized, screens: loaded) {
                        problems[folder.lastPathComponent] = [problem]
                    } else {
                        loaded.append(normalized)
                    }
                } catch {
                    problems[folder.lastPathComponent] = ["The screen JSON couldn’t be read."]
                }
            }
        }

        // One-time compatibility with the early single-file prototype.
        let legacy = baseDirectory.appendingPathComponent("screens.json")
        if loaded.isEmpty, let data = try? Data(contentsOf: legacy),
           let old = try? decoder.decode([CustomScreen].self, from: data) {
            for screen in old.prefix(8) {
                let normalized = Self.normalized(screen)
                try? write(normalized)
                loaded.append(normalized)
            }
            try? manager.removeItem(at: legacy)
        }

        screens = Self.sorted(Array(loaded.prefix(8)))
        errors = problems
        lastError = problems.isEmpty ? nil : "One or more screen files couldn’t be read. Other screens still work."
        fingerprint = currentFingerprint()
    }

    private func write(_ screen: CustomScreen) throws {
        let url = fileURL(for: screen.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try encoder.encode(screen)
        try data.write(to: url, options: .atomic)
    }

    private func currentFingerprint() -> String {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: screenRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]) else { return "" }
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { folder in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles])) ?? []
            let contents = files.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { file in
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return "\(file.lastPathComponent):\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values?.fileSize ?? 0)"
            }.joined(separator: ",")
            return "\(folder.lastPathComponent):\(contents)"
        }.joined(separator: "|")
    }

    private func startWatching() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let next = self.currentFingerprint()
                guard next != self.fingerprint else { return }
                self.load()
            }
        }
        watchTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

enum CustomScreenError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        }
    }
}
