"""Opt-in offscreen native guide navigation QA; never runs the installed app.

Compiles the actual app views with a link-only AppDelegate seam. No OS input,
permission requests or activation. One far-offscreen, non-key window is ordered
only to materialize AX; no window is placed onscreen. PNGs/logs survive in the
printed temporary evidence directory. AX unavailable is explicitly not a pass
for native UI navigation; source wiring checks remain a separate fallback.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
ui = (root / "Sources/GuideUI.swift").read_text()
contracts = {
    "Continue": 'else { guide.next() }',
    "Back": 'Button("← Back") { guide.previous() }',
    "progress dots": 'onSelect: { guide.go(to: $0) }',
    "Skip": 'Button("Skip for now") { guide.dismiss() }',
    "Explore destination": 'settings.tab = "components"',
    "Explore completion": 'guide.completeOnboarding()',
}
for control, contract in contracts.items():
    assert contract in ui, f"Missing real-view navigation wiring: {control}"
print("PASS: real GuideUI control wiring contracts", flush=True)

work = Path(tempfile.mkdtemp(prefix="wakely-guide-navigation-"))
# Snapshot the inputs so concurrent implementation work cannot invalidate swiftc.
snapshot = work / "Sources"
snapshot.mkdir()
sources = []
for source in sorted((root / "Sources").glob("*.swift")):
    if source.name in ("main.swift", "AppDelegate.swift"):
        continue
    target = snapshot / source.name
    target.write_bytes(source.read_bytes())
    sources.append(str(target))
harness = work / "GuideNavigationVisualHarness.swift"
harness.write_bytes((root / "Tests/GuideNavigationVisualHarness.swift").read_bytes())
binary = work / "guide-navigation"
subprocess.run([
    "xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macos14.0",
    "-parse-as-library", "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
    "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "IOKit",
    "-framework", "ServiceManagement", "-framework", "AVFoundation",
    *sources, str(harness), "-o", str(binary),
], check=True)
subprocess.run([str(binary), str(work)], check=True)
print(f"Evidence: {work}")
