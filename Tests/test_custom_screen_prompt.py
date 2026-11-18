"""Focused screen-generation prompt contracts; no app build, install or launch.

Run: python3 -m unittest discover -s Tests -p 'test_custom_screen_prompt.py'
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "Sources/CustomScreens.swift").read_text()
PROMPT = SOURCE.split('        return """', 1)[1].split('\n        """', 1)[0]


class CustomScreenPromptTests(unittest.TestCase):
    def test_requires_real_reference_inspection_and_honest_limits(self):
        for reference in ("Sources/Typography.swift", "Sources/PixelUI.swift",
                          "Sources/SettingsUI.swift", "Sources/CustomScreenUI.swift",
                          "ComponentCard", "GeneralPane", "ClamSwitch"):
            self.assertIn(reference, PROMPT)
        self.assertIn("READ Sources/Typography.swift", PROMPT)
        self.assertIn("do not claim you inspected it", PROMPT)
        self.assertIn("Plugins cannot import Wakely's internal", PROMPT)
        self.assertIn("Define private equivalents", PROMPT)

    def test_font_recipes_match_active_typography(self):
        typography = (ROOT / "Sources/Typography.swift").read_text()
        for face in ("PixelOperator", "PixelOperator-Bold", "PixelOperator8",
                     "PixelOperator8-Bold", "PixelOperatorMono", "PixelOperatorMono-Bold"):
            self.assertIn('"' + face + '"', typography)
            self.assertIn('"' + face + '"', PROMPT)
        self.assertIn("max(11, requested + 1.25)", PROMPT)
        self.assertIn("max(11, requested + 1.25)", typography)
        self.assertIn("Geist is a", PROMPT)
        self.assertIn("NOT the active UI", PROMPT)
        self.assertNotIn("system fonts\n          are acceptable", PROMPT)
        self.assertIn("No system-font body/live content", PROMPT)

    def test_adaptive_tokens_match_real_theme(self):
        theme = (ROOT / "Sources/SettingsUI.swift").read_text()
        tokens = re.findall(r"static let (\w+) = adaptive\(light: 0x([0-9A-F]{6}), dark: 0x([0-9A-F]{6})\)", theme)
        required = {"card", "cardHover", "stroke", "strokeHover", "hoverOutline",
                    "ink", "textSecondary", "textTertiary", "control", "controlHover",
                    "controlPressed", "gold", "goldSoft", "accentInk", "switchTrack",
                    "switchTrackHover"}
        self.assertEqual(required, required.intersection(name for name, _, _ in tokens))
        for name, light, dark in tokens:
            if name in required:
                self.assertIn(f"{name} {light}/{dark}", PROMPT)
        self.assertIn("NSColor(name: nil) { appearance in", PROMPT)
        self.assertIn("appearance.bestMatch(from: [.aqua, .darkAqua])", PROMPT)
        self.assertNotIn("card #17130D", PROMPT)

    def test_host_and_control_recipes(self):
        for requirement in ("Host owns the pane title/subtitle", "transparent root/NSHostingController",
                            "no duplicate", "another 82-point spacer", "bottom padding 96",
                            "40x20 cut-2 track", "14x14 square", "22-point travel",
                            "NOT Toggle with the native .switch style", "keyboard activation",
                            "Never nest the switch", "local ButtonStyle", "1-point border",
                            "NOT a dashboard/SaaS aesthetic"):
            self.assertIn(requirement, PROMPT)
        self.assertIn("forced colorScheme/preferredColorScheme", PROMPT)
        self.assertIn("Keep cards opaque", PROMPT)

    def test_scroll_dither_and_shared_subtitle_are_required(self):
        for requirement in (
            "4x4 Bayer checker", "top 28-point and bottom 68-point fades",
            "reveal the host surface", "never a solid gradient",
            "NSScrollView offset", "ramp each over 24 points",
            "The host draws the subtitle 6 points under the title",
            "morphs both\n          title and subtitle glyphs",
            "Never draw a second title or subtitle",
            "90 characters maximum",
        ):
            self.assertIn(requirement, PROMPT)
        self.assertIn("A plain ScrollView or\n          .scrollIndicators(.hidden) alone is not enough", PROMPT)

    def test_control_path_recipe_cannot_drop_the_first_corner(self):
        recipe = PROMPT.split('func path(in rect: CGRect) -> Path {', 1)[1].split('return p', 1)[0]
        self.assertEqual(recipe.count('p.move(to:'), 1)
        self.assertEqual(recipe.count('p.addLine(to:'), 7)
        self.assertEqual(recipe.count('p.closeSubpath()'), 1)
        self.assertNotIn('p.addLines(', recipe)
        self.assertIn('Do NOT call addLines after', PROMPT)
        self.assertIn('strokeBorder stays inside the bounds', PROMPT)
        self.assertIn('no slanted/skewed boxes', PROMPT)

    def test_visual_edits_preserve_complete_product_and_verification(self):
        for requirement in ("preserve ALL existing functionality", "feature inventory before/after",
                            "persistence", "permissions", "refresh behavior", "loading/offline/error",
                            "ask before dropping it", "compile, runtime, visual and",
                            "functional checks separately", "No unrelated files",
                            "No HTML, WKWebView", "Never show invented placeholder values",
                            "Do not enable or", "disable components"):
            self.assertIn(requirement, PROMPT)
        self.assertIn('"id": "\\(id)"', PROMPT)
        self.assertIn('"class": "\\(className)"', PROMPT)
        self.assertIn('-o "\\(libraryPath)" "\\(swiftPath)"', PROMPT)
        self.assertIn('\\(requestText.isEmpty ?', PROMPT)
        self.assertIn('Current screen JSON (preserve its id and class)', SOURCE)


if __name__ == "__main__":
    unittest.main()
