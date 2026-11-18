"""Chunky, top-left-lit blue inventory objects on the parent's 28px grid.

Small engraved function marks and inset indicators share the object's perspective.
Only painted colors change with power/frame; all variants retain their silhouette.
"""


def draw(sprite, kind) -> bool:
    """Draw a supported physical device, returning False for unknown kinds."""
    if kind not in {'crt', 'status', 'robot', 'bell', 'lamp', 'reset',
                    'key', 'keyboard', 'speaker', 'mute', 'lock', 'bag'}:
        return False
    q = sprite
    pulse = 'i' if q.on and q.frame == 0 else 's' if q.on else 'b'

    if kind == 'crt':
        q.shadow(4, 25, 21)
        # Deep cabinet, angled away to the right, with a thick glass bezel.
        q.poly([(4, 5), (19, 3), (25, 6), (25, 18), (20, 21), (4, 19)], 'u')
        q.poly([(4, 5), (19, 3), (25, 6), (9, 8)], 's')
        q.line(5, 5, 18, 3, 'l')
        q.poly([(20, 7), (25, 6), (25, 18), (20, 21)], 'd')
        q.line(23, 9, 23, 16, 'u')
        q.line(24, 9, 24, 16, 'b')
        q.poly([(3, 6), (19, 6), (21, 8), (21, 20), (4, 20), (3, 19)], 'b')
        q.line(4, 6, 18, 6, 'l')
        q.line(3, 7, 3, 18, 's')
        q.rect(5, 8, 14, 10, 'u')
        q.rect(6, 9, 12, 8, 'n')
        q.line(6, 9, 16, 9, 'd')
        q.line(7, 10, 9, 10, 's')
        q.line(7, 11, 7, 13, 'b')
        q.line(10, 13, 12, 15, pulse)
        q.line(12, 15, 15, 11, pulse)
        q.rect(6, 19, 8, 1, 'd')
        q.dot(18, 19, pulse)
        q.poly([(11, 21), (16, 21), (17, 23), (10, 23)], 'd')
        q.poly([(8, 23), (18, 22), (21, 24), (7, 24)], 's')
        q.line(8, 24, 20, 24, 'b')

    elif kind == 'status':
        q.shadow(5, 25, 19)
        # A pocket terminal with a projecting screen hood and tactile buttons.
        q.poly([(5, 7), (20, 4), (24, 7), (24, 22), (20, 25), (5, 23)], 'u')
        q.poly([(5, 7), (20, 4), (24, 7), (9, 10)], 's')
        q.line(6, 7, 19, 4, 'l')
        q.poly([(20, 9), (24, 7), (24, 22), (20, 25)], 'd')
        q.poly([(4, 8), (19, 8), (21, 10), (21, 23), (5, 23), (4, 22)], 'b')
        q.line(5, 8, 18, 8, 'l')
        q.line(4, 9, 4, 21, 's')
        q.rect(6, 10, 13, 8, 'u')
        q.rect(7, 11, 11, 6, 'n')
        q.line(8, 12, 13, 12, pulse)
        q.line(8, 14, 11, 14, 's')
        q.rect(14, 14, 2, 2, pulse)
        q.rect(7, 19, 3, 2, 'l')
        q.rect(12, 19, 2, 2, 's')
        q.rect(16, 19, 2, 2, 'd')
        q.line(8, 22, 17, 22, 'd')
        q.line(23, 12, 23, 18, 'u')

    elif kind == 'robot':
        q.shadow(4, 25, 21)
        q.rect(13, 2, 2, 4, 'd')
        q.rect(12, 2, 3, 2, 's')
        q.dot(12, 2, pulse)
        q.poly([(6, 7), (19, 5), (23, 8), (23, 15), (19, 17), (6, 15)], 'd')
        q.poly([(6, 7), (19, 5), (23, 8), (10, 10)], 'l')
        q.rect(5, 8, 15, 8, 'b')
        q.line(5, 8, 18, 8, 's')
        q.rect(7, 10, 11, 4, 'n')
        q.rect(8, 11, 3, 2, 'u')
        q.rect(14, 11, 3, 2, 'u')
        # Sleeping eyes fill the same solid eye inset rather than erasing it.
        q.line(8, 11 if q.on else 12, 10, 11 if q.on else 12, pulse)
        q.line(14, 11 if q.on else 12, 16, 11 if q.on else 12, pulse)
        q.rect(10, 15, 5, 1, 'd')
        q.rect(10, 16, 7, 2, 'u')
        q.poly([(7, 18), (18, 17), (21, 19), (20, 23), (7, 23)], 'b')
        q.line(8, 18, 17, 17, 'l')
        q.poly([(18, 18), (21, 19), (20, 23), (18, 23)], 'd')
        q.rect(10, 19, 5, 3, 'u')
        q.dot(11, 20, pulse)
        q.line(13, 20, 14, 20, 's')
        q.rect(4, 18, 3, 5, 'd')
        q.rect(4, 18, 2, 3, 's')
        q.rect(22, 17, 3, 5, 'u')
        q.rect(22, 17, 2, 3, 'b')
        q.rect(7, 23, 5, 2, 'd')
        q.rect(16, 23, 5, 2, 'd')
        q.line(7, 23, 11, 23, 's')
        q.line(16, 23, 20, 23, 'b')

    elif kind == 'bell':
        q.shadow(4, 25, 21)
        # Cast school bell, crown, thick flared skirt and a visible clapper.
        q.poly([(12, 4), (16, 3), (19, 5), (18, 8), (12, 8)], 'd')
        q.rect(12, 4, 4, 3, 's')
        q.line(13, 4, 15, 4, 'l')
        q.poly([(9, 8), (16, 6), (20, 9), (21, 17), (25, 21), (21, 24), (5, 23), (3, 21), (7, 17)], 'd')
        q.poly([(9, 8), (15, 7), (18, 9), (18, 17), (21, 21), (6, 21), (9, 16)], 'b')
        q.poly([(9, 9), (12, 8), (11, 17), (8, 20), (6, 20), (9, 16)], 's')
        q.line(10, 9, 11, 9, 'l')
        q.line(9, 11, 9, 15, 'l')
        q.dot(10, 10, 'i')
        q.poly([(4, 20), (20, 20), (24, 21), (21, 23), (5, 22)], 's')
        q.line(5, 20, 19, 20, 'l')
        q.poly([(6, 23), (21, 24), (23, 22), (8, 22)], 'u')
        q.rect(13, 22, 3, 3, 'd')
        q.line(13, 24, 15, 24, pulse)

    elif kind == 'lamp':
        q.shadow(4, 25, 21)
        q.poly([(7, 22), (17, 21), (23, 24), (20, 25), (5, 25), (4, 24)], 'd')
        q.poly([(7, 22), (17, 21), (22, 23), (6, 24), (4, 23)], 's')
        q.line(7, 22, 16, 21, 'l')
        q.line(13, 21, 18, 14, 'u')
        q.line(12, 21, 17, 14, 's')
        q.line(17, 14, 12, 8, 'd')
        q.line(16, 14, 11, 8, 'l')
        q.rect(15, 13, 4, 3, 'b')
        q.dot(16, 13, 'i')
        q.poly([(7, 4), (13, 3), (18, 8), (16, 12), (5, 12), (3, 10)], 'd')
        q.poly([(7, 4), (12, 4), (16, 8), (5, 10), (3, 10)], 's')
        q.line(7, 4, 12, 4, 'l')
        q.poly([(4, 10), (16, 8), (17, 10), (15, 12), (5, 13)], 'u')
        q.line(6, 11, 14, 10, 'l')
        q.line(8, 11, 12, 10, pulse)
        q.dot(8, 5, 'i')
        q.rect(8, 23, 3, 1, 'b')

    elif kind == 'reset':
        q.shadow(4, 25, 21)
        # Twin-bell alarm clock, with a reset arrow embossed in its dial.
        q.poly([(6, 4), (10, 3), (13, 6), (8, 9), (4, 7)], 'd')
        q.poly([(6, 4), (10, 3), (12, 5), (6, 7)], 's')
        q.poly([(18, 3), (22, 4), (25, 7), (21, 9), (17, 6)], 'd')
        q.line(18, 3, 22, 4, 'l')
        q.rect(13, 4, 3, 3, 'b')
        q.ellipse(4, 7, 21, 17, 'd')
        q.ellipse(3, 7, 19, 17, 's')
        q.ellipse(4, 8, 17, 15, 'b')
        q.ellipse(6, 9, 13, 12, 'n')
        q.line(7, 10, 10, 9, 'l')
        q.line(6, 11, 6, 16, 's')
        q.line(13, 11, 16, 13, pulse)
        q.line(16, 13, 16, 17, pulse)
        q.line(16, 17, 12, 19, pulse)
        q.line(12, 19, 9, 17, pulse)
        q.line(9, 17, 9, 14, pulse)
        q.poly([(7, 15), (9, 12), (11, 15)], 's')
        q.dot(13, 15, 'l')
        q.line(7, 23, 6, 24, 'd')
        q.line(19, 22, 21, 24, 'd')

    elif kind == 'key':
        q.shadow(3, 25, 22)
        q.poly([(4, 9), (18, 5), (24, 10), (24, 21), (10, 25), (3, 20)], 'u')
        q.poly([(4, 9), (18, 5), (24, 10), (10, 15)], 'l')
        q.poly([(10, 15), (24, 10), (24, 21), (10, 25)], 'd')
        q.poly([(3, 10), (10, 15), (10, 25), (3, 20)], 'b')
        q.poly([(6, 9), (17, 6), (21, 10), (10, 13)], 's')
        q.line(6, 9, 16, 6, 'i')
        q.line(4, 11, 4, 18, 's')
        q.line(11, 16, 22, 12, 'b')
        q.line(11, 23, 22, 20, 'u')
        # A chunky caps-lock up arrow sunk into the key's sloping top.
        q.poly([(10, 10), (12, 7), (16, 9), (14, 9), (14, 11), (12, 12), (12, 10)], 'u')
        q.line(12, 12, 15, 11, 'b')

    elif kind == 'keyboard':
        q.shadow(2, 25, 24)
        q.poly([(3, 9), (19, 5), (26, 17), (25, 21), (9, 26), (2, 20)], 'u')
        q.poly([(3, 9), (19, 5), (26, 17), (9, 23), (2, 18)], 's')
        q.poly([(9, 23), (26, 17), (25, 21), (9, 26)], 'd')
        q.poly([(2, 18), (9, 23), (9, 26), (2, 21)], 'b')
        q.line(3, 9, 18, 5, 'l')
        q.line(3, 19, 8, 23, 'l')
        # Separate raised keycaps, not a dither overlay: staggered rows follow
        # the same perspective, each with a dark lower wall and lit crown.
        for row in range(3):
            for col in range(5):
                x = 4 + col * 3 + row * 2
                y = 10 - col + row * 3
                q.poly([(x, y), (x + 2, y), (x + 2, y + 2), (x, y + 2)], 'u')
                q.line(x, y, x + 1, y, 'l' if row == 0 else 's')
                q.line(x, y + 1, x + 1, y + 1, 'b')
        q.poly([(9, 20), (18, 17), (20, 19), (11, 22)], 'u')
        q.line(10, 20, 18, 18, 'l')
        q.line(11, 21, 19, 19, 'b')
        q.dot(19, 7, pulse)

    elif kind in {'speaker', 'mute'}:
        q.shadow(5, 25, 19)
        q.poly([(6, 6), (18, 3), (23, 6), (23, 22), (18, 25), (6, 23)], 'u')
        q.poly([(6, 6), (18, 3), (23, 6), (11, 9)], 's')
        q.line(7, 6, 17, 3, 'l')
        q.poly([(18, 8), (23, 6), (23, 22), (18, 25)], 'd')
        q.poly([(5, 7), (17, 7), (19, 9), (19, 24), (6, 24), (5, 23)], 'b')
        q.line(6, 7, 16, 7, 'l')
        q.line(5, 8, 5, 22, 's')
        q.ellipse(9, 9, 6, 5, 'u')
        q.ellipse(10, 10, 4, 3, 'n')
        q.dot(10, 10, 's')
        q.ellipse(7, 15, 10, 8, 'u')
        q.ellipse(8, 15, 8, 7, 'd')
        q.ellipse(9, 16, 6, 5, 'n')
        q.ellipse(10, 17, 4, 3, 'b')
        q.dot(10, 17, 'l')
        q.line(21, 10, 21, 19, 'u')
        if kind == 'mute':
            # Physical inset slider on the side; never an external cross.
            q.rect(20, 15, 3, 6, 'n')
            q.rect(20, 16 if q.on else 18, 3, 2, 's')
            q.line(9, 12, 15, 19, 'd')
            q.line(10, 12, 16, 19, 's')
        else:
            q.dot(16, 23, pulse)

    elif kind == 'lock':
        q.shadow(4, 25, 21)
        # Thick steel shackle with a deeply shaded, recessed middle.
        q.ellipse(7, 2, 15, 17, 'd')
        q.ellipse(7, 2, 12, 16, 's')
        q.ellipse(10, 5, 6, 11, 'n')
        # The inset is an occluded dark interior of the lock, not a cutout.
        q.line(9, 5, 9, 11, 'l')
        q.line(11, 3, 15, 3, 'l')
        q.dot(11, 3, 'i')
        q.poly([(5, 13), (18, 10), (24, 14), (24, 22), (18, 26), (5, 23)], 'u')
        q.poly([(5, 13), (18, 10), (24, 14), (11, 17)], 'l')
        q.poly([(18, 16), (24, 14), (24, 22), (18, 26)], 'd')
        q.poly([(4, 14), (17, 14), (19, 16), (19, 24), (5, 24), (4, 23)], 'b')
        q.line(5, 14, 16, 14, 's')
        q.line(4, 15, 4, 22, 'l')
        q.ellipse(10, 17, 4, 4, 'n')
        q.rect(11, 20, 2, 2, 'n')
        q.dot(10, 17, 's')
        q.line(6, 23, 16, 23, 'd')

    elif kind == 'bag':
        q.shadow(4, 25, 21)
        q.poly([(10, 5), (10, 2), (17, 2), (19, 5), (16, 6), (15, 4), (12, 4), (12, 6)], 'd')
        q.line(11, 2, 16, 2, 'l')
        # Rear straps and side bottle pocket are physical silhouette details.
        q.poly([(19, 7), (23, 9), (24, 22), (21, 24), (20, 20)], 'u')
        q.poly([(7, 6), (17, 4), (22, 8), (23, 22), (20, 25), (6, 24), (4, 21), (4, 11)], 'd')
        q.poly([(7, 6), (16, 5), (19, 8), (19, 23), (6, 23), (4, 21), (4, 11)], 'b')
        q.poly([(7, 6), (16, 5), (19, 8), (8, 10), (5, 11)], 's')
        q.line(7, 6, 15, 5, 'l')
        q.line(5, 11, 5, 20, 's')
        q.poly([(8, 11), (16, 10), (18, 12), (17, 15), (8, 15), (6, 13)], 'd')
        q.line(8, 11, 15, 10, 'l')
        q.rect(11, 13, 3, 3, 'u')
        q.rect(12, 13, 1, 2, 's')
        q.poly([(7, 17), (16, 16), (18, 18), (18, 22), (7, 22)], 'u')
        q.poly([(7, 17), (15, 16), (17, 18), (17, 21), (7, 21)], 'b')
        q.line(8, 17, 15, 16, 's')
        q.dot(15, 18, 'i')
        q.rect(20, 17, 4, 6, 'u')
        q.line(20, 17, 23, 17, 's')
        q.line(20, 18, 20, 21, 'b')
    _details(q, kind, pulse)
    return True


def _details(q, kind, pulse):
    """Sparse functional inlays, never floating badges or extra outlines."""
    if kind == 'crt':
        # Agent eyes in a window, rather than a generic success tick.
        q.rect(8, 11, 8, 5, 'u')
        q.line(8, 11, 15, 11, 's')
        q.dot(10, 13, pulse); q.dot(14, 13, pulse)
        q.line(11, 15, 13, 15, 's' if q.on else 'd')
        q.line(22, 10, 24, 9, 'n')
        q.line(22, 13, 24, 12, 'n')
    elif kind == 'status':
        # Two agent rows: active dot and waiting hollow/dim dot.
        q.rect(7, 11, 11, 6, 'n')
        q.dot(8, 12, pulse); q.line(10, 12, 16, 12, 's')
        q.dot(8, 15, 'l' if q.on else 'd')
        q.line(10, 15, 14, 15, 'b')
        q.dot(17, 20, pulse)
    elif kind == 'robot':
        # Task-completion check on the chest and jaw grille.
        q.rect(10, 19, 6, 3, 'u')
        q.line(11, 20, 12, 21, pulse)
        q.line(12, 21, 15, 19, pulse)
        q.dot(11, 15, 's'); q.dot(14, 15, 's')
        q.dot(5, 21, 'n'); q.dot(23, 20, 'n')
    elif kind == 'bell':
        # Approval/attention engraving recessed into the cast skirt.
        q.rect(14, 11, 3, 7, 'u')
        q.line(15, 12, 15, 14, pulse); q.dot(15, 16, pulse)
        q.line(19, 11, 20, 17, 'u')
    elif kind == 'lamp':
        # Broad lit reflector, dark when disabled; fixed metal shade.
        q.line(6, 11, 14, 10, 'i' if q.on else 'u')
        q.line(7, 12, 13, 11, 'l' if q.on else 'd')
        q.rect(8, 22, 4, 2, 'u'); q.dot(9, 22, pulse)
        q.dot(17, 14, 'n')
    elif kind == 'reset':
        # Clock ticks and an actual minute hand inside the reset loop.
        q.dot(12, 10, 's'); q.dot(18, 15, 's'); q.dot(12, 20, 'b')
        q.line(13, 15, 13, 12, 'l' if q.on else 'b')
        q.line(13, 15, 15, 16, 's')
        q.dot(13, 15, 'i' if q.on else 's')
        q.line(19, 10, 20, 14, 'u')
    elif kind == 'key':
        # Caps Lock has a bar beneath the arrow and a dedicated inset LED.
        q.line(12, 13, 16, 12, 'u')
        q.line(13, 13, 16, 12, 'b')
        q.rect(5, 15, 3, 2, 'u'); q.dot(6, 15, pulse)
        q.line(12, 21, 21, 18, 'u')
    elif kind == 'keyboard':
        # Recessed lock plate replaces a few central keys, not a loose badge.
        q.rect(12, 12, 5, 7, 'u')
        q.line(13, 12, 15, 12, 'l')
        q.dot(13, 13, 's'); q.dot(15, 13, 'd')
        q.rect(12, 14, 5, 4, 'b')
        q.line(12, 14, 16, 14, 's')
        q.dot(14, 15, pulse); q.dot(14, 16, 'n')
    elif kind == 'speaker':
        # A little musical-note inlay identifies lid-close confirmation audio.
        q.rect(20, 10, 3, 5, 'n')
        q.line(21, 11, 22, 10, pulse)
        q.line(21, 11, 21, 14, pulse); q.dot(20, 14, pulse)
        q.dot(8, 22, 's'); q.dot(16, 16, 'u')
    elif kind == 'mute':
        # The slash remains visible in both states; switch shows enablement.
        q.line(9, 12, 15, 19, 'n')
        q.line(10, 12, 16, 19, 'l' if q.on else 'b')
        q.dot(21, 16 if q.on else 18, pulse)
        q.line(7, 23, 13, 23, 'u')
    elif kind == 'lock':
        # Password dots on a sunken plate distinguish this from input locking.
        q.rect(7, 16, 10, 7, 'u')
        q.ellipse(10, 17, 4, 3, 'n'); q.rect(11, 19, 2, 2, 'n')
        for x in (8, 11, 14): q.dot(x, 22, pulse)
        q.line(20, 18, 22, 17, 'b')
    elif kind == 'bag':
        # Laptop sleeve seam and temperature-warning tag for an awake Mac.
        q.line(8, 9, 16, 8, 'u')
        q.rect(9, 18, 6, 3, 'u')
        q.line(11, 18, 11, 19, pulse); q.dot(11, 20, pulse)
        q.line(14, 18, 14, 20, 'b')
        q.line(21, 19, 23, 19, 'n')
