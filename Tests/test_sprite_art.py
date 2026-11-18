"""Run with python3 -m unittest discover -s Tests -p 'test_sprite_art.py'."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT))
from sprite_test_support import load_art
art = load_art('wakely_sprites')


class SpriteArtTests(unittest.TestCase):
    def test_catalog_coverage(self):
        import re
        catalog = (ROOT / 'Sources/ComponentCatalog.swift').read_text()
        self.assertEqual(set(re.findall(r'ComponentDefinition\(id: "([^"]+)"', catalog)), set(art.IDS))

    def test_frames_remain_on_native_grid_and_silhouette(self):
        for component, kind in art.IDS.items():
            base = art.Sprite(True, False, 0)
            base.draw(kind)
            alpha = bytes(base.rgba()[3::4])
            for frame in range(8):
                with self.subTest(component=component, frame=frame):
                    sprite = art.Sprite(True, False, 0)
                    sprite.draw(kind)
                    sprite.animate_idle(kind, frame)
                    self.assertEqual(len(sprite.rgba()), 28 * 28 * 4)
                    self.assertEqual(bytes(sprite.rgba()[3::4]), alpha)
                    self.assertEqual(sprite.rgba(), self.render(kind, frame))

    def render(self, kind, frame):
        sprite = art.Sprite(True, False, 0)
        sprite.draw(kind)
        sprite.animate_idle(kind, frame)
        return sprite.rgba()

    def test_disabled_sprites_do_not_animate(self):
        for component, kind in art.IDS.items():
            with self.subTest(component=component):
                sprite = art.Sprite(False, False, 0)
                sprite.draw(kind)
                before = sprite.rgba()
                for frame in range(8):
                    sprite.animate_idle(kind, frame)
                    self.assertEqual(sprite.rgba(), before)

    def test_playback_only_schedules_components_with_changing_frames(self):
        import re
        source = (ROOT / 'Sources/ComponentSprites.swift').read_text()
        listed = source.split('animatedComponents: Set<String> = [', 1)[1].split(']', 1)[0]
        scheduled = set(re.findall(r'"([^"]+)"', listed))
        changing = set()
        for component, kind in art.IDS.items():
            if len({bytes(self.render(kind, frame)) for frame in range(8)}) > 1:
                changing.add(component)
        self.assertEqual(scheduled, changing)

    def test_light_assets_exist_and_match_dark_geometry(self):
        import struct
        for component in art.IDS:
            for state in ['off', 'on', 'hover-off-0', 'hover-on-0']:
                for appearance in ('', '-light'):
                    with self.subTest(component=component, state=state, light=bool(appearance)):
                        path = ROOT / 'Resources/Sprites' / f'{component}-{state}{appearance}.png'
                        data = path.read_bytes()
                        self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
                        self.assertEqual(struct.unpack('>II', data[16:24]), (28, 28))

    def test_generated_assets_exist_and_have_native_dimensions(self):
        import struct
        for component in art.IDS:
            for state in ['off', 'on'] + [f'idle-on-{i}' for i in range(8)]:
                with self.subTest(component=component, state=state):
                    data = (ROOT / 'Resources/Sprites' / f'{component}-{state}.png').read_bytes()
                    self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
                    self.assertEqual(struct.unpack('>II', data[16:24]), (28, 28))


if __name__ == '__main__':
    unittest.main()
