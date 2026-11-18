"""Keep Awake option and display-hold guards; no IOPM assertion is created."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
catalog = (root / 'Sources/ComponentCatalog.swift').read_text()
settings = (root / 'Sources/SettingsUI.swift').read_text()
engine = (root / 'Sources/ComponentBehaviors.swift').read_text()
menu = (root / 'Sources/MenuBar.swift').read_text()

assert 'Keep the screen {screen} while it is awake.' in catalog
assert 'chips["{screen}"]' in settings and 'keepAwake.keepScreenOn' in settings
assert 'kIOPMAssertionTypePreventUserIdleDisplaySleep' in engine
assert 'keepAwakeDisplayAssertion' in engine
assert '("Indefinitely", 0)' in settings, 'component dropdown must offer Indefinitely'
assert 'KeepAwakeMenuPresentation.choices' in menu, 'menu submenu keeps the same option'
assert 'minutes == 0 ? nil : minutes' in settings
assert 'minutes <= 0' in engine, 'switch path treats stored zero as indefinite'
assert 'Keep the screen {screen} while it is plugged in.' in catalog
assert 'alwaysOnPluggedIn.keepScreenOn' in settings
assert 'alwaysOnDisplayAssertion' in engine
assert 'func updateAlwaysOnDisplay' in engine
assert 'durationKnown' in (root / 'Sources/KeepAwakeSelection.swift').read_text()
print('PASS: Keep Awake and Always On expose sentence screen toggles; both hold display sleep only when on; Indefinitely is in both menus')
