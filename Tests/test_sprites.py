"""Checks grid geometry, state coverage, and PNG assets without image libraries."""
from pathlib import Path
import re
import struct
import unittest
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sprite_test_support import load_art
art = load_art('sprites')


class SpriteTests(unittest.TestCase):
    def test_catalog_coverage(self):
        catalog = (ROOT / 'Sources' / 'ComponentCatalog.swift').read_text()
        names = set(re.findall(r'icon: "([^"]+)"', catalog))
        self.assertEqual(names, set(art.IDS))

    def test_exact_grid_and_solid_pixels(self):
        for component, kind in art.IDS.items():
            for on in (False, True):
                for hover in (False, True):
                    for frame in (0, 1):
                        with self.subTest(component=component, on=on, hover=hover, frame=frame):
                            sprite = art.Sprite(on, hover, frame)
                            sprite.draw(kind)
                            rgba = sprite.rgba()
                            self.assertEqual(len(rgba), 28 * 28 * 4)
                            self.assertTrue(set(rgba[3::4]) <= {0, 255})
                            self.assertGreater(sum(a == 255 for a in rgba[3::4]), 45)

    def test_authored_state_frames_are_different(self):
        for component, kind in art.IDS.items():
            for frame in (0, 1):
                frames = []
                for on, hover in ((False, False), (True, False), (False, True), (True, True)):
                    sprite = art.Sprite(on, hover, frame)
                    sprite.draw(kind)
                    frames.append(bytes(sprite.rgba()))
                with self.subTest(component=component, frame=frame):
                    self.assertEqual(len(set(frames)), 4)

    def test_hover_stays_inside_authored_silhouette(self):
        for component, kind in art.IDS.items():
            for on in (False, True):
                resting = art.Sprite(on, False, 0)
                resting.draw(kind)
                silhouette = bytes(resting.rgba())[3::4]
                for frame in (0, 1):
                    hovered = art.Sprite(on, True, frame)
                    hovered.draw(kind)
                    with self.subTest(component=component, on=on, frame=frame):
                        self.assertEqual(bytes(hovered.rgba())[3::4], silhouette)

    def test_golden_material_is_warm_and_restrained(self):
        for component, kind in art.IDS.items():
            sprite = art.Sprite(True, False, 0)
            sprite.draw(kind)
            painted = [tone for row in sprite.p for tone in row if tone is not None]
            with self.subTest(component=component):
                self.assertTrue(set(painted) <= set('nudbsliw'))
                self.assertGreaterEqual(len(set(painted)), 5)
                self.assertGreaterEqual(len(painted) / (28 * 28), 0.18)
                self.assertLessEqual(len(painted) / (28 * 28), 0.70)
                self.assertLess(sum(tone in 'iw' for tone in painted) / len(painted), 0.12)
                self.assertTrue(all(sprite.p[0][x] is None and sprite.p[27][x] is None for x in range(28)))
                for color in sprite.colors.values():
                    red, green, blue = bytes.fromhex(color.lstrip('#'))
                    self.assertGreaterEqual(red, green)
                    self.assertGreaterEqual(green, blue)
                    self.assertGreater(red - blue, 18, 'material must read yellow, not neutral')

    def test_all_power_and_hover_states_keep_the_same_silhouette(self):
        for component, kind in art.IDS.items():
            silhouettes = set()
            for on in (False, True):
                for hover in (False, True):
                    for frame in (0, 1):
                        sprite = art.Sprite(on, hover, frame)
                        sprite.draw(kind)
                        silhouettes.add(bytes(sprite.rgba())[3::4])
            with self.subTest(component=component):
                self.assertEqual(len(silhouettes), 1)

    def test_light_and_dark_palettes_are_explicit_and_distinct(self):
        for on in (False, True):
            dark = art.Sprite(on, False, 0, 'dark').colors
            light = art.Sprite(on, False, 0, 'light').colors
            self.assertEqual(set(dark), set('nudbsliw'))
            self.assertEqual(set(light), set('nudbsliw'))
            self.assertNotEqual(dark, light)
            for mapping in (dark, light):
                for color in mapping.values():
                    red, green, blue = bytes.fromhex(color.lstrip('#'))
                    self.assertGreaterEqual(red, green)
                    self.assertGreaterEqual(green, blue)

    def test_pngs_are_native_resolution_and_lossless(self):
        for component in art.IDS:
            for state in ('off', 'on', 'hover-off-0', 'hover-off-1', 'hover-on-0', 'hover-on-1'):
                path = ROOT / 'Resources' / 'Sprites' / f'{component}-{state}.png'
                data = path.read_bytes()
                with self.subTest(asset=path.name):
                    self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
                    self.assertEqual(struct.unpack('>II', data[16:24]), (28, 28))
                    pos, compressed = 8, bytearray()
                    while pos < len(data):
                        size = struct.unpack('>I', data[pos:pos+4])[0]
                        kind = data[pos+4:pos+8]
                        body = data[pos+8:pos+8+size]
                        crc = struct.unpack('>I', data[pos+8+size:pos+12+size])[0]
                        self.assertEqual(crc, zlib.crc32(kind + body) & 0xffffffff)
                        if kind == b'IDAT': compressed.extend(body)
                        pos += size + 12
                    self.assertEqual(len(zlib.decompress(compressed)), 28 * (28 * 4 + 1))


if __name__ == '__main__':
    unittest.main()
