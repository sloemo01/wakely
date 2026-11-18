#!/usr/bin/env python3
"""Detailed inventory sprites inspired by the three custom module references.

Artwork only: native 28px canvas / existing 2x UI renderer. No UI changes,
resampling, antialiasing, detached particles or whole-sprite hover movement.
All source geometry is integer-addressed and the palette is eight blue tones.
"""
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parent
DEST = ROOT / 'Resources' / 'Sprites'
IDS = {
    'agentScreen': 'crt', 'agentStatus': 'status', 'finishWorkThenSleep': 'robot',
    'agentNotifications': 'bell', 'agentLight': 'lamp', 'sleepUntilReset': 'reset',
    'capsLock': 'key', 'cleaningLock': 'keyboard', 'lidCloseSound': 'speaker',
    'quietClose': 'mute', 'passwordAfterClose': 'lock', 'bagCheck': 'bag',
    'alwaysOnPluggedIn': 'plug', 'homeServer': 'server', 'lowPowerWhileClosed': 'leafbattery',
    'batteryBudget': 'battery', 'keepAwake': 'cup', 'sleepMeansSleep': 'moon',
    'stayOffWhenOpened': 'laptop', 'finishJobsThenSleep': 'download', 'sleepWhenIdle': 'cloud',
    'sleepTimer': 'hourglass', 'fanBoost': 'fan', 'ejectOnSleep': 'eject',
    'bluetoothOffWhileClosed': 'bluetooth', 'awakeWhileConnected': 'terminal',
    'lidShortcuts': 'shortcut', 'armWhileAppRuns': 'app', 'armOnWiFi': 'wifi',
    'armOnSchedule': 'calendar', 'armWhenDriveConnects': 'drive',
}
# n/u = contact and occlusion; d/b = shaded wall and body; s/l = lit face
# and bevel; i/w = rare specular points. Same vocabulary as icon.txt.
# Authored material ramps. Base filenames are the dark appearance; the light
# appearance is generated as explicit -light assets so runtime never hue-shifts
# or colour-multiplies a sprite. Same tone vocabulary, different tonal separation.
PALETTES = {
    'dark': {
        True: {'n':'#2a1b05','u':'#4a2e06','d':'#70470a','b':'#b9820f',
               's':'#e3af24','l':'#f7d66a','i':'#fff0b3','w':'#fff9dc'},
        False: {'n':'#1e1912','u':'#30271a','d':'#4c3c23','b':'#715a32',
                's':'#998146','l':'#bfa461','i':'#d8c189','w':'#e8d9ae'},
    },
    'light': {
        True: {'n':'#3a2404','u':'#563706','d':'#7b4f08','b':'#a86f06',
               's':'#c98f10','l':'#e7b52f','i':'#f8d975','w':'#fff0b8'},
        False: {'n':'#3d3528','u':'#564b36','d':'#746446','b':'#8f7a50',
                's':'#ad9562','l':'#c6b17f','i':'#dccb9f','w':'#ead dbb'.replace(' ','')},
    },
}
HOVER_LIFTS = {
    'dark': {
        True: {'d':'#88570b','b':'#ce9616','s':'#efbf3c','l':'#ffe58a'},
        False: {'d':'#5c4a2b','b':'#826b3e','s':'#aa9259','l':'#d2bc84'},
    },
    'light': {
        True: {'d':'#8b5b09','b':'#bd810b','s':'#dda81c','l':'#f3cc55'},
        False: {'d':'#806f4f','b':'#9d8759','s':'#bba36d','l':'#d4c091'},
    },
}

class Sprite:
    def __init__(self, on, hover, frame, appearance='dark'):
        self.p = [[None] * 28 for _ in range(28)]
        self.on, self.hover, self.frame = on, hover, frame
        if appearance not in PALETTES:
            raise ValueError(f'Unknown appearance {appearance}')
        self.appearance = appearance
        self.colors = dict(PALETTES[appearance][on])
        if hover:
            # Material catches a little more light; its silhouette never moves.
            self.colors.update(HOVER_LIFTS[appearance][on])

    def dot(self, x, y, c):
        if 0 <= x < 28 and 0 <= y < 28:
            if c is not None and c not in self.colors: raise ValueError(f'Unknown tone {c}')
            self.p[y][x] = c

    def rect(self, x, y, w, h, c):
        for yy in range(y, y + h):
            for xx in range(x, x + w): self.dot(xx, yy, c)

    def line(self, x, y, xx, yy, c):
        dx, dy = abs(xx-x), -abs(yy-y)
        sx, sy = (1 if x < xx else -1), (1 if y < yy else -1)
        error = dx + dy
        while True:
            self.dot(x, y, c)
            if x == xx and y == yy: break
            e = error * 2
            if e >= dy: error += dy; x += sx
            if e <= dx: error += dx; y += sy

    def poly(self, vertices, c):
        # Pixel-centre scan conversion; explicit Bresenham edges preserve steps.
        minx, maxx = min(x for x,y in vertices), max(x for x,y in vertices)
        miny, maxy = min(y for x,y in vertices), max(y for x,y in vertices)
        for y in range(miny, maxy+1):
            for x in range(minx, maxx+1):
                inside = False
                px, py = x+0.5, y+0.5
                for (ax,ay),(bx,by) in zip(vertices, vertices[1:]+vertices[:1]):
                    if (ay > py) != (by > py) and px < (bx-ax)*(py-ay)/(by-ay)+ax:
                        inside = not inside
                if inside: self.dot(x,y,c)
        for (x,y),(xx,yy) in zip(vertices, vertices[1:]+vertices[:1]): self.line(x,y,xx,yy,c)

    def ellipse(self, x, y, w, h, c):
        for yy in range(y, y+h):
            for xx in range(x, x+w):
                if ((2*(xx-x)+1-w)/w)**2 + ((2*(yy-y)+1-h)/h)**2 <= 1:
                    self.dot(xx,yy,c)

    def panel(self, x, y, w, h, fill='b'):
        self.rect(x+1,y,w-2,h,'d'); self.rect(x,y+1,w,h-2,'d')
        self.rect(x+1,y+1,w-2,h-2,fill)
        self.line(x+1,y,x+w-3,y,'l'); self.line(x,y+1,x,y+h-3,'s')
        self.line(x+1,y+h-1,x+w-2,y+h-1,'u')

    def block(self, x, y, w, h, depth=3):
        # Right-receding three-quarter object. Front, roof, wall and bevels
        # are independent solid planes, not one flat square with an outline.
        d=depth
        self.poly([(x,y+2),(x+w-d,y+4),(x+w-d,y+h),(x,y+h-2)],'b')
        self.poly([(x,y+2),(x+d,y),(x+w,y+2),(x+w-d,y+4)],'s')
        self.poly([(x+w-d,y+4),(x+w,y+2),(x+w,y+h-2),(x+w-d,y+h)],'d')
        self.line(x,y+2,x+d,y,'l'); self.line(x+d,y,x+w,y+2,'l')
        self.line(x,y+3,x,y+h-3,'l')
        self.line(x+1,y+3,x+w-d-1,y+5,'s')
        self.line(x,y+h-2,x+w-d,y+h,'u')
        self.line(x+w-d,y+5,x+w-d,y+h-1,'u')

    def glyph(self, x, y, rows, c='i'):
        for yy,row in enumerate(rows):
            for xx,value in enumerate(row):
                if value != '.': self.dot(x+xx,y+yy,c)

    def light(self, x, y, w=1, h=1):
        tone = ('w' if self.hover and self.frame else 'i') if self.on else 's'
        self.rect(x,y,w,h,tone)

    def shadow(self, x=5, y=25, w=18):
        """No ground planes or cast shadows in module icons.

        Retain the authoring hook for existing artwork, but do not paint it.
        Physical feet, stands, case undersides and dark material seams remain.
        """
        pass

    def draw(self, kind):
        from sprite_art_devices import draw as devices
        from sprite_art_connections import draw as connections
        from sprite_art_power import draw as power
        from sprite_redesign_controls import draw as controls_redraw
        from sprite_redesign_power import draw as power_redraw
        from sprite_redesign_connections import draw as connections_redraw
        for draw in (controls_redraw, power_redraw, connections_redraw, devices, power, connections):
            if draw(self,kind): return
        raise ValueError(f'No artwork for {kind}')

    def animate_idle(self, kind, frame):
        """Eight authored samples on a fresh ON drawing; never move its shell.

        Physical policies that disable activity remain stationary. All edits are
        confined to real screen, lamp, steam, sand or impeller geometry; no
        palette-wide pulse, detached particles, or generic animation overlay.
        """
        if not self.on:
            return
        if not 0 <= frame < 8:
            raise ValueError('Idle frame must be in 0..7')
        before = [[cell is not None for cell in row] for row in self.p]
        from sprite_redesign_controls import animate as controls_motion
        from sprite_redesign_power import animate as power_motion
        from sprite_redesign_connections import animate as connections_motion
        for animate in (controls_motion, power_motion, connections_motion):
            if animate(self, kind, frame):
                if before != [[cell is not None for cell in row] for row in self.p]:
                    raise ValueError(f'{kind} redraw idle {frame} changed alpha silhouette')
                return
        # Slow breath for light sources; discrete clocks below have independent
        # object-specific timing. Eight files need not fake eight different poses.
        glow = ('i', 'i', 'l', 'l', 's', 'l', 'l', 'i')[frame]
        if kind in {'mute', 'bluetooth', 'laptop', 'lock', 'bag', 'shortcut',
                    'calendar', 'bell', 'speaker', 'reset', 'key', 'keyboard',
                    'plug', 'eject'}:
            # Quiet Close, disabled radio and powered-off laptop must not imply
            # sound, packets or a live screen. Passive hardware also rests.
            pass
        elif kind == 'fan':
            # Existing hover impeller phases, but no hover material on the case.
            rotor = Sprite(True, bool((frame // 2) % 2), (frame // 2) % 2)
            rotor.draw(kind)
            for y in range(9, 21):
                for x in range(6, 19):
                    if before[y][x] and rotor.p[y][x] is not None:
                        self.p[y][x] = rotor.p[y][x]
            # Repaint _details' stationary grille and bearing after the blades.
            self.line(7, 11, 17, 19, 'd')
            self.line(7, 18, 17, 11, 'd')
            self.ellipse(11, 13, 5, 5, 's')
            self.ellipse(12, 14, 3, 3, 'u'); self.dot(12, 14, 'i')
        elif kind == 'crt':
            # Single-pixel eyelids blink late in the cycle; mouth/header fixed.
            for x in (10, 14):
                self.dot(x, 13, 's' if frame == 6 else 'i')
            # A genuine underline cursor below the agent window.
            self.line(8, 16, 10, 16, 'l' if frame < 4 else 'n')
        elif kind == 'status':
            # Activity in the first agent row; waiting row stays dim and stable.
            self.dot(8, 12, ('i','l','s','l','i','i','s','s')[frame])
            self.dot(8, 15, 's')
        elif kind == 'robot':
            # Both eyes close inside their existing sockets. Completion check
            # stays untouched: this is a finished worker, not a changing task.
            for x in (8, 14):
                self.rect(x, 11, 3, 2, 'u')
                self.line(x, 12 if frame == 6 else 11,
                          x + 2, 12 if frame == 6 else 11, 'i')
        elif kind == 'lamp':
            self.line(6, 11, 14, 10, glow)
        elif kind == 'server':
            # Independent disk activity on the three existing tray LEDs.
            for index, y in enumerate((9, 14, 19)):
                self.dot(14, y, 'i' if (frame + index * 3) % 8 < 2 else 's')
        elif kind == 'leafbattery':
            # Reduced-load segments remain filled; a crown glint is not charge.
            for x in (7, 10, 13):
                self.dot(x, 14, 'l')
            self.dot((7, 10, 13, 13, 13, 10, 7, 7)[frame], 14, 'i')
        elif kind == 'battery':
            # Only the allowed budget segment catches light. Forbidden segments
            # remain dark in all frames and the charge level never changes.
            self.dot(7, 14, glow)
        elif kind == 'cup':
            # Two upward-moving heat highlights follow existing steam grooves.
            # Groove opacity is constant, so no detached puffs or alpha changes.
            for x in (10, 16):
                self.line(x, 4, x, 6, 's')
                self.dot(x, (6, 6, 5, 5, 4, 4, 5, 6)[frame], 'i')
        elif kind == 'moon':
            self.dot(17, 22, glow)
        elif kind == 'download':
            # Progress activity travels only along the existing recessed track,
            # never across the engraved download arrow or its physical stop.
            self.line(8, 21, 14, 22, 'n')
            track = ((8,21),(9,21),(10,21),(11,22),(12,22),(13,22),(14,22))
            for index, (x, y) in enumerate(track):
                self.dot(x, y, 'i' if index == frame % 7 else 's')
        elif kind == 'cloud':
            # Closed, resting laptop has only a slow sleep-status lamp.
            self.dot(18, 22, glow)
        elif kind == 'hourglass':
            # Reset the existing opaque sand column, then advance the granular
            # stream down it. No glass edges, reservoirs or silhouette move.
            self.line(14, 14, 14, 18, 'd')
            self.dot(14, 14, 's')
            for y in range(15, 19):
                self.dot(14, y, 'i' if (y - 15 - frame) % 4 == 0 else 's')
        elif kind == 'terminal':
            self.line(13, 14, 15, 14, 'i' if frame < 4 else 'n')
        elif kind == 'app':
            # Play indicator remains readable, with activity on its status LED.
            self.dot(18, 18, glow)
        elif kind == 'wifi':
            for index, x in enumerate((10, 13, 16)):
                self.dot(x, 21, 'i' if (frame + index * 2) % 8 < 3 else 's')
        elif kind == 'drive':
            # Disk activity LED only: platter, read head and cable stay fixed.
            self.dot(6, 22, 'i' if frame in (0, 1, 4) else 's')
        else:
            raise ValueError(f'No idle animation for {kind}')
        after = [[cell is not None for cell in row] for row in self.p]
        if before != after:
            raise ValueError(f'{kind} idle {frame} changed alpha silhouette; check artwork coordinates')

    def rgba(self):
        result=bytearray()
        for row in self.p:
            for key in row:
                if key is None: result.extend((0,0,0,0))
                else: result.extend((*bytes.fromhex(self.colors[key].lstrip('#')),255))
        return result


def png(path,width,height,rgba):
    def chunk(kind,data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    rows=b''.join(b'\0'+bytes(rgba[y*width*4:(y+1)*width*4]) for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(rows,9))+chunk(b'IEND',b''))


def paste(target,tw,rgba,w,h,x,y,scale=1):
    for yy in range(h):
        for xx in range(w):
            pixel=rgba[(yy*w+xx)*4:(yy*w+xx+1)*4]
            if pixel[3]:
                for dy in range(scale):
                    for dx in range(scale):
                        pos=((y+yy*scale+dy)*tw+x+xx*scale+dx)*4
                        target[pos:pos+4]=pixel


def main():
    DEST.mkdir(exist_ok=True)
    (ROOT/'build').mkdir(exist_ok=True)
    sw,sh=4*112,len(IDS)*72
    sheet=bytearray(bytes((24,26,32,255))*(sw*sh))
    # Compact gallery: 4 columns of ON artwork at exact 3x, separated by
    # ground baselines. Reference originals are drawn unchanged in top row.
    gw,gh=4*112,128+((len(IDS)+3)//4)*104
    gallery=bytearray(bytes((24,26,32,255))*(gw*gh))
    references=ROOT/'harvest/modules-kit/sdk/examples'
    reference_names=('desk-mode','night-render','short-sessions')
    if not all((references/name/'icon.txt').is_file() for name in reference_names):
        reference_names=()
    for col,reference in enumerate(reference_names):
        rows=(references/reference/'icon.txt').read_text().splitlines()
        pixels=bytearray()
        for row in rows:
            for letter in row:
                pixels.extend((0,0,0,0) if letter=='.' else (*bytes.fromhex(PALETTES['dark'][True][letter].lstrip('#')),255))
        paste(gallery,gw,pixels,32,32,col*112+8,12,3)
    # Subtle fixed divider: above = the untouched references; below = new art.
    for x in range(8,gw-8): gallery[(119*gw+x)*4:(119*gw+x+1)*4]=bytes((53,65,88,255))
    states=[('off',False,False,0),('on',True,False,0),('hover-off-0',False,True,0),('hover-on-0',True,True,0),('hover-off-1',False,True,1),('hover-on-1',True,True,1)]
    for row,(module,kind) in enumerate(IDS.items()):
        for appearance in ('dark', 'light'):
            suffix = '' if appearance == 'dark' else '-light'
            for col,(state,on,hover,frame) in enumerate(states):
                sprite=Sprite(on,hover,frame,appearance);sprite.draw(kind);rgba=sprite.rgba()
                png(DEST/f'{module}-{state}{suffix}.png',28,28,rgba)
                if appearance == 'dark' and col<4: paste(sheet,sw,rgba,28,28,col*112+28,row*72+8,2)
                if appearance == 'dark' and state=='on': paste(gallery,gw,rgba,28,28,(row%4)*112+14,128+(row//4)*104+8,3)
    # Separate idle family keeps all existing ON/OFF and hover filenames intact.
    # Draw the unanimated base first: artwork's hover conditionals must never
    # accidentally change static OFF assets or leak hover material into idle.
    idle_rows = []
    for module, kind in IDS.items():
        frames = []
        for frame in range(8):
            sprite = Sprite(True, False, 0)
            sprite.draw(kind)
            sprite.animate_idle(kind, frame)
            rgba = sprite.rgba()
            frames.append(bytes(rgba))
            png(DEST/f'{module}-idle-on-{frame}.png', 28, 28, rgba)
        for frame in range(8):
            sprite = Sprite(True, False, 0, 'light')
            sprite.draw(kind)
            sprite.animate_idle(kind, frame)
            png(DEST/f'{module}-idle-on-{frame}-light.png', 28, 28, sprite.rgba())
        if kind in {'fan', 'crt', 'status', 'cup', 'hourglass', 'terminal', 'server'} and len(set(frames)) < 2:
            raise ValueError(f'{module} is missing its authored idle motion')
        idle_rows.append((module, frames))
    # Pillow is optional; asset generation itself uses only the standard library.
    # Labels matter here: a reviewer can match every frame back to its module.
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print('Pillow unavailable; skipping labeled idle contact sheet.')
    else:
        preview = Image.new('RGBA', (210 + 8 * 64, 30 + len(IDS) * 64), (24, 26, 32, 255))
        labels = ImageDraw.Draw(preview)
        for frame in range(8):
            labels.text((210 + frame * 64, 8), f'Frame {frame}', fill=(191, 216, 255, 255))
        for row, (module, frames) in enumerate(idle_rows):
            y = 30 + row * 64
            labels.text((8, y + 23), module, fill=(191, 216, 255, 255))
            for frame, rgba in enumerate(frames):
                tile = Image.frombytes('RGBA', (28, 28), rgba)
                tile = tile.resize((56, 56), Image.Resampling.NEAREST)
                preview.alpha_composite(tile, (210 + frame * 64, y + 4))
        preview.save(ROOT/'build/idle-sprite-contact-sheet.png')
        animation = []
        for frame in range(8):
            overview = Image.new('RGB', (4 * 248, 34 + ((len(IDS) + 3) // 4) * 126), (24, 26, 32))
            caption = ImageDraw.Draw(overview)
            caption.text((12, 10), 'Authored idle ON / 5 fps / stationary silhouettes', fill=(191, 216, 255))
            for index, (module, frames) in enumerate(idle_rows):
                x, y = (index % 4) * 248, 34 + (index // 4) * 126
                caption.text((x + 8, y + 4), module, fill=(191, 216, 255))
                tile = Image.frombytes('RGBA', (28, 28), frames[frame])
                tile = tile.resize((84, 84), Image.Resampling.NEAREST)
                overview.paste(tile, (x + 82, y + 24), tile)
            animation.append(overview)
        animation[0].save(ROOT/'build/refined-sprites-preview.gif', save_all=True,
                          append_images=animation[1:], duration=200, loop=0, disposal=2)
    png(ROOT/'build/sprite-contact-sheet.png',sw,sh,sheet)
    png(ROOT/'build/blue-sprite-gallery.png',gw,gh,gallery)
    print(f'Generated {len(IDS)*28} golden sprite states for {len(IDS)} modules, split across explicit light/dark assets (8 idle + 6 legacy each).')
    print('Contact sheet columns: OFF / ON / OFF HOVER / ON HOVER. Gallery first row: untouched references.')

if __name__=='__main__':main()
