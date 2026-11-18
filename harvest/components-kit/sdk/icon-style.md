# Drawing the icon (icon.txt)

Wakely's component icons are hand-drawn pixel art, like item icons in a game: one object in solid tones, lit from the top left, on a dark background. Yours sits beside Wakely's own components in Settings > Components, so it follows the same rules.

## Format

- Exactly 32 lines of exactly 32 characters. One character per pixel.
- `.` is empty. Lines may start with a row number and a bar (`07|`); the checker removes them.
- Letters, darkest to brightest:

| Letter | Use |
| --- | --- |
| `n` | night: the deepest shadow, screens, the contact shadow |
| `u` | dusk: deep shadow, the contact shadow |
| `d` | deep: shaded sides, right and bottom edges |
| `b` | blue: the body color |
| `s` | sheen: soft lit faces |
| `l` | light: lit top and left edges |
| `i` | ice: bright highlights, the component's light |
| `w` | white: the few brightest glints only |

The letters are tones, not fixed colors. The preview draws them in blue; Wakely draws the same tones in its own palette, muted when the component is off and warm amber when it is on. Nothing else draws, and there are no other tones.

## Rules

1. One object that stands for what the component does (a clock, a film clapper, a plug), front or three-quarter view, filling about the middle 26 x 26 cells. Leave an empty column on each side and the top row empty, and keep the drawing within 29 rows.
2. Silhouette first: outline and fill the body with `b`, check that it reads as the object at card size, then shade it.
3. Light comes from the top left: top and left edges `l` or `s`; right and bottom edges `d`; deep shadow `u` or `n`. Use at least 5 tones.
4. `w` and `i` only on the few cells where light hits hardest or where the component's light is (a lamp, a screen, a spark): under 12% of the drawing. Those cells stay the brightest when Wakely shows the icon on.
5. Solid areas of one tone. Never a checkerboard or dither pattern across an area, and no stray single pixels except a few deliberate sparkles.
6. End with a contact shadow: the lowest line of the drawing is one row of `u` or `n` under the object, a little wider than it. The row may alternate `u` and `n` at its ends, as some of Wakely's do. It grounds the object on the card.
7. The icon fills 18% to 70% of the box.
8. Draw your own object. Study `sdk/reference-sprites/` for the style, then change the silhouette and the details; the checker warns when an icon matches one of Wakely's sprites.

Wakely's own icons sometimes let a spark or a wave reach the edge of the box; that is fine for an emission, not for the object.

Work by small edits: change a few cells, run `check` and `preview`, and compare with `sdk/reference-sprites/`. `check` prints the icon's fill, tone count and bright share so you can see the numbers. Three rounds is usually enough.
