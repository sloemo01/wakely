"""Idle animation contracts: geometry, semantics and deterministic PNG pixels."""
from pathlib import Path
import struct
import unittest
import sys
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sprite_test_support import load_art
art = load_art('idle_sprites')


def sprite(kind, frame, on=True):
    image = art.Sprite(on, False, 0)
    image.draw(kind)
    image.animate_idle(kind, frame)
    return image


class IdleSpriteTests(unittest.TestCase):
    def test_fixed_alpha_and_stationary_off(self):
        for kind in art.IDS.values():
            for on in (False, True):
                base = art.Sprite(on, False, 0)
                base.draw(kind)
                for frame in range(8):
                    with self.subTest(kind=kind, on=on, frame=frame):
                        actual = sprite(kind, frame, on).rgba()
                        self.assertEqual(actual[3::4], base.rgba()[3::4])
                        if not on:
                            self.assertEqual(actual, base.rgba())

    def test_passive_policies_remain_stationary(self):
        for kind in ('mute', 'bluetooth', 'laptop'):
            base = art.Sprite(True, False, 0)
            base.draw(kind)
            for frame in range(8):
                self.assertEqual(sprite(kind, frame).rgba(), base.rgba())

    def test_budget_does_not_animate_forbidden_segments(self):
        from sprite_redesign_power import BUDGET_RESERVE, BUDGET_STOP_X, BUDGET_STOP_Y_RANGE
        base = sprite('battery', 0)
        rx, ry, width, height = BUDGET_RESERVE
        for frame in range(8):
            image = sprite('battery', frame)
            for x in range(rx, rx + width):
                for y in range(ry, ry + height):
                    self.assertEqual(image.p[y][x], base.p[y][x])
                    self.assertIn(image.p[y][x], ('n', 'u'))
            for y in range(*BUDGET_STOP_Y_RANGE):
                self.assertEqual(image.p[y][BUDGET_STOP_X], 'l')

    def test_motion_exists_only_in_small_local_regions(self):
        for kind in art.IDS.values():
            base = art.Sprite(True, False, 0)
            base.draw(kind)
            for frame in range(8):
                image = sprite(kind, frame)
                changed = sum(image.p[y][x] != base.p[y][x]
                              for y in range(28) for x in range(28))
                self.assertLessEqual(changed, 80 if kind == 'fan' else 18)
        for kind in ('crt', 'terminal', 'cup', 'hourglass', 'fan', 'server'):
            self.assertGreater(len({bytes(sprite(kind, f).rgba()) for f in range(8)}), 1)

    def test_generated_idle_pixels_match_authored_frames(self):
        for component, kind in art.IDS.items():
            for frame in range(8):
                data = (art.DEST / f'{component}-idle-on-{frame}.png').read_bytes()
                self.assertEqual(struct.unpack('>II', data[16:24]), (28, 28))
                pos, compressed = 8, bytearray()
                while pos < len(data):
                    size = struct.unpack('>I', data[pos:pos+4])[0]
                    tag, body = data[pos+4:pos+8], data[pos+8:pos+8+size]
                    if tag == b'IDAT':
                        compressed.extend(body)
                    pos += size + 12
                rows = zlib.decompress(compressed)
                self.assertTrue(all(rows[y * 113] == 0 for y in range(28)))
                pixels = b''.join(rows[y * 113 + 1:(y + 1) * 113] for y in range(28))
                self.assertEqual(pixels, bytes(sprite(kind, frame).rgba()))


if __name__ == '__main__':
    unittest.main()
