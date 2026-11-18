"""Visual-system source and asset contracts. No application or permission launch."""
from pathlib import Path
import re
from collections import Counter

root = Path(__file__).resolve().parents[1]
sources = root / "Sources"
ui = (sources / "SettingsUI.swift").read_text()
pixel = (sources / "PixelUI.swift").read_text()
sprites = (sources / "ComponentSprites.swift").read_text()
setup = (sources / "ComponentPermissions.swift").read_text()
typography = (sources / "Typography.swift").read_text()
main = (sources / "main.swift").read_text()
menu = (sources / "GooMenuView.swift").read_text()
detail = (sources / "ComponentDetailUI.swift").read_text()
grid = (sources / "PixelDesign.swift").read_text()

for name, text in [("SettingsUI", ui), ("PixelUI", pixel)]:
    assert ".shadow(" not in text, f"{name} still paints rectangular shadows"
assert "scaleEffect(reduceMotion ? 1 : (hover ? 1.01 : 1))" not in ui, "hover must not move cards"
assert "offset(x: pressed ? 2 : 0" not in pixel, "flat buttons must not jump on press"
assert "hueRotation" not in sprites and "colorMultiply" not in sprites, "sprites use authored palettes"
assert "GoldenSpritePalette" in sprites
assert "ComponentSpriteImages.image(componentID: componentID" in sprites

# Restore authored pixel faces without inflating their semantic sizes. Native
# measurement helpers and their fallbacks must use the same sizes as SwiftUI.
for role, expression in (("body", "max(11, requested + 1.25)"),
                         ("name", "max(13, requested)"),
                         ("label", "max(9, requested)"),
                         ("mono", "max(9, requested)")):
    assert re.search(rf"static func {role}Size\([^\n]+{re.escape(expression)}", typography), role
assert '.custom(isHeavy(weight) ? bodyBold : bodyRegular, size: bodySize(size))' in typography
assert '.custom(bodyBold, size: nameSize(size))' in typography
assert '.custom(displayBold, size: max(12, size))' in typography
assert 'NSFont(name: isHeavy(weight) ? bodyBold : bodyRegular, size: bodySize(size))' in typography
assert '.systemFont(ofSize: bodySize(size)' in typography
assert 'static func registerBundledFonts()' in typography
assert 'CTFontManagerRegisterFontsForURL' in typography
assert "registerBundledFonts()" in main
assert "resolvedFontSummary()" in main
assert "WAKELY_FONT_DIAGNOSTICS" in main and "WAKELY_FONT_DIAGNOSTICS" in (sources / "AppDelegate.swift").read_text()

# Restore compact cards and menu geometry alongside the original type scale.
assert "static let cardMinHeight: CGFloat = 160" in detail
assert ".lineLimit(2)" in ui
assert "static let rowHeight: CGFloat = 32" in menu
assert "static let width: CGFloat = 320" in menu
assert "static let backHeader: CGFloat = 48" in menu

# Navigation floats over the scroll content, not in a fixed footer. Glass is
# intentionally unwashed; contrast contracts below apply to opaque cards only.
assert "static let navHover" in ui
assert "FloatingNav()" in ui and ".overlay(alignment: .bottom)" in ui
assert "readingWash" not in ui
assert "ink.opacity(0.04)" not in ui
assert "if showsFocus || showsHover" in menu
assert "if false" not in menu
assert "GooPalette.hoverOutline" in menu and "GooPalette.gold" in menu
assert "hoverOutline" in ui
assert "width >= 630 + 2 * spacing" in grid
assert "VGrid(spacing: 12)" in ui

# General and About share Components' title-plus-secondary-subtitle hierarchy.
assert '"Set up appearance, startup, safety and helper access."' in ui
assert '"What Wakely does, where it comes from, and its licence."' in ui
assert "if let paneSubtitle" in ui and ".font(ClamType.body(13))" in ui

# Existing alpha geometry is untouched by recolouring.
base = sorted((root / "Resources/Sprites").glob("*.png"))
light = [p for p in base if p.stem.endswith("-light")]
dark = [p for p in base if not p.stem.endswith("-light")]
assert len(dark) == 434, f"unexpected base asset count: {len(dark)}"
assert len(light) == 434, f"unexpected light asset count: {len(light)}"

colors = {
    key: (light_hex, dark_hex)
    for key, light_hex, dark_hex in re.findall(
        r"static let (\w+) = adaptive\(light: 0x([0-9A-F]{6}), dark: 0x([0-9A-F]{6})\)", ui)
}

def luminance(hex_value):
    channels = [int(hex_value[i:i+2], 16) / 255 for i in (0, 2, 4)]
    linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in channels]
    return sum(v * w for v, w in zip(linear, (0.2126, 0.7152, 0.0722)))

def contrast(a, b):
    lo, hi = sorted((luminance(a), luminance(b)))
    return (hi + 0.05) / (lo + 0.05)

for appearance in (0, 1):
    for foreground in ("ink", "textSecondary"):
        ratio = contrast(colors[foreground][appearance], colors["card"][appearance])
        assert ratio >= 4.5, (foreground, appearance, ratio)
        hover_ratio = contrast(colors[foreground][appearance], colors["cardHover"][appearance])
        assert hover_ratio >= 4.5, (foreground, "hover", appearance, hover_ratio)
    assert contrast(colors["cardHoverBorder"][appearance], colors["card"][appearance]) >= 1.7

# Tertiary metadata retains its improved contrast on opaque card surfaces;
# no contrast guarantee is made for bare glass over an arbitrary desktop.
for appearance in (0, 1):
    for surface in ("card", "cardHover"):
        ratio = contrast(colors["textTertiary"][appearance], colors[surface][appearance])
        assert ratio >= 4.5, ("textTertiary", surface, appearance, ratio)
assert contrast(colors["navHover"][0], colors["sidebar"][0]) >= 1.15
assert contrast(colors["controlHover"][0], colors["control"][0]) >= 1.10

# Setup is app-owned content inside the retained panel, not another NSWindow.
assert "setupPresented" in setup
assert "NSWindow(contentRect" not in setup
assert "ComponentSetupContent" in setup
assert "setupPresented" in ui and "ComponentSetupContent(coordinator: permissions)" in ui
assert "EdgeScrollView" in setup
assert ".scrollIndicators(.never)" in (sources / "ScrollEdgeTreatment.swift").read_text()
print("PASS: flat surfaces, semantic contrast, golden asset coverage and in-panel setup contracts")
