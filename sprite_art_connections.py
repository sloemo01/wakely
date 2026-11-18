"""Original blue game-inventory connection objects on the 28-cell canvas.

Recessed function marks, connectors and small inset lamps identify each module.
Their backing stays opaque and outer geometry is independent of state/frame.
"""


def _lamp(s, x, y, w=1, h=1):
    s.rect(x, y, w, h, 'i' if s.on and not s.frame else 's' if s.on else 'b')


def _case(s, x, y, w, h, depth=3):
    """A beveled upright cabinet with a sloping top and a dark right wall."""
    s.poly([(x, y), (x + depth, y - depth),
            (x + w + depth, y - depth), (x + w, y)], 'l')
    s.poly([(x + w, y), (x + w + depth, y - depth),
            (x + w + depth, y + h - depth), (x + w, y + h)], 'd')
    s.rect(x, y, w, h, 'b')
    s.line(x, y, x, y + h - 1, 's')
    s.line(x + 1, y, x + w - 1, y, 'l')
    s.line(x + 1, y + h - 1, x + w, y + h - 1, 'u')
    s.line(x + w + depth, y - depth + 1,
           x + w + depth, y + h - depth, 'u')


def _eject(s):
    s.shadow(4, 25, 21)
    # Low optical-drive enclosure, its opened tray projecting toward the eye.
    s.poly([(4, 10), (10, 5), (24, 5), (24, 13), (18, 18), (4, 18)], 'u')
    s.poly([(4, 10), (10, 5), (24, 5), (18, 10)], 's')
    s.line(10, 5, 23, 5, 'l')
    s.poly([(18, 10), (24, 5), (24, 13), (18, 18)], 'd')
    s.rect(4, 10, 14, 8, 'b')
    s.line(4, 10, 17, 10, 'l')
    s.rect(5, 12, 12, 4, 'n')
    s.line(6, 12, 16, 12, 'u')
    s.poly([(6, 15), (16, 15), (21, 21), (7, 21), (3, 18)], 'l')
    s.poly([(6, 16), (15, 16), (19, 20), (7, 20), (5, 18)], 'u')
    s.ellipse(7, 16, 10, 4, 's')
    s.ellipse(10, 17, 4, 2, 'd')
    s.dot(11, 17, 'n')
    s.poly([(3, 18), (7, 21), (21, 21), (21, 23), (7, 23), (3, 20)], 'b')
    s.line(7, 21, 20, 21, 'l')
    s.line(7, 23, 20, 23, 'u')
    s.line(4, 19, 6, 21, 's')
    s.poly([(20, 12), (22, 10), (22, 13)], 'l')
    _lamp(s, 20, 15)
    s.dot(9, 6, 'i')


def _bluetooth(s):
    s.shadow(7, 25, 16)
    # Metal USB tongue attached to a tall, rounded radio dongle.
    s.poly([(10, 8), (13, 5), (21, 5), (18, 8)], 'l')
    s.poly([(18, 8), (21, 5), (21, 12), (18, 15)], 'd')
    s.rect(10, 8, 8, 7, 's')
    s.line(10, 8, 17, 8, 'i')
    s.rect(11, 10, 2, 2, 'n')
    s.rect(15, 10, 2, 2, 'u')
    s.line(11, 13, 17, 13, 'l')
    s.poly([(7, 15), (10, 12), (19, 12), (22, 15),
            (22, 21), (18, 24), (9, 24), (7, 22)], 'u')
    s.poly([(8, 15), (11, 13), (18, 13), (20, 15), (17, 17), (8, 17)], 'l')
    s.poly([(18, 16), (21, 14), (21, 21), (18, 23)], 'd')
    s.poly([(8, 16), (17, 16), (18, 17), (18, 23), (10, 23), (8, 21)], 'b')
    s.line(8, 16, 8, 20, 's')
    # The radio emblem is engraved into a physical object, not its silhouette.
    s.line(13, 16, 13, 22, 'l')
    s.line(13, 16, 16, 18, 'l')
    s.line(16, 18, 11, 21, 'l')
    s.line(11, 17, 16, 21, 's')
    s.line(16, 21, 13, 22, 's')
    _lamp(s, 10, 22)


def _terminal(s):
    s.shadow(4, 25, 21)
    # Compact SSH workstation: thick CRT, glass inset, sloped keyboard plinth.
    _case(s, 5, 7, 15, 13, 3)
    s.rect(7, 9, 11, 8, 'u')
    s.rect(8, 10, 9, 6, 'n')
    s.line(8, 10, 16, 10, 'd')
    s.line(9, 11, 11, 12, 'l')
    s.line(11, 12, 9, 14, 'l')
    _lamp(s, 13, 14, 3)
    s.line(7, 18, 15, 18, 'd')
    s.dot(6, 8, 'i')
    s.poly([(5, 20), (20, 20), (24, 23), (22, 25), (4, 25), (3, 23)], 'u')
    s.poly([(5, 19), (19, 19), (23, 22), (4, 22)], 's')
    s.poly([(4, 22), (23, 22), (23, 24), (4, 24)], 'b')
    s.line(4, 22, 22, 22, 'l')
    for x in (7, 10, 13, 16):
        s.rect(x, 20, 2, 1, 'u')
    s.line(9, 23, 16, 23, 'd')
    _lamp(s, 20, 23)


def _shortcut(s):
    s.shadow(3, 25, 22)
    # Two chunky keyboard keys, coupled by an inset steel chain.
    _case(s, 3, 10, 9, 10, 3)
    s.rect(5, 12, 5, 5, 'u')
    s.line(6, 13, 9, 13, 'l')
    s.line(6, 13, 6, 16, 's')
    s.line(6, 16, 9, 16, 's')
    s.line(9, 13, 9, 16, 's')
    s.dot(7, 14, 'b')
    _case(s, 14, 15, 8, 9, 3)
    s.line(16, 18, 19, 18, 'l')
    s.line(19, 18, 19, 21, 's')
    s.line(19, 21, 17, 21, 's')
    s.dot(17, 20, 's')
    # Chain has dark solid shoulders and open centers, connected to both keys.
    s.line(10, 19, 16, 15, 'n')
    s.poly([(9, 18), (12, 15), (15, 15), (17, 17),
            (14, 20), (11, 20)], 'd')
    s.line(10, 18, 13, 15, 'l')
    s.line(13, 15, 15, 15, 's')
    s.line(11, 19, 14, 19, 'b')
    s.line(14, 19, 16, 17, 's')
    s.line(12, 18, 14, 16, 'n')
    s.dot(10, 18, 'i')
    _lamp(s, 20, 22)


def _app(s):
    s.shadow(5, 25, 19)
    # A tiny glass display on a substantial pedestal, showing a boxed app.
    s.poly([(11, 18), (16, 18), (17, 22), (11, 22)], 'd')
    s.poly([(9, 22), (17, 21), (21, 24), (8, 24)], 's')
    s.rect(8, 24, 13, 1, 'u')
    _case(s, 4, 7, 17, 13, 3)
    s.rect(6, 9, 13, 8, 'u')
    s.rect(7, 10, 11, 6, 'n')
    s.rect(10, 10, 6, 6, 'd')
    s.rect(10, 10, 5, 5, 'b')
    s.line(10, 10, 14, 10, 'l')
    s.line(10, 11, 10, 14, 's')
    s.rect(11, 11, 3, 3, 's')
    s.dot(12, 12, 'l')
    s.line(7, 16, 9, 16, 'd')
    s.line(7, 18, 15, 18, 'd')
    _lamp(s, 18, 18)
    s.dot(5, 8, 'i')


def _wifi(s):
    s.shadow(3, 25, 22)
    # Two hinged antennas are attached to the back of the router chassis.
    s.poly([(7, 15), (6, 5), (7, 3), (9, 4), (10, 14)], 'u')
    s.line(7, 5, 8, 14, 'l')
    s.line(8, 5, 9, 13, 'b')
    s.poly([(20, 13), (22, 3), (24, 3), (25, 5), (23, 15)], 'd')
    s.line(22, 4, 20, 14, 's')
    s.line(23, 4, 21, 14, 'b')
    s.poly([(3, 18), (9, 13), (23, 13), (25, 15), (19, 21), (3, 21)], 's')
    s.line(9, 13, 22, 13, 'l')
    s.poly([(19, 19), (25, 14), (25, 20), (19, 25)], 'd')
    s.rect(3, 19, 16, 5, 'b')
    s.line(3, 19, 18, 19, 'l')
    s.line(3, 24, 19, 24, 'u')
    s.line(4, 20, 4, 22, 's')
    for x in (10, 13, 16):
        s.rect(x, 21, 2, 2, 'n')
        _lamp(s, x, 21)
    for x in (11, 14, 17):
        s.line(x, 15, x + 2, 15, 'd')
    s.line(21, 20, 23, 18, 'u')
    s.line(21, 22, 23, 20, 'u')
    s.dot(5, 20, 'i')


def _calendar(s):
    s.shadow(4, 25, 21)
    # A desk easel with a deep folded back, thick page stack and binding tabs.
    s.poly([(9, 6), (21, 6), (25, 23), (21, 25), (17, 11)], 'u')
    s.poly([(20, 8), (22, 7), (25, 23), (23, 23)], 'd')
    s.poly([(5, 8), (9, 5), (23, 5), (20, 8), (18, 24), (4, 24)], 'd')
    s.poly([(5, 8), (20, 8), (18, 23), (4, 23)], 's')
    s.poly([(5, 8), (20, 8), (19, 12), (5, 12)], 'b')
    s.line(5, 8, 19, 8, 'l')
    s.line(4, 23, 18, 23, 'l')
    s.line(19, 13, 18, 22, 'b')
    s.line(5, 13, 4, 22, 'l')
    for x in (8, 15):
        s.rect(x, 4, 2, 6, 'u')
        s.rect(x, 4, 1, 5, 'l')
        s.dot(x, 4, 'i')
        s.dot(x + 1, 9, 'n')
    for y in (14, 17, 20):
        for x in (7, 11, 15):
            s.rect(x, y, 2, 2, 'd')
            s.dot(x, y, 'b')
    s.rect(11, 17, 2, 2, 'b')
    _lamp(s, 11, 17)
    s.line(6, 24, 19, 24, 'u')


def _drive(s):
    s.shadow(4, 25, 21)
    # Ribbed external disk, plus an attached cable and substantial USB plug.
    s.line(19, 18, 24, 18, 'n')
    s.line(24, 18, 24, 10, 'n')
    s.line(20, 17, 23, 17, 'b')
    s.line(23, 17, 23, 10, 's')
    s.poly([(3, 12), (8, 7), (18, 7), (20, 10), (15, 15), (3, 15)], 's')
    s.poly([(15, 13), (20, 8), (20, 20), (15, 25)], 'd')
    s.rect(3, 13, 12, 11, 'b')
    s.line(3, 13, 14, 13, 'l')
    s.line(3, 14, 3, 22, 's')
    s.line(4, 24, 15, 24, 'u')
    s.rect(5, 16, 8, 4, 'u')
    s.rect(6, 17, 6, 2, 'd')
    s.line(6, 17, 10, 17, 's')
    for y in (14, 17, 20):
        s.line(17, y, 19, y - 2, 'u')
    s.line(8, 8, 16, 8, 'l')
    s.dot(5, 14, 'i')
    _lamp(s, 6, 22, 2)
    s.rect(21, 7, 5, 5, 'd')
    s.rect(21, 6, 4, 5, 'b')
    s.line(21, 6, 24, 6, 'l')
    s.rect(21, 3, 4, 3, 's')
    s.line(21, 3, 24, 3, 'l')
    s.dot(22, 4, 'n')
    s.dot(24, 4, 'u')
    s.line(21, 7, 21, 10, 's')


_DRAWERS = {
    'eject': _eject,
    'bluetooth': _bluetooth,
    'terminal': _terminal,
    'shortcut': _shortcut,
    'app': _app,
    'wifi': _wifi,
    'calendar': _calendar,
    'drive': _drive,
}


def draw(sprite, kind) -> bool:
    """Paint a supported physical object, returning False without touching others."""
    painter = _DRAWERS.get(kind)
    if painter is None:
        return False
    painter(sprite)
    _details(sprite, kind)
    return True


def _details(s, kind):
    """One functional inlay plus restrained material/connector detail."""
    lit = 'i' if s.on and not s.frame else 's' if s.on else 'b'
    if kind == 'eject':
        # Eject symbol belongs on the drive casing; the tray has a spindle.
        s.poly([(12, 7), (14, 5), (16, 7)], 'u')
        s.line(12, 8, 16, 8, 'l' if s.on else 'b')
        s.dot(11, 17, 'l'); s.dot(12, 18, 'n')
        s.line(8, 16, 11, 16, 'l')
        s.line(8, 22, 15, 22, 'u')
        s.dot(17, 22, lit)
    elif kind == 'bluetooth':
        # Enabled policy cuts the radio during sleep: rune dims, switch lights.
        s.rect(11, 16, 6, 7, 'b')
        tone = 'd' if s.on else 's'
        s.line(13, 16, 13, 22, tone)
        s.line(13, 16, 16, 18, tone)
        s.line(16, 18, 11, 21, tone)
        s.line(11, 17, 16, 21, tone)
        s.line(16, 21, 13, 22, tone)
        s.rect(19, 17, 2, 5, 'n')
        s.rect(19, 20 if s.on else 17, 2, 2, lit)
        s.line(11, 14, 16, 14, 's')
        s.dot(11, 10, 'u'); s.dot(15, 10, 'n')
    elif kind == 'terminal':
        # A real prompt and a second session row; plugged-in network jack.
        s.line(9, 11, 11, 12, lit); s.line(11, 12, 9, 14, lit)
        s.line(13, 14, 15, 14, lit)
        s.line(9, 15, 12, 15, 'b')
        s.rect(21, 11, 2, 4, 'n'); s.dot(21, 12, 's')
        s.dot(21, 14, lit)
        s.line(6, 23, 7, 23, 's')
    elif kind == 'shortcut':
        # Lid-open/close key engraving and the nested Shortcut diamond.
        s.rect(5, 12, 5, 5, 'u')
        s.line(6, 13, 9, 12, 'l')
        s.line(6, 13, 6, 15, 's'); s.line(6, 16, 9, 16, 's')
        s.rect(16, 17, 5, 5, 'b')
        s.poly([(18, 17), (20, 19), (18, 21), (16, 19)], 'u')
        s.line(17, 19, 18, 18, lit); s.line(18, 18, 19, 19, lit)
        s.line(17, 20, 18, 21, 's')
    elif kind == 'app':
        # Running app window: title bar and play indicator, not an empty tile.
        s.rect(9, 10, 8, 6, 'b')
        s.line(9, 10, 16, 10, 's'); s.dot(10, 10, 'l')
        s.rect(10, 12, 6, 3, 'u')
        s.poly([(12, 12), (14, 13), (12, 14)], lit)
        s.line(22, 10, 23, 9, 'u')
        s.line(22, 13, 23, 12, 'u')
    elif kind == 'wifi':
        # Three stepped radio bands engraved into the router roof.
        # Replace the generic vent dashes, keeping a quiet flat roof around it.
        s.poly([(10, 14), (19, 14), (18, 18), (9, 18)], 's')
        s.line(12, 14, 16, 14, 'u')
        s.dot(11, 15, 'u'); s.dot(17, 15, 'u')
        s.line(13, 16, 15, 16, 'b'); s.dot(14, 18, lit)
        # WAN socket and an AC jack on the dark side wall.
        s.line(21, 19, 23, 17, 'n')
        s.line(21, 20, 23, 18, 's')
        s.dot(21, 23, 'n')
    elif kind == 'calendar':
        # Two endpoints joined by a selected time window, not one random date.
        s.rect(6, 14, 11, 7, 's')
        for x in (7, 11, 15):
            s.rect(x, 14, 2, 2, 'd'); s.dot(x, 14, 'b')
        s.line(7, 18, 15, 18, 'u')
        s.line(8, 18, 14, 18, lit)
        s.line(7, 17, 7, 20, 'b'); s.line(15, 17, 15, 20, 'b')
        s.dot(7, 17, lit); s.dot(15, 17, lit)
        s.line(7, 21, 13, 21, 'b')
        s.line(20, 21, 22, 22, 'b')
    elif kind == 'drive':
        # Backup volume label: disk platter, read head and a seated USB collar.
        s.rect(5, 15, 8, 6, 'u')
        s.ellipse(6, 16, 6, 4, 'd')
        s.line(7, 16, 10, 16, 's'); s.dot(8, 18, 'n')
        s.line(11, 17, 9, 19, 'l' if s.on else 'b')
        s.dot(6, 20, 's'); s.dot(12, 20, 'd')
        s.line(22, 8, 24, 8, 'u')
        s.line(22, 10, 24, 10, 's')
        s.dot(6, 22, lit)
