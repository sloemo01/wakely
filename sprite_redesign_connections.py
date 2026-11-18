"""Mac-specific redraws: lid radio cutoff, Shortcuts, app hold, USB drive hold."""
from sprite_mac_primitives import closed_mac, open_mac, disk

# Arm When a Drive Connects intentionally uses its previous artwork/motion.
KINDS = {'bluetooth', 'shortcut', 'app'}


def draw(s, kind):
    if kind not in KINDS:
        return False
    lit = 'l' if s.on else 'b'
    s.shadow(3, 25, 22)
    if kind == 'bluetooth':
        # Closed aluminum Mac below a recognizable radio tile. Its slash is a
        # cutoff policy, not a receiver with apparently working activity lights.
        closed_mac(s, 3, 18, 21, 6)
        s.panel(8, 2, 13, 16, 'b')
        s.rect(10, 4, 9, 12, 'u')
        s.line(14, 4, 14, 15, 's')
        s.line(14, 4, 18, 8, 's'); s.line(18, 8, 11, 13, 's')
        s.line(14, 15, 18, 11, 's'); s.line(18, 11, 11, 6, 's')
        # Dark separation under a strong diagonal makes the disabled rune read.
        s.line(9, 14, 19, 5, 'n'); s.line(10, 15, 20, 6, lit)
        s.line(10, 16, 19, 8, lit)
        s.line(9, 19, 19, 21, 'b')
        s.dot(5, 22, 'd')
    elif kind == 'shortcut':
        # A lid event feeds the actual Shortcuts two interlocking ribbon marks.
        # The lower left silhouette is a partly closing Mac, not two key cubes.
        s.poly([(3, 11),(12, 8),(15, 17),(6, 20),(3, 18)], 'd')
        s.poly([(3, 11),(11, 9),(13, 16),(5, 18)], 'b')
        s.line(4, 11, 10, 9, 'l'); s.line(4, 12, 5, 16, 's')
        closed_mac(s, 2, 19, 21, 5)
        # Lid-to-automation event trace, deliberately fixed, not a light show.
        s.line(11, 17, 16, 17, 'u'); s.line(16, 17, 16, 14, 'u')
        s.dot(11, 17, lit); s.line(15, 15, 16, 14, 's')
        # Chunky rounded-diamond ribbons, dark overlap underneath lighter top.
        s.poly([(18, 6),(25, 10),(25, 12),(19, 16),(12, 12),(12, 10)], 'u')
        s.poly([(18, 6),(25, 10),(19, 14),(12, 10)], 's')
        s.poly([(18, 8),(21, 10),(18, 12),(15, 10)], 'u')
        s.line(13, 10, 18, 7, 'l'); s.line(19, 13, 24, 10, 'b')
        s.poly([(18, 1),(25, 5),(25, 7),(19, 11),(12, 7),(12, 5)], 'd')
        s.poly([(18, 1),(25, 5),(19, 9),(12, 5)], 'b')
        s.poly([(18, 3),(21, 5),(18, 7),(15, 5)], 'u')
        s.line(13, 5, 18, 2, lit); s.line(19, 8, 24, 5, 's')
    elif kind == 'app':
        # A macOS application running on a thin laptop, with traffic-light title
        # bar, one window, and an explicit running-state dot in the Dock.
        open_mac(s)
        s.rect(7, 7, 12, 8, 'd')
        s.line(7, 7, 18, 7, 's')
        for x in (8, 10, 12): s.dot(x, 8, 'l' if x == 8 else 'b')
        s.rect(8, 10, 10, 4, 'u')
        s.panel(10, 10, 5, 4, 'b')
        s.poly([(12, 11),(14, 12),(12, 13)], lit)
        # Dock running marker is separate from the play mark, not disk activity.
        s.line(9, 16, 18, 16, 'd'); s.dot(13, 16, lit)
    else:
        # External modern backup SSD physically cabled to a closed Mac. This is
        # a CONNECTED volume hold, unlike the separate eject-on-sleep module.
        closed_mac(s, 2, 6, 20, 6)
        s.line(4, 11, 4, 18, 'u'); s.line(4, 18, 12, 18, 'u')
        s.line(5, 12, 5, 17, 's'); s.line(5, 17, 12, 17, 's')
        s.rect(11, 16, 4, 3, 'd'); s.line(12, 16, 14, 16, 'l')
        disk(s, 14, 12)
        s.rect(16, 17, 4, 5, 'u')
        s.line(17, 18, 19, 18, 's'); s.line(17, 20, 19, 20, 'b')
        # Mounted-volume lamp, not an exposed spinning platter.
        s.dot(19, 22, lit)
        s.line(8, 8, 14, 9, 'b')
    return True


def animate(s, kind, frame):
    if kind not in KINDS:
        return False
    if s.on and kind == 'app':
        # Gentle running marker; the application and play mark remain readable.
        s.dot(13, 16, ('l','l','s','s','b','s','s','l')[frame])
    if s.on and kind == 'drive':
        # Steady mounted indicator with a restrained periodic heartbeat.
        s.dot(19, 22, 'l' if frame in (0, 1, 2, 7) else 's')
    return True
