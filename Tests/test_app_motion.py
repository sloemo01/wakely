"""Source integration checks for the shared motion system. No app launch."""
from pathlib import Path
r = Path(__file__).resolve().parents[1] / 'Sources'
def read(name): return (r / name).read_text()
s = read('SettingsUI.swift')
f = read('FluidOpen.swift')
g = read('GooMenuView.swift')
t = read('TorphText.swift')
d = read('ComponentDetailUI.swift')
i = read('InlineValueChip.swift')
a = read('AppMotion.swift')
assert 'guard !reduceMotion else { return nil }' in a
assert '.id(model.tab)' not in s, 'Tab changes must preserve pane identity'
assert '.id(revision)' not in s, 'Restore Defaults must not recreate its editors'
assert 'SettingsPaneMotion' in s and '.accessibilityHidden(!active)' in s
assert 'SwitchDragPolicy.desiredState' in s and '@GestureState' in s
assert 'CardMorphTiming.opening.duration + 0.12' not in s, 'Permission setup follows completion, not a guessing timer'
assert 'presentation.beginClose' in s, 'Back must retarget the live presentation'
assert 'presentation.advance(dt: dt)' in s, 'One display-link sample drives the route'
assert 'CardMorphClock' in s
assert 'surfaceFrame(presentation: p)' in d
assert '.opacity(morph.map' not in s, 'The page must not fade as one whole surface'
assert 'contentProgress:' in s and 'backgroundProgress:' in s
assert 'presentRequirementsIfNeeded(' in s and 'for: event.componentID' in s and 'route: event.sessionID' in s, 'Permission work is keyed to the settled route'
assert 'let compactIn' not in d, 'Morph uses a single moving text layer'
assert 'coordinator.retargetCompactHeight' in f and 'coordinator.advance(elapsed)' in f
assert 'GooMotionCoordinator' in read('GooMotionCoordinator.swift')
assert 'min(0.1, max(0, now - lastFrame))' not in f
assert 'accessibilityDisplayOptionsDidChangeNotification' in f
assert 'AppMotion.longFrameCutoff' in f
assert 'visibility.value > 0.5' not in f
assert 'AppMotion.submenuDuration' in g and 'cancelNavigationAnimation' in g
canvas = t.split('Canvas(opaque:', 1)[1].split('.frame(width: animator.width', 1)[0]
assert 'finishIfNeeded' not in canvas, 'Drawing must not mutate layout state'
assert 'completionTask?.cancel()' in t and '.onChange(of: reduceMotion)' in t
assert 'focusTask' in i and 'errorTask' in i and 'scrubActive' in i
assert 'PixelRevealMask(progress: reveal)' in read('ComponentSprites.swift')
assert 'row.toolTip = nil' in g and 'scrollView.hasVerticalScroller = false' in g
assert 'usesMaterial' in g, 'Menu rows must yield their opaque base only behind real material'
assert 'GlassBackdropView' in f, 'The panel owns one material backdrop'
assert 'NSGlassEffectView' in read('GlassSurface.swift'), 'Native glass is available behind an availability gate'
assert 'accessibilityDisplayShouldReduceTransparency' in read('GlassSurface.swift')
assert 'prepareSettingsController' in read('AppDelegate.swift'), 'First click reuses a prepared hosting tree'
assert 'cacheDisplay(in:' in f and 'before animation' in f, 'First drawing work is warmed outside the spring'
assert 'paneIsActive' in read('ComponentSprites.swift'), 'Hidden panes must not run idle timelines'
assert 'case system, light, dark' in read('AppAppearance.swift')
assert '.preferredColorScheme(.dark)' not in s, 'Settings must follow the selected appearance'
assert 'glass.contentView = container' in read('GlassSurface.swift'), 'Native glass owns the content hierarchy'
assert 'glassBackdrop.contentHost.addSubview(group)' in f
assert 'EdgeScrollView' in d and s.count('EdgeScrollView') >= 5, 'All panes/detail/sheet scroll regions share edge treatment'
assert 'Theme.windowInk' not in read('ScrollEdgeTreatment.swift'), 'Dither cannot cache startup RGB'
assert 'blendMode(.destinationOut)' in read('ScrollEdgeTreatment.swift'), 'Dither must expose actual material, not a black overlay'
assert 'navigationSnapshot' not in g, 'Submenu must not reanimate a stale full-menu bitmap'
assert 'if FluidOpen.shared.needsMenuRefreshBeforeOpening { rebuild() }' in read('MenuBar.swift'), 'Close and reverse must skip synchronous menu rebuild'
assert 'if FluidOpen.shared.acceptsLiveMenuRefresh { rebuild() }' in read('MenuBar.swift'), 'Timer rebuild waits until shell and submenu settle'
assert 'oldValue != keyboardHighlighted' in g, 'Display cadence must not invalidate stable menu rows'
assert 'if oldValue != acceptsInteraction' in f, 'Accessibility writes are phase changes, not per-frame work'
print('PASS: shared motion, prewarmed hosting, native glass ownership, appearance, background-revealing edges and sprite safety')
