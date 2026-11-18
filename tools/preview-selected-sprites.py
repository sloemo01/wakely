#!/usr/bin/env python3
"""Labeled selected-sprite proof; optionally use native-rendered warm PNGs."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
SELECTED = [
    ('finishWorkThenSleep','Finish Work, Then Sleep','Agent tasks complete → Mac sleeps'),
    ('capsLock','Caps Lock','Mac keycap · correct legend · LED'),
    ('cleaningLock','Cleaning Lock','Mac keyboard · cloth · input lock'),
    ('quietClose','Quiet Close','Lid closes → audio muted'),
    ('lidCloseSound','Lid-Close Sound','Lid closes → confirmation sound'),
    ('lowPowerWhileClosed','Low Power While Closed','Standalone battery · low-power leaf'),
    ('batteryBudget','Battery Budget','Finite allowance · hard battery stop'),
    ('sleepMeansSleep','Sleep Means Sleep','Previous design restored'),
    ('stayOffWhenOpened','Stay Off When Opened','Open Mac · screen remains powered off'),
    ('sleepWhenIdle','Sleep When Idle','Previous design restored'),
    ('sleepTimer','Sleep Timer','Half-hour dial · sleep endpoint'),
    ('ejectOnSleep','Eject on Sleep','External SSD · standard eject mark'),
    ('bluetoothOffWhileClosed','Bluetooth Off While Closed','Closed Mac · Bluetooth cut off'),
    ('lidShortcuts','Lid Shortcuts','Lid event → Apple Shortcuts ribbons'),
    ('armWhileAppRuns','Arm While an App Runs','macOS app window · running marker'),
    ('armWhenDriveConnects','Arm When a Drive Connects','Previous design restored'),
]


def main():
    out = Image.new('RGB',(1200,1080),(24,26,32))
    d = ImageDraw.Draw(out)
    try:
        title = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',16)
        small = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',12)
    except OSError:
        title=small=ImageFont.load_default()
    warm = (ROOT/'build/native-sprite-preview/finishWorkThenSleep.png').exists()
    d.text((24,18),'WAKELY / 13 REDESIGNS + 3 RESTORED SPRITES',font=title,fill=(239,230,202))
    d.text((24,43),'Native app colors · enabled artwork' if warm else 'Source artwork palette · enabled artwork',font=small,fill=(155,161,172))
    for i,(component,name,hint) in enumerate(SELECTED):
        x,y=(i%4)*300,76+(i//4)*248
        d.rounded_rectangle((x+10,y,x+290,y+232),radius=12,fill=(31,33,39),outline=(48,51,61))
        d.text((x+22,y+16),name,font=title,fill=(232,233,238))
        d.text((x+22,y+43),hint,font=small,fill=(154,161,177))
        path=ROOT/'build/native-sprite-preview'/f'{component}.png' if warm else ROOT/'Resources/Sprites'/f'{component}-on.png'
        icon=Image.open(path).convert('RGBA').resize((140,140),Image.Resampling.NEAREST)
        out.paste(icon,(x+80,y+74),icon)
    out.save(ROOT/'build/selected-mac-sprites.png')
    print(ROOT/'build/selected-mac-sprites.png')

if __name__=='__main__': main()
