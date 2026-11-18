"""Blue inventory objects: power and session modules. No UI dependencies."""

def draw(s, kind):
    if kind == 'plug':
        s.shadow(5,25,18)
        # Molded cord, two metal pins and a thick right-receding plug housing.
        s.line(13,20,13,24,'d');s.line(13,24,22,24,'d');s.line(14,23,22,23,'s')
        s.poly([(8,3),(11,2),(11,9),(8,10)],'s');s.line(8,3,10,3,'i');s.line(8,4,8,9,'l')
        s.poly([(16,4),(19,3),(19,11),(16,12)],'d');s.line(16,4,18,4,'l');s.line(16,5,16,10,'s')
        s.block(5,8,17,13,3)
        s.poly([(8,13),(11,13),(10,16),(13,16),(9,20),(10,17),(7,17)],'l')
        s.light(9,14);s.line(19,13,19,18,'u');s.line(21,12,21,17,'b')
    elif kind == 'server':
        s.shadow(4,25,20)
        s.block(5,2,17,22,4)
        # Recessed removable trays follow the case's perspective.
        for y in (7,12,17):
            s.poly([(7,y),(16,y+1),(16,y+4),(7,y+3)],'u')
            s.line(8,y,15,y+1,'s');s.line(8,y+2,12,y+2,'n')
            s.light(14,y+2)
        s.rect(7,22,3,2,'d');s.rect(15,23,3,1,'n')
        for y in range(8,21,3):s.line(19,y,20,y-1,'u')
        s.dot(8,4,'i');s.line(9,4,15,5,'l')
    elif kind in ('leafbattery','battery'):
        s.shadow(3,25,22)
        s.poly([(22,11),(25,10),(25,16),(22,17)],'d');s.line(23,11,24,11,'l')
        s.block(2,8,21,15,3)
        s.poly([(5,12),(17,13),(17,20),(5,19)],'u')
        s.line(5,12,17,13,'d');s.line(5,13,5,18,'n')
        for i in range(3):
            x=7+i*3
            s.poly([(x,14),(x+1,14),(x+1,18),(x,18)],'l' if s.on else 'b')
            s.dot(x,14,'i' if s.on and i==0 else 's')
        if kind=='leafbattery':
            s.poly([(12,8),(13,5),(18,2),(20,2),(19,6),(16,9)],'d')
            s.poly([(12,8),(14,5),(19,3),(17,7)],'s');s.line(12,9,18,4,'l')
        else:
            # Budget dial built into the upper face rather than floating UI.
            s.line(7,10,15,11,'l');s.rect(12,10,3,1,'d');s.light(13,10)
        s.line(20,14,20,20,'b');s.dot(3,10,'i')
    elif kind=='cup':
        s.shadow(4,25,21)
        # Handle is drawn first so the ceramic body correctly occludes it.
        s.poly([(19,11),(24,12),(25,14),(25,19),(22,22),(18,21)],'d')
        s.poly([(20,13),(23,14),(23,18),(21,20),(20,19)],None)
        s.line(22,12,24,14,'s');s.line(24,14,24,18,'b')
        s.poly([(5,10),(20,11),(20,22),(17,24),(8,23),(5,21)],'b')
        s.poly([(18,11),(21,10),(21,21),(18,24),(18,15)],'d')
        s.rect(6,12,2,9,'s');s.line(6,12,6,20,'l');s.line(8,22,16,23,'s')
        s.ellipse(5,7,17,7,'s');s.ellipse(7,8,13,4,'n');s.line(8,8,17,8,'l')
        s.line(8,11,18,12,'l');s.dot(6,9,'i')
        # An embossed diamond, not a pasted symbol or detached sparkle.
        s.poly([(12,15),(15,18),(12,21),(10,18)],'s');s.light(12,17,1,2)
        for x in (10,16):
            s.line(x,7,x-1,5,'d');s.line(x-1,5,x,3,'s')
            if s.on:s.light(x-1,5)
    elif kind=='moon':
        s.shadow(6,25,17)
        s.block(7,21,15,3,3);s.rect(13,17,3,5,'d');s.line(13,18,13,21,'s')
        # A solid crescent nightlight with a visible shaded rear edge.
        s.poly([(16,2),(11,3),(7,6),(5,10),(5,14),(8,18),(13,20),(18,19),(21,16),(16,16),(12,13),(11,9),(13,5)],'d')
        s.poly([(15,2),(10,4),(7,7),(6,11),(7,15),(10,18),(15,19),(19,17),(15,16),(11,13),(10,9),(12,5)],'s')
        s.line(10,4,7,8,'l');s.line(7,9,7,13,'l');s.line(8,15,10,17,'l')
        s.dot(10,5,'i');s.dot(9,11,'b');s.rect(10,14,2,1,'b');s.light(14,18)
    elif kind=='laptop':
        s.shadow(2,25,24)
        # Display housing, right side and slanted keyboard deck share one projection.
        s.poly([(4,5),(8,3),(23,6),(22,19),(19,21),(4,17)],'d')
        s.poly([(4,5),(19,8),(19,20),(4,17)],'b')
        s.line(4,5,8,3,'l');s.line(8,3,23,6,'s');s.line(4,6,4,16,'l')
        s.poly([(6,7),(17,9),(17,17),(6,15)],'n')
        s.line(7,8,16,10,'u');s.line(7,14,16,16,'u')
        s.glyph(10,10,['..#..','..#..','.....','.###.','#...#','.###.'],'l' if s.on else 'd')
        s.light(11,10)
        s.poly([(4,18),(19,21),(24,23),(8,25),(2,22)],'s')
        s.poly([(2,22),(8,25),(24,23),(24,24),(8,26),(2,23)],'d')
        s.line(3,21,8,24,'l');s.line(8,24,23,22,'l')
        for y in (20,22):s.line(7,y,15,y+1,'b')
        s.poly([(15,22),(18,22),(20,23),(16,24)],'b')
    elif kind=='download':
        s.shadow(3,25,22)
        # A chunky backup cartridge with an inset download engraving.
        s.block(4,4,20,20,4)
        s.poly([(7,8),(17,9),(17,18),(7,17)],'u')
        s.line(8,8,16,9,'d');s.line(7,9,7,16,'n')
        s.glyph(9,10,['..##..','..##..','..##..','######','.####.','..##..'],'l' if s.on else 'b')
        s.light(11,11,1,2)
        s.line(7,21,15,22,'n');s.line(7,20,15,21,'s');s.light(17,21)
        for y in (11,15,19):s.line(21,y,22,y-1,'u')
    elif kind=='cloud':
        s.shadow(3,25,22)
        # Idle mode: a resting computer/pillow-shaped dock, with layered cloth
        # folds and a small recessed moon light rather than a floating Z glyph.
        s.poly([(4,13),(8,10),(20,12),(24,16),(23,22),(18,24),(5,22),(3,18)],'d')
        s.poly([(4,13),(8,11),(20,13),(22,16),(19,21),(6,19)],'s')
        s.poly([(6,15),(10,13),(19,14),(20,17),(17,20),(7,18)],'b')
        s.line(5,14,6,18,'l');s.line(7,12,11,12,'l')
        s.line(5,21,17,23,'b');s.line(7,20,18,22,'s')
        s.line(9,16,11,16,'u');s.line(15,17,17,17,'u')
        s.poly([(16,7),(13,7),(11,9),(11,11),(13,13),(16,13),(14,11),(14,9)],'s')
        s.dot(12,9,'l');s.light(12,10)
    elif kind=='hourglass':
        s.shadow(4,25,21)
        # Faceted glass with a turned, perspective cap. Similar craft to
        # Short Sessions, but a newly drawn silhouette and sand reservoir.
        s.poly([(5,3),(9,1),(23,3),(20,6),(5,5)],'s');s.line(6,3,9,2,'i');s.line(9,2,22,4,'l')
        s.poly([(5,5),(20,6),(22,5),(22,7),(20,8),(6,7)],'d')
        s.line(7,7,7,23,'l');s.line(8,8,8,22,'s');s.line(20,8,20,23,'d')
        s.line(10,8,13,13,'l');s.line(18,9,15,14,'d')
        s.line(13,15,10,21,'s');s.line(15,15,18,22,'d')
        s.poly([(10,9),(18,10),(16,13),(14,14),(12,12)],'s')
        s.line(11,10,17,11,'l');s.rect(14,14,1,6,'s');s.light(14,16)
        s.poly([(10,22),(12,20),(15,19),(18,22)],'b');s.line(12,21,16,21,'s');s.dot(14,20,'l')
        s.poly([(5,23),(9,21),(22,23),(20,25),(5,24)],'s');s.line(5,23,19,24,'l');s.line(6,25,20,25,'d')
    elif kind=='fan':
        s.shadow(3,25,22)
        s.block(3,3,22,21,4)
        s.poly([(6,8),(17,9),(19,11),(19,19),(16,22),(7,20),(5,17),(5,11)],'n')
        s.poly([(7,9),(15,9),(18,12),(17,19),(14,21),(7,19),(6,15)],'u')
        # Curved impeller lobes, with the same opaque backing in both frames.
        if s.hover and s.frame:
            blades=[[(11,10),(14,11),(14,14),(11,13)],[(16,12),(18,15),(15,17),(14,14)],[(13,16),(14,19),(10,19),(11,15)],[(8,12),(11,13),(11,16),(7,15)]]
        else:
            blades=[[(11,9),(15,10),(14,14),(11,13)],[(15,13),(18,14),(17,18),(13,16)],[(11,15),(14,16),(12,20),(9,18)],[(7,11),(11,12),(12,15),(8,15)]]
        for blade in blades:s.poly(blade,'s' if s.on else 'b')
        s.ellipse(11,13,5,5,'l');s.ellipse(12,14,3,3,'d');s.light(12,14)
        for x,y in ((5,6),(19,9),(5,19),(19,22)):
            s.dot(x,y,'l');s.dot(x+1,y,'u')
        for y in (11,15,19):s.line(22,y,23,y-1,'u')
    else:
        return False
    _details(s, kind)
    return True


def _details(s, kind):
    """Mechanical seams and one readable functional accent per object."""
    lit = 'i' if s.on and not s.frame else 's' if s.on else 'b'
    if kind == 'plug':
        # Grip ribs and a seated strain relief, with an inset power lamp.
        s.line(7, 12, 7, 17, 's')
        s.line(16, 14, 16, 19, 'u')
        s.line(18, 14, 18, 18, 'u')
        s.rect(12, 20, 4, 2, 'u'); s.line(13, 20, 14, 20, 'b')
        s.dot(9, 14, lit)
    elif kind == 'server':
        # A house stamped into the header makes the server explicitly domestic.
        s.poly([(9, 6), (11, 4), (14, 6)], 'u')
        s.rect(10, 6, 3, 2, 'u'); s.dot(11, 6, lit)
        for y in (10, 15, 20):
            s.dot(8, y, 's'); s.line(10, y, 12, y, 'n')
        s.rect(16, 22, 2, 1, lit)
    elif kind in ('leafbattery', 'battery'):
        # Positive terminal and casing seam distinguish a battery from a crate.
        s.line(23, 12, 23, 14, 's'); s.line(22, 13, 24, 13, 's')
        s.line(4, 21, 16, 22, 'd')
        if kind == 'leafbattery':
            s.line(14, 7, 17, 6, 'b')
            s.line(15, 5, 16, 6, 'l')
            s.line(18, 4, 18, 5, 'l')
            # Reduced-load bars, not a flashing or depleted battery.
            for x in (7, 10, 13):
                s.line(x, 15, x, 18, 's' if s.on else 'b')
                s.dot(x, 14, 'l' if s.on else 's')
        else:
            # A hard budget stop: one allowed segment, two recessed segments.
            for x in (7, 10, 13):
                s.rect(x, 14, 2, 5, lit if x == 7 else 'd')
            s.line(9, 13, 9, 19, 'n')
            s.dot(9, 13, 'l'); s.line(6, 10, 10, 10, 's')
    elif kind == 'cup':
        # Coffee meniscus and a stable, state-lit steam groove.
        s.line(9, 9, 17, 9, 'd'); s.line(11, 10, 18, 10, 'u')
        s.line(7, 13, 7, 19, 'l')
        s.line(10, 4, 10, 6, lit); s.line(16, 4, 16, 6, lit)
        s.line(11, 18, 12, 19, lit); s.line(12, 19, 14, 16, lit)
    elif kind == 'moon':
        # Battery-powered sleep: a tiny battery inset in the nightlight base.
        s.rect(10, 22, 8, 2, 'u'); s.rect(11, 22, 5, 1, 's')
        s.dot(17, 22, lit)
        s.rect(9, 9, 2, 2, 'b'); s.dot(8, 13, 's')
        s.line(12, 17, 15, 18, 'l' if s.on else 'b')
    elif kind == 'laptop':
        # Enabled means the OPEN laptop stays OFF, not a glowing power glyph.
        s.poly([(6, 7), (17, 9), (17, 17), (6, 15)], 'n')
        s.line(7, 8, 15, 10, 'u')
        s.line(7, 9, 7, 13, 'd')
        # A subtle embossed power symbol stays unlit on the dark display.
        s.glyph(10, 10, ['..#..', '..#..', '.#.#.', '#...#', '.###.'], 'd')
        s.line(5, 18, 16, 20, 'u'); s.dot(20, 22, lit)
        s.line(10, 25, 20, 24, 'b')
    elif kind == 'download':
        # Transfer ends in a physical tray; lower progress track has a stop.
        s.line(8, 18, 8, 19, 's'); s.line(8, 19, 16, 20, 's')
        s.line(16, 20, 16, 19, 's')
        s.line(8, 21, 14, 22, 'n')
        s.line(8, 21, 11 if s.frame else 13, 22, lit)
        s.dot(15, 22, 'u'); s.dot(17, 21, lit)
    elif kind == 'cloud':
        # A CLOSED laptop resting idle: hinge, lid seam and sleeping status.
        # Replaces pillow folds with a crisp metal deck, retaining the outline.
        s.poly([(4, 13), (8, 11), (20, 13), (22, 16), (19, 21), (6, 19)], 's')
        s.line(8, 12, 19, 14, 'l')
        s.line(5, 16, 7, 19, 'l')
        s.line(7, 19, 19, 21, 'u')
        s.line(19, 21, 22, 17, 'n')
        s.line(8, 20, 17, 22, 'b')
        s.line(7, 21, 10, 21, 'n')
        s.dot(18, 22, lit)
        s.poly([(13, 14), (11, 15), (12, 17), (15, 18), (14, 16)], 'b')
    elif kind == 'hourglass':
        # Glass edge reflections, a narrow sand stream and music-fade engraving.
        s.dot(10, 12, 'i'); s.dot(17, 18, 's')
        s.line(14, 14, 14, 18, lit)
        s.line(21, 14, 21, 18, 'u')
        s.line(21, 14, 23, 14, 's')
        s.dot(20, 18, 's'); s.dot(23, 17, 'b')
        s.line(6, 24, 9, 24, 'i')
    elif kind == 'fan':
        # Stationary safety grille, bearing rim, and speed bars on the case.
        s.line(7, 11, 17, 19, 'd')
        s.line(7, 18, 17, 11, 'd')
        s.ellipse(11, 13, 5, 5, 's')
        s.ellipse(12, 14, 3, 3, 'u'); s.dot(12, 14, lit)
        for x, h in ((7, 1), (10, 2), (13, 3)):
            s.rect(x, 23 - h, 1, h, 'l' if s.on else 'd')
