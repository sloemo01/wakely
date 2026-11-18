# Build a Wakely component

Wakely is a Mac menu bar app. It keeps a Mac awake with the lid closed, then lets it sleep normally once the lid opens. You are helping someone add a component to it: one small capability with an icon, a name, a one-line tagline, a description the user can edit in place, and rules that decide when the Mac stays awake or when a session ends. Wakely lists the component in Settings > Components, in the Custom group, beside its own components.

Two files make a component, both inside `components/<id>/`: `component.json` and `icon.txt`. There is no code to write, build or install.

## Work in this order

1. Ask the user what the component should do, in one short message. If the idea is already clear, propose a name, a tagline and the behavior in the same message and ask for confirmation. One component, one job.
2. Check the idea against "What a component can do" below. If it needs something the format cannot do, say so plainly and offer the closest component that works.
3. Create the folder with `sdk/bin/wakely-component new <id>`, or copy `sdk/template/` to `components/<id>/`. The id is the folder name: lowercase words joined by single hyphens, like `render-watch`.
4. Write `components/<id>/component.json`. `sdk/reference.md` describes every field, `sdk/component.schema.json` is the full schema, and `sdk/examples/` holds four finished components.
5. Draw `components/<id>/icon.txt`: 32 lines of 32 letters. Read `sdk/icon-style.md` before you start and study a few icons in `sdk/reference-sprites/`. Work in layers: outline and body first, then shading, then light.
6. Run `sdk/bin/wakely-component check <id>` and fix every error. Each error names the file, the place and the fix. Run the check again until it prints `ok` or warnings only, and fix the warnings unless you have a reason not to.
7. Run `sdk/bin/wakely-component preview <id>`. If you can view images, look at the files it writes in `components/<id>/.preview/`: your icon beside Wakely's, at card and page size. Improve the drawing with small edits, at most three rounds. Then open `components/<id>/.status.json`, which Wakely writes within a second of every change. `"state": "loaded"` means the component is in Wakely; when the state is `invalid`, its `errors` list says why. If there is no `.status.json` after a few seconds, Wakely is not running: a clean `check` is enough, and the component appears the next time Wakely starts.
8. Tell the user it is ready and where to turn it on: Wakely's Settings > Components, in the Custom group. Explain in one or two sentences what it does and which values they can change in its description.

If `sdk/bin/wakely-component` is missing or cannot run, skip it: Wakely validates the component itself and writes the same errors to `.status.json`.

## Rules for you

- Create or change files only inside `components/<id>/` for the component you are building. Leave `sdk/`, `AGENTS.md` and the other component folders alone.
- Write the name, tagline and description in the user's language, in plain words. Keep Wakely's tone calm and exact: no exclamation marks, no hype, no emoji.
- Make the description state what the component does with its real values, which the user edits in place. For example: "While {apps} runs, keep the Mac awake with the lid closed, and let it sleep after {limit}."
- Promise only what the rules actually do.
- To change a component later, edit its files in place; Wakely reloads them. To remove it, the user right-clicks its card and chooses Remove.

## Rules at a glance

Every rule is one JSON object. These are the shapes you will use most.

- Keep awake: `{ "keepAwakeWhile": <condition> }`. Conditions are `appRunning`, `batteryAbove`, `batteryBelow`, `onCharger`, `onBattery`, `externalDisplay`, `timeBetween`, `choiceIs`, and the combinators `all`, `any` and `not`. Several keep-awake rules mean any one of them is enough.
- Timed events: `{ "on": "closedFor", "after": <minutes or a duration/minutes value>, "do": [...] }`, and the same shape with `"sessionFor"`. `closedFor` counts the lid-closed part of the current session and fires once in each closed-lid session; `sessionFor` counts the whole session.
- `when`: an optional condition on an event rule. The rule fires only if it holds, for example `{ "on": "unplugged", "when": "sessionActive", "do": [...] }`.
- `endSession`: an action that ends the current session so the Mac sleeps normally, with a reason of 2 to 60 characters that Wakely shows. It does nothing when no session is on.
- `notify`: an action that posts a notification, either as text or as `{ "title": ..., "body": ... }`. Without a title it uses the component's name, and Wakely sends at most one a minute.
- `lidClosed` and `sessionActive` are conditions only for an event's `when`. `keepAwakeWhile` rejects them, because the lid or an existing session cannot be what holds the Mac awake.

## What a component can do

Components can do four things.

- Hold the Mac awake with the lid closed while a condition is true: an app is running, the Mac is on the charger or on battery, the battery is above or below a level, an external display is connected, the local time is inside a window, or a choice the user flipped. An event rule's `when` can also check whether the lid is closed and whether a session is on. Conditions combine with `all`, `any` and `not`. Wakely arms by itself when the condition starts (only with the lid open, with one notification), and the Mac sleeps normally when it ends.
- React to a moment: the lid closing or opening, a session starting or ending, the closed-lid session starting or ending, waking, plugging in or unplugging, the battery falling below a level, or a session lasting a number of minutes.
- End the current session, with a short reason Wakely shows, so the Mac can sleep normally.
- Post a notification, at most one a minute.

It cannot run code, read or write files, eject or mount drives, use the network, watch Wi-Fi networks or downloads, change system settings, control other apps or the display, or turn Wakely's safety off. When the user asks for one of these, say so plainly and build the closest component that works: an app Wakely can watch, a time window, or a notification that reminds them.

Wakely's safety always wins over every component: opening the lid, the user turning Wakely off, low battery, heat and Wakely's own checks end a session whatever a component says. If Wakely is turned off while a component's condition holds, the component waits until the condition ends and starts again.

## When it does not load

`.status.json` holds the errors. A component with errors never runs; if an earlier version worked, that version keeps running until the new one passes. The card in Settings shows the first error, and its menu has Copy Fix Prompt.
