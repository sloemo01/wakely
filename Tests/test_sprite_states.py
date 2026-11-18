"""Sprite state guards: toggling must not fade the icon through transparent."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sprites = (root / 'Sources/ComponentSprites.swift').read_text()
card = (root / 'Sources/SettingsUI.swift').read_text()

built_in = sprites.split('struct CustomComponentSprite', 1)[0]
assert 'PixelRevealMask(progress: reveal)' in built_in
assert '.animation(reduceMotion ? nil : .linear(duration: AppMotion.pixelRevealDuration), value: reveal)' in built_in, 'only the pixel mask animates'
assert 'if on, reveal >= 1 { return }' in built_in, 'a fully lit sprite is never reset to transparent'
assert 'reveal = 0' not in built_in, 'no forced zero before revealing'
assert 'paused: !animatesIdle' in built_in, 'idle animation pauses without swapping the view hierarchy'
assert built_in.count('TimelineView(') == 1
assert 'styled(offState, on: false)' in built_in, 'off artwork remains underneath the reveal'
assert '.transaction { $0.animation = nil }' in built_in, 'inherited card animations cannot fade the sprite'
assert '.animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.12), value: isOn)' not in card, 'card spring must not animate the reveal mask'
assert '.transaction { $0.animation = nil }' in sprites.split('struct CustomComponentSprite', 1)[1]
print('PASS: pixel reveal retained, stable sprite hierarchy, no transparent reset, and isolated mask animation')
