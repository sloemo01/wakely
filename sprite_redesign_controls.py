"""Selected control-module redesigns, authored at native 28px resolution.

The icons describe capabilities, not live state. Enablement changes only palette
and small inset/LED treatments. All shells and cues are stationary in idle.
No generator, output assets, or legacy artwork is modified by this module.
"""
from sprite_mac_primitives import closed_mac, open_mac

KINDS = frozenset({'robot', 'key', 'keyboard', 'speaker', 'mute'})


def _task_mac(s):
    # One MacBook, with a single task-to-sleep composition INSIDE its glass.
    open_mac(s)
    s.rect(6, 6, 14, 9, 'n')
    # Agent task window: title strip, completed check, and resting cursor.
    s.rect(7, 7, 7, 7, 'd')
    s.line(7, 7, 13, 7, 's')
    s.dot(8, 7, 'l')
    s.line(8, 10, 10, 12, 'l')
    s.line(10, 12, 13, 9, 'l')
    s.dot(8, 13, 's')
    # Crescent fits the right pane; no floating badge or robot head.
    s.glyph(15, 8, ['..##.', '.##..', '##...', '##...', '.##..', '..###'], 'l')
    s.dot(17, 9, 'i')
    s.line(8, 16, 18, 16, 'b' if s.on else 'd')


def _caps_key(s):
    # Broad, low-profile Mac keycap: a one-pixel skirt, not a tall cube.
    s.poly([(4,6),(22,6),(24,8),(24,21),(22,23),(4,23),(3,21),(3,8)], 'n')
    s.rect(4, 7, 19, 14, 'd')
    s.rect(5, 7, 17, 13, 'b')
    s.line(5, 6, 21, 6, 's')
    s.line(4, 8, 4, 19, 's')
    s.line(5, 8, 21, 8, 's')
    s.line(5, 21, 22, 21, 'u')
    s.line(5, 22, 21, 22, 'd')
    s.dot(6, 7, 'l')
    # Correct Caps Lock legend: HOLLOW up-arrow, separate underline.
    s.glyph(8, 10, [
        '....#....',
        '...#.#...',
        '..#...#..',
        '.#.....#.',
        '###...###',
        '..#...#..',
        '..#####..',
        '.........',
        '..#####..',
    ], 'l')
    # Inset LED well exists in both states; state is not actual activity.
    s.rect(19, 10, 3, 3, 'u')
    s.dot(20, 11, 'i' if s.on else 'd')
    s.dot(21, 12, 's')


def _clean_keyboard(s):
    # Thin aluminum keyboard; rows remain visibly separate from its skirt.
    s.poly([(3,10),(23,10),(25,12),(25,21),(23,23),(3,23),(2,21),(2,12)], 'u')
    s.rect(3, 11, 21, 10, 's')
    s.line(4, 10, 22, 10, 'l')
    s.line(3, 21, 23, 21, 'd')
    s.line(4, 22, 22, 22, 'n')
    for y in (12, 15):
        for x in (4, 8, 12, 16, 20):
            s.rect(x, y, 3, 2, 'u')
            s.line(x, y, x + 1, y, 'b')
    s.rect(4, 18, 3, 2, 'u')
    s.rect(8, 18, 11, 2, 'u')
    s.line(9, 18, 17, 18, 'b')
    s.rect(20, 18, 3, 2, 'u')
    # Folded cleaning cloth overlaps the keyboard's upper-right corner.
    # Lock is printed into the cloth: a single clear cleaning/locking cue.
    s.poly([(16,4),(23,5),(26,9),(23,14),(16,12),(14,8)], 'd')
    s.poly([(16,4),(22,5),(25,9),(22,12),(16,11),(15,8)], 'l')
    s.line(16, 5, 20, 5, 'i')
    s.line(23, 7, 24, 9, 's')
    s.line(22, 12, 25, 9, 'b')
    s.line(18, 7, 18, 8, 'u')
    s.line(19, 6, 20, 6, 'u')
    s.line(21, 7, 21, 8, 'u')
    s.rect(17, 8, 6, 3, 'd')
    s.dot(19, 9, 'l' if s.on else 's')
    s.dot(19, 10, 'n')


def _audio_mac(s, muted):
    # Closed, thin MacBook remains the only primary hardware object.
    closed_mac(s, x=3, y=17, w=21, h=7)
    s.line(9, 20, 15, 21, 'b')
    s.dot(8, 19, 'i')
    # Large engraved/diagrammatic sound cue, NOT a speaker cabinet.
    s.rect(5, 9, 4, 5, 'd')
    s.poly([(8,9),(12,6),(12,17),(8,14)], 's')
    s.line(11, 8, 11, 15, 'l')
    s.line(5, 10, 7, 10, 'b')
    s.line(5, 13, 7, 13, 'u')
    if muted:
        s.line(16, 8, 23, 15, 'u')
        s.line(16, 15, 23, 8, 'u')
        s.line(16, 7, 23, 14, 'l')
        s.line(16, 14, 23, 7, 'l')
        s.dot(16, 7, 'i')
    else:
        # Two generous stepped arcs, not pulsating waves or actual playback.
        s.line(15, 9, 16, 10, 'l')
        s.line(16, 10, 16, 13, 'l')
        s.line(16, 13, 15, 14, 'l')
        s.line(19, 6, 22, 9, 's')
        s.line(22, 9, 22, 14, 'l')
        s.line(22, 14, 19, 17, 's')
        s.dot(20, 7, 'l')
        s.dot(22, 10, 'i')


def draw(s, kind):
    """Draw only the five selected kinds; return False without touching others."""
    if kind not in KINDS:
        return False
    if kind == 'robot':
        _task_mac(s)
    elif kind == 'key':
        _caps_key(s)
    elif kind == 'keyboard':
        _clean_keyboard(s)
    else:
        _audio_mac(s, kind == 'mute')
    return True


def animate(s, kind, frame):
    """Handled but passive: enablement alone never asserts real activity.

    The task window's completed check and resting cursor do not blink. This is
    deliberately safe for both enabled and disabled states, without live agent
    activity input. In particular, never animate audio or cleaning on enable.
    """
    return kind in KINDS
