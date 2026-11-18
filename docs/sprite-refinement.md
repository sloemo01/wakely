# Module sprite refinement

All 31 built-in modules retain a 28×28 source grid, solid pixel edges, fixed silhouettes, and the existing application color treatment. User-authored SDK icons are unchanged.

## Artwork

Functional details are inset into the objects: agent faces and activity rows, task completion, notification attention marks, a keyboard cleaning lock, password dots, bag warning tag, battery allowance, transfer progress, SSH prompt, router connections, selected schedule interval, and drive hardware.

The enabled state describes an enabled **policy**, not necessarily powered-on hardware. Stay Off When Opened deliberately keeps the laptop screen dark; Bluetooth Off While Closed dims the radio symbol; Battery Budget retains a limited allowance rather than appearing to charge. Sleep When Idle has a closed-laptop deck.

## Selected Mac-specific redraw

A second pass redrew the 16 modules listed below. At the user's request, Arm When a Drive Connects, Sleep Means Sleep, and Sleep When Idle were subsequently restored to their previous artwork and animation. The remaining 13 redraws are retained. A later correction makes both power/budget icons standalone battery cells and removes the ground/cast-shadow decoration from every built-in sprite. Other device details are preserved, including the three restored designs.

| Module | New visual language |
| --- | --- |
| Finish Work, Then Sleep | Thin MacBook, completed agent task, sleep crescent |
| Caps Lock | Low-profile Mac keycap, correct hollow arrow/bar legend, inset LED |
| Cleaning Lock | Thin keyboard with key rows, wiping cloth and input-lock mark |
| Quiet Close | Closed MacBook, large muted-speaker cross |
| Lid-Close Sound | Closed MacBook, confirmation sound arcs |
| Low Power While Closed | Standalone beveled battery, restrained segments and an inset eco leaf; no laptop underneath |
| Battery Budget | Standalone beveled battery, finite allowance, aligned limit cursor and immutable dark reserve |
| Sleep Means Sleep | Reverted to previous crescent nightlight |
| Stay Off When Opened | Thin open MacBook, dark glass and unlit power control |
| Sleep When Idle | Reverted to previous resting closed-laptop design |
| Sleep Timer | Half-hour timer dial with a sleep endpoint |
| Eject on Sleep | External SSD, standard eject triangle and bar; no CD |
| Bluetooth Off While Closed | Closed MacBook and crossed-out Bluetooth rune |
| Lid Shortcuts | Physical lid event and interlocking Shortcuts ribbons |
| Arm While an App Runs | macOS window with title-bar controls and a Dock running marker |
| Arm When a Drive Connects | Reverted to previous standalone external-drive design |

The module catalog and implementation were read together. An enabled module does not prove a particular action is happening now, so policy, completion, cleaning, and audio cues are stationary rather than continuously simulating work or playback. No power, audio, keyboard, or module settings were changed to create the previews.

## Playback

The application uses eight generated `idle-on-N` frames sampled at 5 fps only for sprites with changing frames. Movement is confined to authored details: agent-eye blinks, terminal cursors, steam, the fan impeller and activity lights. Passive policies and all OFF states remain stationary. Hover adds a small fixed brightness lift rather than starting a second animation clock. Reduce Motion selects static artwork and snaps power-state changes. The pixel reveal uses the native 28×28 grid rather than fractional 8×8 cells.

The old generic Canvas overlays are no longer attached to the module sprite view. They could put effects outside the real details and create fractional or misaligned pixels.

## Regenerate and verify

```sh
python3 generate-sprites.py
python3 -m unittest discover -s Tests -p 'test*sprite*.py' -v
bash build.sh
```

Generation has no required third-party packages. Pillow additionally creates a labeled contact sheet and animated GIF in the build directory. The tests check catalog coverage, palette, solid pixels, stable silhouettes, stationary disabled/passive states, budget limits, and lossless asset output.

The general animated preview uses the source blue palette. The selected redesign proof uses the real `ModuleSprite` SwiftUI renderer, including its warm enabled-state colors. Compile the proof with `swiftc Sources/ModuleSprites.swift tools/render-sprite-proof.swift -o build/render-sprite-proof`, run it from the repository root, then run `tools/preview-selected-sprites.py` with Pillow to produce the labeled 16-sprite proof. The application also preserves its khaki disabled-state transform.
