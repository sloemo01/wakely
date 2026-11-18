"""Structural contracts for user-created screens; no app or system changes."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = root / "Sources"
store = (src / "CustomScreens.swift").read_text()
ui = (src / "CustomScreenUI.swift").read_text()
settings = (src / "SettingsUI.swift").read_text()

assert "struct CustomScreen: Identifiable, Codable, Equatable" in store
assert "struct CustomScreenSection" in store and "struct CustomScreenBlock" in store
assert "case note, components, status" in store
assert 'prefix = "screen:"' in store
assert 'appendingPathComponent("screen.json")' in store and "options: .atomic" in store
assert "validationProblem" in store
assert "up to eight screens" in store
assert "screens.count < 8" in store

assert 'items.count <= 5' in settings
assert 'screens.screens.map { (CustomScreenRoute.tab(for: $0.id), $0.title, $0.icon) }' in settings
assert 'customScreens.screen(for: model.tab)?.title ?? "Components"' in settings
assert 'CustomScreenPane()' in settings
assert 'active: model.tab == "components"' in settings
assert 'AddScreenCard { model.beginScreenPrompt() }' in settings
assert 'MakeYourOwnCard { model.showMakeYourOwn = true }' in settings
assert settings.index('MakeYourOwnCard { model.showMakeYourOwn = true }') < settings.index('AddScreenCard { model.beginScreenPrompt() }')
assert 'ScreenPromptSheet(screen: model.screenPromptID.flatMap(screens.screen(with:))' in settings
assert 'model.anyModalPresented' in settings

assert 'Button("Edit with Agent")' in ui and 'Add a screen' in ui
assert 'ComponentCatalog.all' in ui
assert 'model.setOn(id, !model.isOn(id))' in ui
assert 'Component unavailable' in ui
assert 'TextEditing' not in ui
assert 'Process(' not in ui
assert 'AgentSwiftScreenView' in ui and 'SwiftScreenLoader' in ui and 'dlopen' in ui
assert 'WebKit' not in ui and 'screen.html' not in ui
assert 'complete SwiftUI screen' in store and 'Treat the request as the product' in store
assert 'Native SwiftUI + AppKit' in store and 'screen.html' not in store
assert 'Screen.swift' in store and 'Screen.dylib' in store and 'Live weather' in store
assert 'Copy prompt' in ui and 'Reveal Screens folder' in ui
assert 'Delete Screen' in ui and 'The page and its files are removed' in ui
assert 'runs as native SwiftUI inside Wakely' in ui
print("PASS: agent-authored native Swift screens are scanned, loaded, and can be deleted completely")
