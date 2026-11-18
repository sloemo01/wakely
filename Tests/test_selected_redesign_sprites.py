"""Mac-specific redraw scope and behavior cues, not just changed decorations."""
from pathlib import Path
import unittest
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from sprite_test_support import load_art
art = load_art('redesign_sprites')
from sprite_art_devices import draw as devices
from sprite_art_power import draw as power
from sprite_art_connections import draw as connections

SELECTED = {'finishWorkThenSleep','capsLock','cleaningLock','quietClose',
            'lidCloseSound','lowPowerWhileClosed','batteryBudget',
            'stayOffWhenOpened','sleepTimer','ejectOnSleep',
            'bluetoothOffWhileClosed','lidShortcuts','armWhileAppRuns'}


def legacy(kind, on, hover, frame):
    s = art.Sprite(on, hover, frame)
    for draw in (devices, power, connections):
        if draw(s, kind):
            return s
    raise AssertionError(kind)


class SelectedRedesignTests(unittest.TestCase):
    def test_only_the_retained_thirteen_have_new_artwork(self):
        self.assertEqual(len(SELECTED), 13)
        for component, kind in art.IDS.items():
            for on in (True, False):
                for hover in (True, False):
                    for frame in (0, 1):
                        actual = art.Sprite(on, hover, frame)
                        actual.draw(kind)
                        old = legacy(kind, on, hover, frame)
                        with self.subTest(component=component, on=on, hover=hover, frame=frame):
                            if component in SELECTED:
                                # Actual shell/composition changed, not just LEDs.
                                changed_alpha = sum(a != b for a,b in zip(actual.rgba()[3::4],old.rgba()[3::4]))
                                self.assertGreater(changed_alpha, 25)
                            else:
                                self.assertEqual(actual.rgba(), old.rgba())

    def test_ground_shadow_hook_never_paints(self):
        for on in (True, False):
            s = art.Sprite(on, False, 0)
            s.dot(14, 14, 's')
            before = s.rgba()
            s.shadow()
            s.shadow(1, 24, 26)
            self.assertEqual(s.rgba(), before)

    def test_both_batteries_are_standalone_cells_without_lower_props(self):
        for kind in ('leafbattery', 'battery'):
            for on in (True, False):
                s = art.Sprite(on, False, 0)
                s.draw(kind)
                with self.subTest(kind=kind, on=on):
                    # No laptop, floor or decorative pedestal under the cell.
                    self.assertTrue(all(s.p[y][x] is None for y in range(24,28) for x in range(28)))
                    self.assertTrue(all(s.p[y][x] is None for y in range(6) for x in range(28)))
                    self.assertIsNotNone(s.p[13][25])  # battery terminal
                    self.assertEqual(s.p[14][4], 'u')  # recessed meter edge

    def test_powered_off_mac_screen_never_lights_up(self):
        for on in (True,False):
            for frame in range(8):
                s = art.Sprite(on,False,0)
                s.draw('laptop'); s.animate_idle('laptop',frame)
                self.assertTrue(all(s.p[y][x] in ('n','u','d','b')
                                    for y in range(6,15) for x in range(6,20)))

    def test_new_passive_cues_never_imply_live_work_or_audio(self):
        kinds = ('robot','key','keyboard','speaker','mute','leafbattery',
                 'battery','laptop','eject','bluetooth','shortcut')
        for kind in kinds:
            samples=[]
            for frame in range(8):
                s=art.Sprite(True,False,0); s.draw(kind); s.animate_idle(kind,frame)
                samples.append(bytes(s.rgba()))
            with self.subTest(kind=kind):
                self.assertEqual(len(set(samples)),1)


if __name__ == '__main__': unittest.main()
