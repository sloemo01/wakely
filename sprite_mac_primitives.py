"""Shared 28px Mac hardware primitives for the selected module redesigns.

Integer geometry, solid aluminum planes, dark glass, restrained highlights.
Use one primary device and one large readable functional cue per sprite.
"""

def closed_mac(s, x=3, y=17, w=21, h=6):
    """Thin closed MacBook, three-quarter lid and front-edge separation."""
    s.poly([(x,y+2),(x+5,y),(x+w,y+3),(x+w-5,y+h),(x,y+h-2)],'d')
    s.poly([(x,y+2),(x+5,y),(x+w,y+3),(x+w-5,y+h-1),(x,y+h-3)],'s')
    s.line(x+1,y+2,x+5,y+1,'l'); s.line(x+5,y+1,x+w-2,y+3,'l')
    s.line(x,y+h-2,x+w-5,y+h,'u')
    s.line(x+w-5,y+h,x+w,y+3,'n')
    s.line(x+3,y+h-2,x+6,y+h-2,'n')
    s.line(x+8,y+h-1,x+11,y+h-1,'b')


def open_mac(s):
    """Recognizable thin laptop, not a CRT: full glass, hinge, keys, trackpad."""
    s.poly([(4,4),(21,4),(23,6),(23,18),(21,19),(4,17)],'u')
    s.rect(4,5,18,12,'b'); s.line(5,4,20,4,'l')
    s.rect(6,6,14,9,'n'); s.line(7,6,18,6,'u')
    s.dot(13,5,'d'); s.line(6,17,21,18,'d')
    s.poly([(4,18),(21,19),(25,23),(20,25),(2,23)],'s')
    s.poly([(2,23),(20,25),(25,23),(25,24),(20,26),(2,24)],'d')
    s.line(3,23,19,25,'l'); s.line(20,25,24,23,'b')
    s.line(6,19,19,20,'u'); s.line(7,20,20,21,'b')
    s.poly([(10,22),(15,22),(17,23),(11,23)],'b')
    s.dot(20,20,'n')


def moon(s,x,y,tone='l'):
    # Solid crescent stencil; no alpha erasure against the underlying device.
    s.glyph(x,y,['..###.','.##...','##....','##....','.##...','..####'],tone)


def check(s,x,y,tone='i'):
    s.line(x,y+2,x+2,y+4,tone); s.line(x+2,y+4,x+6,y,tone)


def battery(s,x,y,w=14,h=8):
    s.panel(x,y,w,h,'b'); s.rect(x+2,y+2,w-4,h-4,'n')
    s.rect(x+w,y+2,2,h-4,'d'); s.line(x+2,y+1,x+w-3,y+1,'s')


def disk(s,x=14,y=11):
    s.poly([(x,y+2),(x+3,y),(x+10,y+2),(x+10,y+10),(x+7,y+12),(x,y+10)],'u')
    s.poly([(x,y+2),(x+7,y+3),(x+7,y+12),(x,y+10)],'b')
    s.poly([(x,y+2),(x+3,y),(x+10,y+2),(x+7,y+3)],'s')
    s.line(x+1,y+2,x+6,y+3,'l'); s.line(x+1,y+3,x+1,y+9,'s')
    s.line(x+8,y+5,x+8,y+9,'n'); s.dot(x+5,y+10,'i' if s.on else 'b')
