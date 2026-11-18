"""Render the actual ComponentCard offscreen; never activate the app or engine.

Run directly with python3. Set COMPONENT_CARD_VISUAL_OUTPUT to retain PNGs;
otherwise all build/capture artifacts are disposable. This intentionally compiles
all app sources except main, just like test_goo_menu.py, rather than substituting
a replica of the card. Hover/focus are source contracts, not claimed runtime tests.
"""
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
settings = (root / "Sources/SettingsUI.swift").read_text()
card = settings.split("struct ComponentCard: View {", 1)[1].split(
    "private struct ComponentPressStyle", 1)[0]
custom = settings.split("struct CustomComponentCard: View {", 1)[1]
assert "isSelected" not in card, "selection must not leave an accent card perimeter"
assert card.count("ComponentActivationStroke(") == 1
assert "hover ? Theme.hoverOutline : Theme.stroke" in card
assert "hover ? Theme.hoverOutline : Theme.stroke" in custom
assert "ComponentFocusCorners()" in card
assert ".stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 1.5" in card
# The only card strokeBorder is its neutral normal/hover outline. No separate
# gold/selected/focused continuous border may compete with activation tracing.
assert card.count(".strokeBorder(") == 1
assert ".strokeBorder(hover ? Theme.hoverOutline : Theme.stroke, lineWidth: 1)" in card
assert ".focusEffectDisabled()" in card
print("PASS actual card source contracts: no selected ring, neutral hover/focus, sole activation perimeter", flush=True)

sources = sorted(str(p) for p in (root / "Sources").glob("*.swift") if p.name != "main.swift")
with tempfile.TemporaryDirectory(prefix="wakely-card-visual-") as directory:
    work = Path(directory)
    output = Path(os.environ.get("COMPONENT_CARD_VISUAL_OUTPUT", str(work / "captures")))
    binary = work / "component-card-visual"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0", "-parse-as-library",
        "-module-cache-path", str(work / "module-cache"),
        "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "IOKit",
        "-framework", "ServiceManagement", "-framework", "AVFoundation",
        *sources, str(root / "Tests/ComponentCardVisualHarness.swift"),
        "-o", str(binary),
    ], check=True)
    for run in range(int(os.environ.get("COMPONENT_CARD_VISUAL_RUNS", "1"))):
        run_output = output if run == 0 else output / f"repeat-{run + 1}"
        subprocess.run([str(binary), str(run_output)], check=True)
