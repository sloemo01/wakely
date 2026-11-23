import SwiftUI
import AppKit
import Darwin

/// A page built from notes and existing component controls. Opening it never
/// changes component state; only the switches do that through the normal path.
struct CustomScreenPane: View {
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var store = CustomScreenStore.shared
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var components = ComponentStore.shared
    @State private var confirmDelete = false

    private var screen: CustomScreen? { store.screen(for: model.tab) }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 82).accessibilityHidden(true)
            if let screen {
                screenControls(screen)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 8)
                if screen.swift != nil {
                    swiftContent(screen)
                } else {
                    nativeContent(screen)
                }
            }
        }
        .alert("Delete this screen?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                guard let screen else { return }
                store.remove(screen.id)
                model.tab = "components"
            }
        } message: {
            Text("The page and its files are removed. Your components and their settings stay unchanged.")
        }
    }

    private func screenControls(_ screen: CustomScreen) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Edit with Agent") { model.beginScreenPrompt(screen.id) }
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityLabel("Delete Screen")
        }
    }

    private func nativeContent(_ screen: CustomScreen) -> some View {
        EdgeScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if screen.sections.allSatisfy({ $0.blocks.isEmpty }) {
                    emptyPage(screenID: screen.id)
                } else {
                    ForEach(screen.sections) { section in
                        sectionView(section)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func swiftContent(_ screen: CustomScreen) -> some View {
        if let url = store.swiftURL(for: screen),
           let swift = screen.swift,
           FileManager.default.fileExists(atPath: url.path) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            AgentSwiftScreenView(library: url, className: swift.className,
                                 screenTitle: screen.title)
                .id("\(url.path)-\(modified)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Swift screen bundle missing").font(WakelyType.body(14, .semibold))
                Text("Ask your agent to rebuild Screen.dylib, or delete this screen.")
                    .font(WakelyType.body(12)).foregroundStyle(Theme.textSecondary)
                Button("Edit with Agent") { model.beginScreenPrompt(screen.id) }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func emptyPage(screenID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This screen is empty")
                .font(WakelyType.body(14, .semibold))
            Text("Add a note or some components to make it useful.")
                .font(WakelyType.body(12))
                .foregroundStyle(Theme.textSecondary)
            Button("Edit with Agent") { model.beginScreenPrompt(screenID) }
                .padding(.top, 2)
        }
        .padding(.top, 4)
    }

    private func sectionView(_ section: CustomScreenSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title.isEmpty ? "SECTION" : section.title.uppercased())
                .font(WakelyType.label(10))
                .foregroundStyle(Theme.textSecondary)
            ForEach(section.blocks) { block in
                switch block.kind {
                case .note:
                    Text(block.note)
                        .font(WakelyType.body(12.5))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(PixelShape(cut: 3).fill(Theme.card))
                        .overlay(PixelShape(cut: 3).strokeBorder(Theme.stroke, lineWidth: 1))
                case .components:
                    components(block)
                case .status:
                    statusBlock
                }
            }
        }
    }

    private var statusBlock: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 3) {
                Text("WAKELY").font(WakelyType.label(9)).foregroundStyle(Theme.textTertiary)
                Text(state.armed ? "Armed" : "Off")
                    .font(WakelyType.body(14, .semibold))
                    .foregroundStyle(state.armed ? Theme.gold : Theme.ink)
            }
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("COMPONENTS ON").font(WakelyType.label(9)).foregroundStyle(Theme.textTertiary)
                Text("\(model.onCount)")
                    .font(WakelyType.body(14, .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PixelShape(cut: 3).fill(Theme.card))
        .overlay(PixelShape(cut: 3).strokeBorder(Theme.stroke, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func components(_ block: CustomScreenBlock) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(block.componentIDs.enumerated()), id: \.offset) { index, id in
                if index > 0 {
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                }
                componentRow(id)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .background(PixelShape(cut: 3).fill(Theme.card))
        .overlay(PixelShape(cut: 3).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private func componentRow(_ id: String) -> some View {
        if let component = ComponentCatalog.definition(for: id) {
            componentRow(name: component.name, tagline: component.tagline, isOn: model.isOn(id)) {
                model.setOn(id, !model.isOn(id))
            }
        } else if let custom = components.components.first(where: { $0.id == id }) {
            componentRow(name: custom.name, tagline: custom.tagline, isOn: components.isEnabled(id)) {
                components.setEnabled(id, !components.isEnabled(id))
            }
        } else {
            Text("Component unavailable")
                .font(WakelyType.body(11.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func componentRow(name: String, tagline: String, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(WakelyType.body(12.5, .medium))
                Text(tagline)
                    .font(WakelyType.body(11))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 10)
            WakelySwitch(isOn: isOn, action: toggle)
                .accessibilityLabel("Enable \(name)")
        }
    }
}

/// A bounded editor. Draft changes are local until Save writes the screen file.
struct ScreenEditorSheet: View {
    var bodyCap: CGFloat
    var onClose: () -> Void
    @ObservedObject private var store = CustomScreenStore.shared
    @ObservedObject private var model = SettingsModel.shared
    @ObservedObject private var customComponents = ComponentStore.shared
    @State private var draft: CustomScreen
    @State private var errorMessage: String?
    @State private var confirmDelete = false
    @State private var contentHeight: CGFloat = 0
    @FocusState private var titleFocused: Bool

    init(screen: CustomScreen?, bodyCap: CGFloat, onClose: @escaping () -> Void) {
        self.bodyCap = bodyCap
        self.onClose = onClose
        _draft = State(initialValue: screen ?? .blank())
    }

    private var problem: String? {
        CustomScreenStore.validationProblem(CustomScreenStore.normalized(draft), screens: store.screens)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EdgeScrollView(topFade: 24, bottomFade: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.screen(with: draft.id) == nil ? "Create a screen" : "Edit screen")
                            .font(WakelyType.name(17.1))
                        Text("This becomes its own tab in Wakely. Components keep their normal settings and permissions.")
                            .font(WakelyType.body(12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        editorField("Screen name", text: $draft.title).focused($titleFocused)
                        editorField("Subtitle (optional)", text: $draft.subtitle)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(CustomScreen.icons, id: \.self) { icon in
                                    Button {
                                        draft.icon = icon
                                    } label: {
                                        Image(systemName: icon)
                                            .font(.system(size: 13))
                                            .frame(width: 27, height: 27)
                                            .background(PixelShape(cut: 2)
                                                .fill(draft.icon == icon ? Theme.gold.opacity(0.16) : Theme.control))
                                            .overlay(PixelShape(cut: 2)
                                                .strokeBorder(draft.icon == icon ? Theme.gold : Theme.stroke, lineWidth: 1))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(icon)
                                    .accessibilityAddTraits(draft.icon == icon ? .isSelected : [])
                                }
                            }
                        }
                    }

                    ForEach($draft.sections) { $section in
                        sectionEditor(section: $section)
                    }

                    Button {
                        guard draft.sections.count < 6 else { return }
                        draft.sections.append(CustomScreenSection(id: UUID(), title: "", blocks: []))
                    } label: {
                        Label("Add section", systemImage: "plus")
                    }
                    .disabled(draft.sections.count >= 6)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ScreenEditorBodyHeight.self, value: proxy.size.height)
                })
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight > 0 ? contentHeight : bodyCap, bodyCap))
            .onPreferenceChange(ScreenEditorBodyHeight.self) { contentHeight = $0 }

            if let errorMessage {
                Text(errorMessage)
                    .font(WakelyType.body(11.5))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)
            }

            HStack(spacing: 8) {
                if store.screen(with: draft.id) != nil {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Spacer(minLength: 0)
                Button("Cancel") { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Screen") { save() }
                    .buttonStyle(PixelButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 540)
        .pixelPanel(fill: Theme.window, border: Theme.strokeHover, cut: 4)
        .modifier(AppAppearanceModifier())
        .onExitCommand { onClose() }
        .onAppear { titleFocused = true }
        .alert("Delete this screen?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                store.remove(draft.id)
                if model.tab == CustomScreenRoute.tab(for: draft.id) { model.tab = "components" }
                onClose()
            }
        } message: {
            Text("The page is removed. Your components and their settings stay unchanged.")
        }
    }

    private func sectionEditor(section: Binding<CustomScreenSection>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Section title", text: section.title)
                    .textFieldStyle(.plain)
                    .font(WakelyType.body(13, .semibold))
                    .padding(8)
                    .background(PixelShape(cut: 2).fill(Theme.control))
                Button {
                    draft.sections.removeAll { $0.id == section.wrappedValue.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Remove section")
            }

            ForEach(section.blocks) { $block in
                blockEditor(block: $block)
            }

            Menu {
                Button("Text note") { section.wrappedValue.blocks.append(.note()) }
                Button("Components") { section.wrappedValue.blocks.append(.components()) }
                Button("Status") { section.wrappedValue.blocks.append(.status()) }
            } label: {
                Label("Add block", systemImage: "plus")
            }
            .disabled(section.wrappedValue.blocks.count >= 8)
        }
        .padding(12)
        .background(PixelShape(cut: 3).fill(Theme.card))
        .overlay(PixelShape(cut: 3).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private func componentName(_ id: String) -> String {
        ComponentCatalog.definition(for: id)?.name
            ?? customComponents.components.first { $0.id == id }?.name
            ?? id
    }

    private func addComponentButton(id: String, name: String, block: Binding<CustomScreenBlock>) -> some View {
        Button {
            guard !block.wrappedValue.componentIDs.contains(id),
                  block.wrappedValue.componentIDs.count < 8 else { return }
            block.wrappedValue.componentIDs.append(id)
        } label: {
            if block.wrappedValue.componentIDs.contains(id) {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private func blockEditor(block: Binding<CustomScreenBlock>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(block.wrappedValue.kind == .note ? "NOTE"
                     : (block.wrappedValue.kind == .components ? "COMPONENTS" : "STATUS"))
                    .font(WakelyType.label(9))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    draft.sections.indices.forEach { sectionIndex in
                        draft.sections[sectionIndex].blocks.removeAll { $0.id == block.wrappedValue.id }
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Remove block")
            }

            if block.wrappedValue.kind == .note {
                TextField("Write a short note", text: block.note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...5)
                    .padding(9)
                    .background(PixelShape(cut: 2).fill(Theme.control))
            } else if block.wrappedValue.kind == .status {
                Text("Shows whether Wakely is armed and how many components are on.")
                    .font(WakelyType.body(11))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(block.wrappedValue.componentIDs, id: \.self) { id in
                    HStack {
                        Text(componentName(id))
                            .font(WakelyType.body(11.5))
                        Spacer()
                        Button {
                            block.wrappedValue.componentIDs.removeAll { $0 == id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("Remove \(componentName(id))")
                    }
                }
                Menu("Add component") {
                    ForEach(ComponentCatalog.all) { component in
                        addComponentButton(id: component.id, name: component.name, block: block)
                    }
                    if !customComponents.components.isEmpty {
                        Divider()
                        ForEach(customComponents.components) { component in
                            addComponentButton(id: component.id, name: component.name, block: block)
                        }
                    }
                }
                .disabled(block.wrappedValue.componentIDs.count >= 8)
            }
        }
        .padding(9)
        .background(PixelShape(cut: 2).fill(Theme.control))
    }

    private func editorField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .padding(9)
            .background(PixelShape(cut: 2).fill(Theme.control))
            .overlay(PixelShape(cut: 2).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private func save() {
        guard problem == nil else {
            errorMessage = problem
            return
        }
        switch store.save(draft) {
        case .success:
            model.tab = CustomScreenRoute.tab(for: draft.id)
            onClose()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}

private struct ScreenEditorBodyHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct AddScreenCard: View {
    var action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: "plus")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(hover ? Theme.gold : Theme.textTertiary)
                        .frame(width: 56, height: 56)
                        .background(PixelShape(cut: 4).fill(Theme.ink.opacity(hover ? 0.09 : 0.05)))
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.top, 14)
                Spacer(minLength: 10)
                Text("Add a screen").font(WakelyType.name(14.5))
                    .foregroundStyle(Theme.ink).lineLimit(1).padding(.horizontal, 14)
                Text("Describe a page to your agent. It builds the tab for you.")
                    .font(WakelyType.body(11.5)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 3).padding(.bottom, 14)
            }
            .frame(minHeight: 150, alignment: .top).frame(maxWidth: .infinity)
            .background(PixelShape(cut: 4).fill(hover ? Theme.cardHover : Theme.card.opacity(0.6)))
            .overlay(PixelShape(cut: 4).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(hover ? Theme.gold.opacity(0.9) : Theme.strokeHover))
        }
        .buttonStyle(.plain)
        .focusable()
        .onHover { hover = $0 }
        .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
    }
}

/// Agent-first creation flow: Wakely writes no screen itself here. It gives the
/// user a bounded prompt, watches the folder, and validates whatever the
/// coding agent writes before it becomes a tab.
struct ScreenPromptSheet: View {
    var bodyCap: CGFloat
    var onClose: () -> Void
    @ObservedObject private var store = CustomScreenStore.shared
    private let screen: CustomScreen?
    // State, not a let: SwiftUI re-creates this view, and a fresh UUID each
    // time would make the prompt and the created folder disagree.
    @State private var promptID: UUID
    @State private var copied = false
    @State private var request = ""
    @State private var copyReset: DispatchWorkItem?
    @FocusState private var requestFocused: Bool

    init(screen: CustomScreen?, bodyCap: CGFloat, onClose: @escaping () -> Void) {
        self.screen = screen
        _promptID = State(initialValue: screen?.id ?? UUID())
        self.bodyCap = bodyCap
        self.onClose = onClose
    }

    private var prompt: String {
        CustomScreenStore.prompt(for: screen,
                                 id: promptID,
                                 request: request,
                                 screensFolder: store.screensFolder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            EdgeScrollView(topFade: 24, bottomFade: 32) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(screen == nil ? "Make your own screen" : "Edit screen with your agent")
                            .font(WakelyType.name(17.1))
                        Text("Describe the screen you want. Your coding agent builds a complete local screen app; Wakely adds it to the navigation when it is ready.")
                            .font(WakelyType.body(12.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(screen == nil ? "WHAT SHOULD IT DO?" : "WHAT SHOULD CHANGE?")
                            .font(WakelyType.label(9.5)).tracking(1.0)
                            .foregroundStyle(Theme.section)
                        TextField(screen == nil ? "A live weather screen for my city" : "Describe an edit to this screen",
                                  text: $request, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                            .padding(9)
                            .background(PixelShape(cut: 2).fill(Theme.control))
                            .overlay(PixelShape(cut: 2).strokeBorder(Theme.stroke, lineWidth: 1))
                            .focused($requestFocused)
                    }
                    .tourTarget("addScreenForm")

                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text("PROMPT").font(WakelyType.label(9.5)).tracking(1.0)
                                .foregroundStyle(Theme.section)
                            Spacer()
                            Text("Read-only").font(WakelyType.mono(9))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        EdgeScrollView(topFade: 24, bottomFade: 32) {
                            Text(prompt)
                                .font(WakelyType.mono(11))
                                .lineSpacing(2)
                                .foregroundStyle(Theme.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: 250)
                        .scrollIndicators(.hidden)
                        .background(PixelShape(cut: 3).fill(Theme.secondary))
                        .overlay(PixelShape(cut: 3).strokeBorder(Theme.strokeHover))
                        .accessibilityLabel("Prompt to give your coding agent")
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your agent may ask once to read Wakely’s Screens folder. Allow it, then let it write screen.json, Screen.swift and Screen.dylib.")
                            .font(WakelyType.body(11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("The screen runs as native SwiftUI inside Wakely. It can use Swift and public APIs, but it has no automatic permission to components or settings.")
                            .font(WakelyType.body(11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = store.lastError {
                            Text(error)
                                .font(WakelyType.body(11))
                                .foregroundStyle(Color.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .pixelPanel(fill: Theme.card, border: Theme.stroke, cut: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ScreenPromptBodyHeight.self, value: proxy.size.height)
                })
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight > 0 ? contentHeight : bodyCap, bodyCap))
            .onPreferenceChange(ScreenPromptBodyHeight.self) { contentHeight = $0 }

            HStack(spacing: 8) {
                Button("Reveal Screens folder") { NSWorkspace.shared.open(store.screensFolder) }
                Spacer(minLength: 0)
                Button("Done") { onClose() }.keyboardShortcut(.cancelAction)
                Button(copied ? "Copied" : "Copy prompt") { copy() }
                    .buttonStyle(PixelButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .focused($requestFocused)
            }
            .padding(.top, 14)
        }
        .padding(22)
        .frame(width: 500)
        .pixelPanel(fill: Theme.window, border: Theme.strokeHover, cut: 4)
        .modifier(AppAppearanceModifier())
        .onExitCommand { onClose() }
        .onAppear {
            requestFocused = !GuideCoordinator.shared.isPresented
            // The prompt names this folder as the place to write the screen,
            // so it has to exist before the agent (or the user) looks for it.
            try? FileManager.default.createDirectory(at: store.folderURL(for: promptID),
                                                     withIntermediateDirectories: true)
        }
        .onDisappear {
            // rmdir(2) removes the folder only if it is still empty, atomically,
            // so files an agent has just written are never deleted.
            _ = rmdir(store.folderURL(for: promptID).path)
        }
        .onDisappear {
            copyReset?.cancel()
            copyReset = nil
        }
    }

    @State private var contentHeight: CGFloat = 0

    private func copy() {
        guard !GuideCoordinator.shared.isPresented else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        copyReset?.cancel()
        copied = true
        let reset = DispatchWorkItem { copied = false }
        copyReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }
}

private struct ScreenPromptBodyHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Loads a native Swift screen bundle. The screen folder is the entire trust
/// boundary: the bundle runs in Wakely's process, so only user-approved code
/// belongs here. Deletion removes the folder and tab; an already-loaded
/// library is released by the process on quit.
@MainActor
enum SwiftScreenLoader {
    enum Result {
        case success(NSViewController)
        case failure(String)
    }

    private static var handles: [String: UnsafeMutableRawPointer] = [:]

    static func load(library: URL, className: String) -> Result {
        let key = library.path
        let handle: UnsafeMutableRawPointer
        if let existing = handles[key] {
            handle = existing
        } else {
            guard let opened = dlopen(key, RTLD_NOW | RTLD_LOCAL) else {
                let detail = dlerror().map { String(cString: $0) } ?? "The bundle could not be opened."
                return .failure(detail)
            }
            handles[key] = opened
            handle = opened
        }
        _ = handle
        guard let type = NSClassFromString(className) as? NSObject.Type else {
            return .failure("The controller class \(className) was not found in Screen.dylib.")
        }
        let selector = NSSelectorFromString("makeViewController")
        let object = type.init()
        guard object.responds(to: selector) else {
            return .failure("\(className) does not expose makeViewController().")
        }
        guard let unmanaged = object.perform(selector),
              let controller = unmanaged.takeUnretainedValue() as? NSViewController else {
            return .failure("makeViewController() did not return an NSViewController.")
        }
        return .success(controller)
    }
}

struct AgentSwiftScreenView: NSViewControllerRepresentable {
    let library: URL
    let className: String
    let screenTitle: String

    func makeNSViewController(context: Context) -> NSViewController {
        switch SwiftScreenLoader.load(library: library, className: className) {
        case .success(let controller):
            return controller
        case .failure(let message):
            return NSHostingController(rootView: SwiftScreenErrorView(screenTitle: screenTitle,
                                                                     message: message))
        }
    }

    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

private struct SwiftScreenErrorView: View {
    let screenTitle: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(screenTitle) couldn’t load")
                .font(WakelyType.body(15, .semibold))
            Text(message)
                .font(WakelyType.body(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Edit with your agent, rebuild Screen.dylib, then reopen this tab.")
                .font(WakelyType.body(11))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.window)
    }
}
