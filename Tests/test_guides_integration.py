"""Read-only onboarding/help integration contracts; never launches the real app."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = root / "Sources"
ui = (src / "SettingsUI.swift").read_text()
help_ui = (src / "GuideUI.swift").read_text()
coordinator = (src / "GuideCoordinator.swift").read_text()
content = (src / "GuideContent.swift").read_text()
scene = (src / "PixelGuideScene.swift").read_text()
brand = (src / "BrandIcon.swift").read_text()
playback = (src / "GuidePlayback.swift").read_text()
app = (src / "AppDelegate.swift").read_text()
fluid = (src / "FluidOpen.swift").read_text()
detail = (src / "ComponentDetailUI.swift").read_text()
main = (src / "main.swift").read_text()

for name, text in (("UI", help_ui), ("coordinator", coordinator), ("content", content), ("scene", scene), ("playback", playback)):
    for forbidden in ("PowerEngine.shared", "ComponentEngine.shared", "HelperClient.shared", ".setEnabled(", ".setOn(", ".requestCurrent(", "NSWorkspace.shared.open", "Process()", "AVAudioPlayer"):
        assert forbidden not in text, (name, forbidden)
assert "static let pixelRows" in brand and "pixelRows.enumerated()" in brand
assert "BrandIcon.pixelRows.enumerated()" in scene
assert '"..######.."' not in scene, "Guide still draws a generic mark instead of Wakely's logo"
assert "BrandIcon.appImage" in help_ui and "BrandIcon.onboardingLogo" not in help_ui
assert "BrandIcon.onboardingLogo" not in brand, "The status-bar outline must stay out of onboarding"
assert '.frame(maxWidth: .infinity, alignment: .center)' in help_ui, "onboarding logo must be centred"
assert 'pupil = row == 5 && column == 5' in scene
assert 'rect(x + 6, y + 4, 30, 14, "n", lit: awake)' in scene, "MacBook glass needs a dedicated inset"
assert 'one small window and a separate dock' in scene
assert 'statusIcon(x + 28, y + 4)' in scene, "Laptop status icon must be right-aligned inside the menu strip"
assert 'rect(x + 7, y + 4, 28, 7, "d")' in scene, "The in-screen menu bar must be 7 pixels tall"
assert 'statusIcon(138, 7, lit: true)' in scene, "Welcome desktop needs its own contained status icon"
assert 'rect(101, 7, 45, 7, "d")' in scene, "Welcome desktop menu bar must contain all 7 icon rows"
assert 'wakely(133, 7' not in scene, "An 11-pixel mark cannot sit in an 8-pixel menu bar"
# Active onboarding has its own taller stage and fully contained screen props.
assert 'gridHeight: CGFloat = tour ? 60 : 40' in scene
assert 'func tourScene(' in scene and 'func tourLaptop(' in scene
assert 'tourScene(kind, beat: beat, frame: frame)' in scene
assert 'floor(unit * deviceScale / 2)' in scene, 'Laptop needs a correctly scaled miniature mark'
assert 'let iconWidth = Int(ceil(9 * cell / unit))' in scene
assert 'rect(x + 7, y + 3, 46, 26, "n", lit: lit)' in scene
assert '.frame(height: sceneHeight)' in help_ui
assert 'proxy.size.height - 270' in help_ui, 'Short windows must keep navigation visible'
assert '.frame(maxWidth: 560, minHeight: 36)' in help_ui
assert 'reduced ? (previewBeat ?? 1) : beat' in help_ui, 'Reduced Motion retains an informative still'
for clutter in ('Text("PREVIEW")', 'Text("Try it →")', 'Text("STILL FRAME")', 'labelPrefix: "Scene"', 'This is a demonstration.'):
    assert clutter not in help_ui, f'Remove secondary onboarding clutter: {clutter}'
assert 'guide.progress.step == 0, let appIcon' in help_ui, 'Logo only belongs on the welcome page'
assert 'Read a guide' not in content, 'Removed component guides must not be advertised'
for contract in ("keyboard deck", "trackpad", "Hinge", "camera belongs on the bezel"):
    assert contract in scene, f"Missing recognisable laptop detail: {contract}"
assert 'pupil = row == 5 && column == 5' in scene
# The menu-bar mark uses a coloured pixel outline and white interior. It must
# not be a template image, which macOS would flatten into a single tint.
for contract in ("fill: NSColor = .white", "shouldAntialias = false", "image.isTemplate = false",
                 "func idleStatusImage", "func strokedImage", "func glyphCells",
                 "let edge = cell / 4"):
    assert contract in brand, f"missing coloured-icon contract: {contract}"
assert "func statusImage" in brand and "guard let color else { return idleStatusImage() }" in brand
assert "TimelineView" not in scene and "Task" not in scene
assert "repeatForever" not in help_ui
assert "paused: !playback.isRunning || !canAnimate" in help_ui
assert "didResignActiveNotification" in help_ui and "didBecomeActiveNotification" in help_ui
assert "minimumInterval: 0.2" in help_ui
assert "PixelHelpButton" not in help_ui and "PixelHelpButton" not in detail and "PixelHelpButton" not in ui
assert "HOW IT WORKS" not in help_ui and "componentGuide" not in coordinator
assert "back()" in coordinator and "progress.complete()" in coordinator
assert "guard persistenceEnabled, !preview" in coordinator
assert "hadRecord ? .dismissed : .unseen" in coordinator
assert "keyAELaunchedAsLogInItem" in coordinator and 'arguments.contains("--background")' in coordinator
assert "guideLaunchContext.foregroundOpen, NSApp.isActive" in app
assert "guideLaunchCommandReceived = true" in app
assert "classifyExistingInstallation(!guideLaunchWasNew)" in app
assert "preservingGuide: true" in app
assert "GuideDestinationView()" in ui
assert ".disabled(guides.isPresented)" in ui
assert ".accessibilityHidden(guides.isPresented)" in ui
assert 'section("GETTING STARTED")' in ui
assert "guides.showOnboarding(restart:" in ui
assert "- ComponentCardMetrics.switchWidth - 16)" in detail
assert "showComponent(" not in coordinator and "showCustom(" not in coordinator
assert "ComponentGuideCatalog" not in content and "ComponentGuide" not in content
assert fluid.index("if GuideCoordinator.shared.isPresented") < fluid.index("if ComponentPermissions.shared.setupPresented")
assert 'Button("Skip for now")' in help_ui
assert 'Button("← Back")' in help_ui and '"Continue →"' in help_ui
assert '"Explore Components →"' in help_ui
assert "GuideProgressDots" in help_ui and ".accessibilityValue(" in help_ui
assert ".onExitCommand { guide.dismiss() }" in help_ui
assert '"--render-guide-preview"' in main and "configureGuidePreview()" in main
assert "previewOnboarding(step:" in main and "previewComponent" not in main
assert "previewReduceMotion" in coordinator and "forceReducedMotion" in help_ui
print("PASS: onboarding-only guide, no component help controls/routes, finite playback and accessibility contracts")
