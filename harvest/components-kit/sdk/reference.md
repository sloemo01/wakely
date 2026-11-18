# component.json reference (format 1)

Strict: an unknown field is an error, so check spelling. All text is one line.

```json
{
  "format": 1,
  "id": "render-watch",
  "name": "Render Watch",
  "tagline": "Stays awake with the lid closed while your render app runs.",
  "keywords": ["render", "export", "video"],
  "description": {
    "text": "While {apps} runs, Wakely keeps your Mac awake with the lid closed, and ends the session after {limit}.",
    "values": {
      "apps": { "kind": "apps", "default": [] },
      "limit": { "kind": "duration", "default": 120 }
    }
  },
  "rules": [
    { "keepAwakeWhile": { "appRunning": "apps" } },
    { "on": "closedFor", "after": "limit", "do": [{ "endSession": "Render time limit reached" }] }
  ]
}
```

## Fields

| Field | Rules |
| --- | --- |
| `format` | Always `1`. |
| `id` | 2 to 40 lowercase letters, digits and hyphens, starting with a letter. Same as the folder name. |
| `name` | 3 to 30 characters, Title Case. Shown on the card and the page. |
| `tagline` | One sentence that says the outcome ("Stays awake while ..."). Aim for 64 characters or fewer, which fit the card; 90 is the hard limit. |
| `keywords` | Optional, up to 12 search words of 1 to 30 characters each. |
| `description` | A sentence (plain text), or `{ "text": ..., "values": { ... } }` when the user should edit values in place. 20 to 480 characters. |
| `rules` | 1 to 12 rules. |

## Values

Write `{key}` in `description.text` once for each value, and declare the same key under `values`. Up to 6 values. Each declared value must appear once in the text and be used by at least one rule; a value that no rule reads is an error, and so is a `{key}` that no value declares. The user changes values on the component's page, and every rule reads the current value.

| Kind | Fields | Shows as |
| --- | --- | --- |
| `duration` | `default` (required, 15 to 720 minutes); optional `min` and `max` in the same range | "2 hours" |
| `minutes` | `default` (required, 1 to 720 minutes); optional `min` and `max` in the same range | "5 minutes" |
| `percent` | `default` (required, 1 to 100); optional `min` and `max` in the same range | "20%" (do not write % after it) |
| `number` | `default`, `max` and `unit` (all required); optional `min`, `step` (a positive whole number), `unitPlural` | "3 times" |
| `choice` | `options` (exactly two different words); `default` (one of them or 0/1). Both required. | a word the user flips |
| `apps` | optional `default`: bundle identifiers, or `[]` | "Final Cut Pro or + add app" |

`duration`, `minutes`, `percent` and `number` take whole numbers. When `min` or `max` is omitted, `duration`, `minutes` and `percent` use the range shown; `number` has no fixed range and requires `max`. For every numeric kind, `min` may not be greater than `max`, and `default` must sit inside the bounds.

Bundle identifiers: `mdls -name kMDItemCFBundleIdentifier -r /Applications/<App>.app`, or `osascript -e 'id of app "<App>"'`. Some common ones: Final Cut Pro `com.apple.FinalCut`, Compressor `com.apple.Compressor`, Logic Pro `com.apple.logic10`, Xcode `com.apple.dt.Xcode`, Terminal `com.apple.Terminal`, Blender `org.blenderfoundation.blender`, HandBrake `fr.handbrake.HandBrake`. If you cannot confirm an app's identifier on this Mac, leave `"default": []` and tell the user to pick the app on the component's page (the `apps` value has an add-app button).

## Rules

Each rule is one of two shapes: a keep-awake condition, or a reaction to an event. The fields do not mix.

Keep awake while a condition holds:

```json
{ "keepAwakeWhile": <condition> }
```

Wakely arms by itself when the condition becomes true with the lid open (one notification), holds the Mac awake with the lid closed while it stays true, and lets the Mac sleep normally when it becomes false. Several `keepAwakeWhile` rules mean "any of them". `lidClosed` and `sessionActive` are rejected in this condition, at any nesting level; they belong in an `"on"` rule's `"when"`.

One condition is enough:

```json
{ "keepAwakeWhile": "onCharger" }
```

Combine conditions when one is not enough:

```json
{ "keepAwakeWhile": { "all": ["onCharger", "externalDisplay"] } }
```

React to a moment:

```json
{ "on": "<event>", "when": <condition, optional>, "do": [<action>, ...] }
```

`on` and `do` are required; `do` takes 1 to 4 actions, which run in order. `when` is optional; the actions run only when it holds at the moment the event fires. `after` and `below` carry the number some events need:

- `after`: 1 to 720 minutes, or a `duration` or `minutes` value key. Required for `closedFor` and `sessionFor`.
- `below`: 1 to 100 percent, or a `percent` value key. Required for `batteryBelow`.

Events: `lidClosed` and `lidOpened` follow the lid. `sessionStarted` and `sessionEnded` follow every session. `closedSessionStarted` (the lid closed on an armed Mac) and `closedSessionEnded` follow the closed-lid part of a session. `wake` fires when the Mac wakes. `pluggedIn` and `unplugged` follow the power source. `batteryBelow` fires when the battery falls below `below`. `closedFor` and `sessionFor` fire once when the lid has been closed, or the session has run, for `after`.

An event rule can be small:

```json
{ "on": "wake", "do": [{ "notify": "The Mac is awake." }] }
```

A rule with `when`:

```json
{ "on": "lidClosed", "when": "sessionActive", "do": [{ "notify": "The lid closed on an armed Mac." }] }
```

A timed rule:

```json
{ "on": "closedFor", "after": 45, "do": [{ "endSession": "45 minutes with the lid closed" }] }
```

A battery crossing:

```json
{ "on": "batteryBelow", "below": 20, "when": "sessionActive", "do": [{ "endSession": "Battery below 20 percent" }] }
```

What the events count:

- A session is any time Wakely is armed, whoever armed it: your component, another component, the user or a shortcut. `sessionStarted`, `sessionEnded` and `sessionFor` follow every session.
- The closed-lid session is the part of a session with the lid closed. `closedFor` measures how long the lid has been closed in the current session and runs once per closed-lid session.
- `batteryBelow` runs once each time the level crosses below the value, in or out of a session. Add `"when": "sessionActive"` or `"when": "lidClosed"` to limit it.
- `endSession` does nothing when no session is on.
- After any session ends (your `endSession`, the user, the lid opening), a component whose `keepAwakeWhile` condition still holds does not arm again: it waits until the condition ends and starts again. So "at most 3 hours" is one `closedFor` rule with `endSession`, and the Mac stays asleep after it.
- Notification text and reasons are shown as written; `{key}` placeholders work only in the description.

## Conditions

An object condition has exactly one operator. Nesting stops at four levels.

| Condition | Meaning |
| --- | --- |
| `"onCharger"`, `"onBattery"` | The power source. |
| `"externalDisplay"` | A display other than the built-in one is connected. |
| `"lidClosed"` | The lid is closed. Only in an `"on"` rule's `"when"`, never in `keepAwakeWhile`. |
| `"sessionActive"` | A session is on (Wakely is armed, by anyone). Only in an `"on"` rule's `"when"`, never in `keepAwakeWhile`. |
| `{ "appRunning": "<apps value key>" }` or `{ "appRunning": ["com.apple.FinalCut"] }` | Any of the apps is running. An array may list 1 to 8 bundle identifiers. |
| `{ "batteryAbove": 50 }`, `{ "batteryBelow": "level" }` | The battery level is above or below a number from 1 to 100, or a percent value key. |
| `{ "timeBetween": ["22:00", "07:00"] }` | Local time inside the window (two 24-hour HH:mm times, may cross midnight; the start is included and the end is not). |
| `{ "choiceIs": { "mode": "always" } }` | A choice value key currently reads that word. |
| `{ "all": [ ... ] }`, `{ "any": [ ... ] }`, `{ "not": <condition> }` | Combine conditions. `all` and `any` take 1 to 8 conditions; `not` takes one. |

`lidClosed` and `sessionActive` are valid only inside an `"on"` rule's `"when"`, including when nested in `all`, `any` or `not`. `keepAwakeWhile` rejects them at any depth.

## Actions

| Action | Meaning |
| --- | --- |
| `{ "endSession": "Why it ended" }` | Ends the current session so the Mac sleeps normally; the reason is 2 to 60 characters and is shown. Does nothing when no session is on. |
| `{ "notify": "Text" }` or `{ "notify": { "title": "...", "body": "..." } }` | A notification titled with the component's name unless you set `title`. The string is 2 to 140 characters; the object has a required `body` (up to 140) and an optional `title` (up to 40). At most one a minute. |

## Good to know

- Every component is off until the user turns it on.
- Wakely's safety always wins: opening the lid, the user turning Wakely off, low battery, heat and Wakely's own checks end a session whatever a component says.
- A component that keeps the Mac awake and lets it go more than 6 times in 10 minutes is stopped until its files change.
