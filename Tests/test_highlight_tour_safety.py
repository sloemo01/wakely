"""Source contracts for safety boundaries that ordinary hit-testing cannot prove."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class HighlightTourSafetyTests(unittest.TestCase):
    def test_real_panes_are_keyboard_disabled_and_accessibility_hidden(self):
        text = (ROOT / 'Sources/SettingsUI.swift').read_text()
        pane = text.split('ComponentsPane().modifier', 1)[1].split('.background(glass.', 1)[0]
        self.assertIn('.disabled(guides.isPresented)', pane)
        self.assertIn('!guides.isPresented', pane)
        self.assertIn('.accessibilityHidden', pane)
        self.assertIn('if !guides.isPresented { searchFocused = true }', text)
        self.assertIn('allowsBackShortcut: !guides.isPresented', text)

    def test_component_dispatch_and_prompt_export_are_guarded(self):
        settings = (ROOT / 'Sources/SettingsUI.swift').read_text()
        toggle = settings.split('func setOn(', 1)[1].split('func refresh()', 1)[0]
        self.assertLess(toggle.index('guard !GuideCoordinator.shared.isPresented'),
                        toggle.index('ComponentEngine.shared.setEnabled'))
        self.assertIn('guard !GuideCoordinator.shared.isPresented else { return }\n        store.copyPrompt(prompt)', settings)
        screen = (ROOT / 'Sources/CustomScreenUI.swift').read_text()
        self.assertIn('guard !GuideCoordinator.shared.isPresented else { return }\n        NSPasteboard.general.clearContents()', screen)

    def test_menu_leaf_dispatch_and_window_shortcuts_are_guarded(self):
        menu = (ROOT / 'Sources/MenuBar.swift').read_text()
        dispatch = menu.split('private func perform(', 1)[1].split('/// Test seam:', 1)[0]
        self.assertLess(dispatch.index('GuideCoordinator.shared.isPresented'), dispatch.index('NSApp.sendAction'))
        window = (ROOT / 'Sources/FluidOpen.swift').read_text().split('override func performKeyEquivalent', 1)[1]
        self.assertLess(window.index('GuideCoordinator.shared.isPresented'), window.index('onQuit?()'))

    def test_live_menu_availability_omits_steps_instead_of_explaining_off_state(self):
        menu = (ROOT / 'Sources/MenuBar.swift').read_text()
        self.assertIn('SettingsModel.shared.$enabled.dropFirst().sink', menu)
        view = (ROOT / 'Sources/GooMenuView.swift').read_text()
        self.assertIn('guide.updateMenuKeepAwakeAvailability(available)', view)
        self.assertNotIn('guide.menuKeepAwakeAvailable = available', view)
        coach = (ROOT / 'Sources/HighlightTourUI.swift').read_text()
        coach = coach.split('struct HighlightTourCoach:', 1)[1].split('struct TourPracticeValue:', 1)[0]
        self.assertIn('Text(step.title)', coach)
        self.assertIn('guide.displayedStep', coach)
        self.assertIn('guide.displayedStepCount', coach)
        self.assertNotIn('menuKeepAwakeAvailable', coach)
        self.assertNotIn('highlightComponents', coach)
        self.assertNotIn('displayTitle', coach)
        for unavailable_copy in ['unavailable', "aren’t available", "aren\'t available", 'component is off', 'Keep Awake is off']:
            self.assertNotIn(unavailable_copy, coach)
        coordinator = (ROOT / 'Sources/GuideCoordinator.swift').read_text()
        self.assertIn('private(set) var menuKeepAwakeAvailable', coordinator)
        self.assertIn('func updateMenuKeepAwakeAvailability(', coordinator)
        self.assertIn('var availableTourSteps:', coordinator)
        self.assertNotIn('ComponentEngine', coordinator)

    def test_practice_and_anchors_stay_local(self):
        text = (ROOT / 'Sources/HighlightTourUI.swift').read_text()
        practice = text.split('struct TourPracticeValue:', 1)[1].split('/// UI-only routing.', 1)[0]
        self.assertIn('$guide.demoMinutes', practice)
        self.assertNotIn('UserDefaults', practice)
        self.assertIn('transformAnchorPreference', text)
        self.assertIn('values[id] = anchor', text)
        route = text.split('final class HighlightTourNavigation', 1)[1]
        for dangerous in ['setEnabled(', 'startKeepAwake(', 'armFromMenu', 'HelperClient', 'UserDefaults.standard.set']:
            self.assertNotIn(dangerous, route)

if __name__ == '__main__':
    unittest.main()
