"""Selected power-policy redesigns, authored at native 28px resolution.

No charging animation: budget is a finite allowance with an immutable stop.
All animation is material-only inside existing opaque pixels.
"""
from sprite_mac_primitives import closed_mac, open_mac, moon, battery

# Sleep Means Sleep and Sleep When Idle intentionally use their previous art.
OWNED = frozenset({'leafbattery', 'battery', 'laptop', 'hourglass', 'eject'})
# Public semantic test anchors: the allowance cannot cross this stop or light
# the dark reserve. These coordinates are independent of state and animation.
BUDGET_STOP_X = 10
BUDGET_STOP_Y_RANGE = (11, 20)
BUDGET_RESERVE = (12, 11, 8, 9)  # x, y, width, height
BUDGET_ALLOWANCE = (5, 12, 4, 7)
TIMER_CENTER = (12, 13)


def _battery_shell(s):
    """Wide battery silhouette with a distinct terminal, bevel and inset meter."""
    # Terminal sits behind the right side of the cell, not a power plug.
    s.poly([(23,11),(26,10),(26,16),(23,18)], 'u')
    s.line(24,11,25,11,'s'); s.line(25,12,25,15,'b')
    # Thin three-quarter casing: top-left bevel and shaded right wall.
    s.poly([(2,9),(5,6),(23,7),(24,9),(24,20),(21,23),(2,21)], 'u')
    s.poly([(2,9),(5,6),(23,7),(21,10)], 's')
    s.poly([(21,10),(24,8),(24,20),(21,23)], 'd')
    s.rect(2,10,20,11,'b')
    s.line(3,9,20,10,'l'); s.line(3,10,3,19,'s')
    s.line(3,21,20,22,'d'); s.line(21,11,21,21,'u')
    s.line(6,7,21,8,'l'); s.dot(5,7,'i')
    # Recessed rectangular charge window, kept clean at 2x app display size.
    s.rect(4,11,17,9,'n')
    s.line(4,11,19,11,'u'); s.line(4,12,4,19,'u')
    s.line(5,20,19,20,'s')
    s.dot(22,10,'s'); s.dot(22,20,'b')


def draw(s, kind):
    if kind not in OWNED:
        return False
    if kind in ('leafbattery', 'battery'):
        _battery_shell(s)
        if kind == 'leafbattery':
            # A real battery first: two restrained charge segments and an eco
            # leaf INSIDE its display, never a laptop or separate ground object.
            for x in (5, 8):
                s.rect(x, 12, 2, 7, 's' if s.on else 'b')
                s.line(x, 12, x + 1, 12, 'l' if s.on else 's')
                s.dot(x, 18, 'b')
            s.poly([(13,17),(13,14),(15,12),(19,11),(19,15),(17,18),(14,18)], 's')
            s.line(13,18,18,13,'l')
            s.line(15,16,15,14,'b'); s.line(16,15,18,15,'b')
            s.dot(18,12,'l')
        else:
            # Finite allocation, not current charge: one allowed area stops at
            # the bright divider. Dark reserve never fills or pulses.
            s.rect(*BUDGET_ALLOWANCE, 's' if s.on else 'b')
            s.line(5,12,8,12,'l'); s.line(5,18,8,18,'b')
            start, end = BUDGET_STOP_Y_RANGE
            s.line(BUDGET_STOP_X,start,BUDGET_STOP_X,end-1,'l')
            for x in (12,15,18):
                s.rect(x,12,1,7,'u')
            # Engraved limit cursor in the casing aligns with the hard stop.
            s.rect(9,8,3,2,'u'); s.dot(10,8,'l')
    elif kind == 'moon':
        # Sleep protection shield above the sleeping closed machine.
        closed_mac(s, 2, 19, 23, 6)
        s.poly([(7,3),(13,2),(21,4),(20,12),(14,17),(8,12)],'u')
        s.poly([(8,4),(13,3),(20,5),(19,11),(14,15),(9,11)],'b')
        s.line(8,4,13,3,'l'); s.line(13,3,19,5,'s')
        moon(s,11,6,'l')
        # Shield rim is the blocked-wake cue, without lively rays or a lamp.
        s.line(9,12,14,16,'d'); s.dot(9,4,'i')
    elif kind == 'laptop':
        open_mac(s)
        # Glass stays dark. Large unlit power control etched into the display.
        s.ellipse(10,8,8,7,'d')
        s.ellipse(11,9,6,5,'n')
        s.rect(12,7,4,4,'n')
        s.line(14,8,14,11,'b')
        s.dot(5,6,'i')
    elif kind == 'cloud':
        closed_mac(s, 2, 18, 23, 7)
        # Flat activity baseline terminates in a sleep crescent, not a cloud.
        s.panel(3,3,22,12,'u')
        s.line(5,5,5,12,'d'); s.line(5,12,21,12,'d')
        s.line(6,9,16,9,'l')
        s.dot(9,9,'i')
        moon(s,18,5,'s')
        s.line(7,6,7,7,'b'); s.line(11,6,11,7,'b')
    elif kind == 'hourglass':
        # Thirty-minute timer dial; the long hand points down at half an hour.
        s.ellipse(2,2,22,23,'u')
        s.ellipse(3,2,20,21,'s')
        s.ellipse(5,4,16,17,'b')
        s.ellipse(6,5,14,15,'n')
        for x,y in ((12,5),(19,12),(12,19),(6,12)):
            s.dot(x,y,'l')
        s.line(12,12,12,18,'l'); s.line(12,12,9,10,'s')
        s.rect(11,11,3,3,'d'); s.dot(12,12,'i')
        s.line(8,3,15,3,'l')
        # Sleep endpoint nested on the dial, not another detached object.
        moon(s,16,17,'l')
    elif kind == 'eject':
        # Pocket external SSD: solid slab and USB socket, never optical media.
        s.poly([(5,5),(20,3),(24,6),(24,21),(9,24),(5,21)],'u')
        s.poly([(5,5),(20,3),(24,6),(9,9)],'s')
        s.poly([(5,5),(9,9),(9,24),(5,21)],'d')
        s.poly([(9,9),(24,6),(24,21),(9,24)],'b')
        s.line(6,5,19,3,'l'); s.line(10,9,23,6,'l')
        # Standard eject triangle over a separate horizontal bar.
        s.poly([(16,10),(12,16),(20,16)],'l')
        s.rect(12,18,9,2,'s')
        s.line(13,18,19,18,'l')
        s.line(6,13,6,17,'n')
        # Small lid/sleep cue belongs to the drive's top face.
        s.line(11,5,16,5,'u'); s.line(11,6,16,6,'d')
        s.dot(21,21,'i')
    return True


def animate(s, kind, frame):
    """Owned policies rest; only the timer's inset bearing slowly catches light.

    No budget fill cycling, wake pulses, screen light, or silhouette movement.
    Passive owned kinds still return True so callers do not animate old artwork.
    """
    if kind not in OWNED:
        return False
    if kind == 'hourglass' and s.on:
        s.dot(*TIMER_CENTER, 'i' if (frame // 4) % 2 == 0 else 'l')
    return True
