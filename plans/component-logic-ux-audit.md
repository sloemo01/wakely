# Wakely component logic, UX and verification plan

## Scope and evidence

Audit of the current workspace after the app-wide motion edits, using three
read-only subagents plus parent review. Covers all **31 built-in components**,
custom components and shared UX. The motion work is built and tested but has
**not** been installed during this audit. No component behavior was changed as
part of the audit.

- Full regression suite: **79 PASS, exit 0**. This includes compile steps, pure
  policies and source-integration guards, not 79 hardware acceptance tests.
- Native menu regression: action mapping, refresh, opaque inset hover and stale
  hover cleanup pass without showing a window or moving the pointer.
- Panel model: **42,497 checks** pass for routing, reversals, interruption, layout
  and bounds. These are model tests, not a video-quality assessment.
- Offscreen rendering: General/Components navigation and 11 card/detail morph
  checkpoints produced successfully. No screen-lock or power action was invoked.
- Installed app signature verifies. Read-only helper check: installed/reachable;
  reports low power, fan, Touch ID, BootPreference and wake operations supported.
  `autorestart` is explicitly unsupported on this Mac. The watchdog is loaded.
- A supported capability is **not evidence that its write, restore or physical
  hardware effect succeeded**. Actual sleep/wake, input blocking, fan RPM,
  Bluetooth, drive ejection and firmware effects remain live-test items.

## Highest-priority findings

### 1. Sleep Timer: preserve audio only after a successful outcome

[Expiry path](../Sources/ComponentBehaviors.swift#L862-L883) preserves its fade,
then calls a sleep function returning a Boolean without checking the result.
If sleep is refused, output may remain at zero. Home Server can deliberately
refuse the timer's disarm; the delayed task then aborts while the fade is retained.

**Plan:** model expiry as explicit outcomes: cancelled, blocked, requested,
refused, resumed. Restore the original output when sleep is blocked/refused or a
newer session invalidates the request. Keep successful-sleep restoration on wake.
Show the blocking component and a cancellable countdown; do not claim the Mac is
asleep merely because a request was sent.

**Tests:** fake clock/audio/sleep backend; off before/after expiry, refused sleep,
Home Server conflict, rearm during delay, output-device changes, wake restoration.

### 2. Sleep Until Reset: lifecycle generations and independent ownership

[Replanning](../Sources/SleepUntilResetController.swift#L146-L175) checks enabled
and lid state before asynchronous work, but stale continuations can schedule
wakes after open/disable/quit. Planned times are recorded before successful
scheduling; the wake matcher can therefore treat a merely planned time as owned.
The default session path uses a manual arm/full disarm rather than an independent
owner, potentially ending holds acquired after the reset session began.

**Plan:** lifecycle generation token after every await and before each mutation;
serialize schedule/cancel reconciliation; track confirmed helper-owned events
separately from desired plans. Use a dedicated reset-session owner so finishing
that work releases only its own claim.

**Tests:** delayed helper/read scan with disable/open/quit/re-enable; failed
schedule/cancel; unrelated wake near a planned instant; other owner acquired
while reset work runs; battery/AC, idle/wait caps and restart adoption.

**Already fixed:** helper-owned wakes are adopted on relaunch. Preserve that.

### 3. Password After Close: a requested lock is not a confirmed lock

[Native lock request](../Sources/PowerEngine.swift#L808-L819) returns true when
the symbol exists while discarding its actual return value. The controller checks
that Boolean before disabling Touch ID, so it can still treat a failed request
as successful.

**Plan:** capture the API result and return a truthful outcome; where the private
API's semantics cannot prove lock, require observed screen/session lock state
before applying Touch ID changes. Keep deduplication tied to successful requests.
Show any outstanding restoration rather than burying it in logs.

**Tests:** missing symbol, rejected request, delayed lock observation, unlock
while helper request is in flight, disable/quit during apply, locked relaunch and
helper unavailability during restore. Live lock/Touch ID tests require approval.

### 4. Keep Awake: separate a request from its saved default

[Start/update/end](../Sources/ComponentBehaviors.swift#L449-L537) mixes explicit
menu requests and saved defaults. An explicit one-hour request can have its
deadline cleared when the stored preference is zero (Indefinitely). The indefinite
flag is not reset at teardown, so a later finite activation can inherit it.

**Plan:** a single state model (`stopped`, `timed(deadline)`, `indefinite`) with
separate configuration and active request. Starting a menu request must not reread
and override it with a default. Reset transient state on stop/close/disable.
Display the actual active mode/deadline, not just the configured default.

**Tests:** saved indefinite + menu finite, saved finite + menu indefinite,
stop/re-enable, rapid retiming, close/reopen, assertion failure and screen toggle.

### 5. Shared hold ownership and Home Server

[PowerEngine](../Sources/PowerEngine.swift#L106-L130) retains the initial session
lifetime when a persistent AC/Home Server owner joins an existing one-close
session. Behavior can depend on acquisition order. Home Server's catalog says it
is helper-independent, but its enable/start paths still require a helper even
though its core AC/login behavior does not need privileged `autorestart`.

**Plan:** retain lifetime per owner and compute the effective session policy;
release only the owner that ended. Separate Home Server's AC/login core from its
optional firmware enhancement. Expose all owners and explain why a timer/idle
request is blocked. Keep deliberate safety overrides explicit.

**Tests:** every owner order, manual + automatic, unplug/off, lid open, helperless
Home Server, safety disarm, timer/Home Server conflicts. Existing owner-release
preservation is already implemented; do not regress it.

### 6. Custom runtime: baseline edges, stored values and status

[First observation](../Sources/ComponentRuntime.swift#L132-L165) can synthesize
plugged-in/lid/session-start events after enabling or reloading. Icon-only changes
reset rule state. [Stored overrides](../Sources/Components.swift#L107-L120) are
not migrated/validated against an edited value specification; runtime numeric
operands can consume old out-of-range/type-incompatible values. The circuit
breaker is logged, not visibly published, and its reset differs from SDK wording.

**Plan:** baseline the first observation without inventing edges, with explicit
opt-in if startup reconciliation is wanted. Migrate stored values to current
kind/bounds/options, reject nonfinite values, and share that normalization with
UI/runtime. Reset counters only on meaningful rule/config changes. Publish a
stopped/error status. Document and obtain clear consent for rules that end the
global session rather than only their own hold.

**Tests:** first sample vs real edge, reload while armed, icon-only edit, stale
numeric/choice/app values, different owner sessions, circuit-breaker state and
re-enable/reset rules.

## All 31 component checks

`Source issue` means a code-backed bug or behavior/copy mismatch, not a failed
hardware test. `Conditional/live test` means a runtime path exists but its actual
system effect has not been demonstrated.

| Component | Audit result | Required verification / UX change |
|---|---|---|
| Agent Screen | Conditional/live test; only armed, working screen/browser-qualified agents receive display hold. Stale working/tool metadata can prolong it. | Test stale metadata, grace boundaries, assertion refusal and multiple agents. Explain eligibility instead of implying every agent keeps the screen alive. |
| Agent Status | Source UX mismatch: idle/unknown-only sessions can summarize as “0 waiting on you.” | Test busy/wait/idle/unknown/missing metadata and PID reuse; show truthful counts and state age. |
| Finish Work, Then Sleep | Fixed initial cohort, waiting cap and grace; completed cohort is not automatically reset for later work. | Decide one-shot vs continuous contract; test second session/new cohort and other owners preventing actual sleep. |
| Agent Notifications | Conditional; foreground suppression deliberately does not replay. Revocation/delivery failure can consume a transition without a notice. | Test terminal/tab identity, lost ancestry, revoke and delivery outcomes; show suppression/degraded state. |
| Agent Light | Conditional; waiting overrides working; done tail comes from explicit completion. | Test simultaneous states, malformed duration and monitor stop/restart; distinguish done indication from armed state. |
| Sleep Until Reset | Source issues: stale replans, planned vs confirmed ownership, global arm/disarm. | Priority 2 above; keep existing restart adoption. |
| Caps Lock | Switch watcher can work without AX; typing protection degrades when AX is revoked. | Test secure input, tap timeout, revoke/regrant and external keyboards; show optional protection status separately. |
| Cleaning Lock | Core safety path present: rejects already armed; a successful new arm ends it immediately. | Test deadline, Escape, tap disable, AX revoke, display hot-plug and main-thread stall. Explain which owner blocks/ends it. Do not start during audit. |
| Lid-Close Sound | Conditional: armed close, one accepted playback per close with bounded retries. | Test mute/output routes, rapid reopen, unavailable angle sensor and Quiet Close ordering. Backend start is not proof of audibility. |
| Quiet Close | Conditional restoration tied to captured device; in-memory recovery is lost on crash. | Test original mute, output switch/disconnect, reopen during pending task and failed restore; show pending recovery. |
| Password After Close | Source issue: underlying lock return ignored despite controller guard. | Priority 3 above; live lock/Touch ID restoration test requires approval. |
| Bag Check | Once-per-close latch, not every later unarmed episode during that same close. | Align wording; test arm/unarm within one close, wake-while-closed and permission revoke. It cannot alert while actually asleep. |
| Always On While Plugged In | Owner release is scoped correctly; persistent lifetime is order-dependent. | Priority 5; test AC/battery and owner orders. Screen “off” only releases this display hold—it does not force sleep or override other display owners. |
| Home Server | Source issue: helper-independent core is still helper-gated. Timer/idle disarm is deliberately ignored. | Separate core and optional enhancement; show conflict rather than claim timer succeeded. Autorestart unsupported on this Mac. |
| Low Power While Closed | Conditional/live test; battery-only closed-session apply and saved restoration exist. | Late helper reply/off/open, AC→battery, failed restore, exact pmset readback and pending state. |
| Battery Budget | Pure accounting policy covered; reaching budget disarms, but does not prove immediate OS sleep. | Test missing readings, threshold and multiple owners; show remaining budget and “allows sleep” accurately. |
| Keep Awake | Source bugs in explicit finite/indefinite state and teardown. Separate screen assertion exists. | Priority 4; test all request/default combinations and explain active vs enabled. |
| Sleep Means Sleep | Automatic advertised feature is absent; enable path refuses and tick is a no-op. | Remove unconditional promise; clearly unavailable/limited until a safe implementation exists. Never cancel unrelated wakes speculatively. |
| Stay Off When Opened | Conditional/live firmware test; BootPreference `%00` mapping and ownership restoration exist. | Test late replies/external changes; explain persistence and refusal. Accepted command is not proof firmware follows it. |
| Finish Jobs, Then Sleep | Source/copy mismatch: bounded process cohort, not general download/network-quiet detector. | Decide supported signals, test idle selected app/unknown transfer/new job and other holds; do not claim all jobs are detected. |
| Sleep When Idle | Source/copy mismatch: no general CPU/audio check; fresh work rearm requires lid open. | Test audio, unknown CPU load, slow transfer and closed-lid resume; implement promised signals or narrow wording. |
| Sleep Timer | Source bugs: blocked/refused sleep can retain zero audio. Cancellation/generation guard already exists. | Priority 1; countdown, blockers, request outcome, correct fade recovery. |
| Fan Boost | Mode 3 read/saved-mode restoration is now in source. Initial forced boost is not workload-gated; governor corrects later. | Gate the first boost on workload, retain exact per-fan snapshots; test mode 0/3/mixed manual fans and interrupted restore. Physical RPM test requires approval. |
| Eject on Sleep | Source bug: remount uses names, clears records before success and can label failed command output “ok.” | UUID-based recovery, exit-status checks, retry ledger, Time Machine/unknown skips, duplicate names and unplug/reconnect tests. |
| Bluetooth Off While Closed | Conditional private-framework request; restoration checks/retries exist. | Test unavailable symbols and real off/on separately; show requested/unconfirmed/failed rather than silent logs. |
| Awake While Connected | Conditional charger-gated `lsof`/`who` heuristic, not authoritative remote-work detection. | Test detector failure vs zero sessions and grace; state AC requirement and observation uncertainty. |
| Lid Shortcuts | Source issue: launch/exit errors discarded; “ran” may be logged even if it failed. | Capture completion/error, validate configured names, define in-flight OFF semantics and avoid false success. |
| Arm While App Runs | Empty selection is enabled but inert; app presence is not workload. | “Choose an app” validation/status; test missing/renamed/relaunched app and owner release. |
| Arm on Wi-Fi | Empty/unknown SSID inert; AC requirement and 60s grace apply. | Distinguish missing config, no Location permission and disconnected network; report failed Use Current instead of silent no-op. |
| Arm on a Schedule | Pure invalid/overnight policy correct, but UI permits invalid/equal time or no days without feedback. | Validate before enable; explicit timezone/overnight summary and no-selected-day error. |
| Arm When a Drive Connects | Empty selection inert; AC required; disconnected remembered drives disappear from editor. | Keep remembered UUID selections editable, show AC/waiting/missing-drive status and test reconnect/path changes. |

## UX plan (shared rather than 31 one-off patches)

1. **Separate enabled from running.** Shared per-component health:
   Off → Needs setup/configuration → Waiting for condition → Active →
   Applying/Restoring → Blocked/Unavailable/Failed. Include a concise reason,
   last attempt and retry action. A checkmarked helper only means the helper
   connection is ready, not that this operation is supported or applied.
2. **Expose hold ownership.** Show which components/manual requests keep the Mac
   or display awake; tell the user which one prevents Sleep Timer/idle behavior.
3. **Validate setup before enabling.** App, network, drive, schedule/day and
   Shortcut selection receive inline validation and a relevant action.
4. **Make screen wording honest.** “Keep display awake / Allow display sleep”
   instead of implying “off” forcibly powers off a screen or overrides another
   component's display assertion.
5. **Runtime permissions.** Recheck at use and on activation; show degraded states
   on revoke. No automatic input lock after a permission grant; no blanket TCC
   reset or helper reinstall as a generic remedy.
6. **Recovery is visible.** Pending audio/fan/Touch ID/firmware/drive restoration
   must remain actionable across failure/relaunch where supported. Show skipped,
   requested and unconfirmed outcomes without calling them success.
7. **Motion follows correctness.** The uninstalled motion pass adds shared
   restrained springs, stable tabs, coordinated card morph text, submenu/height
   transitions and live Reduce Motion. Keep deterministic pixel reveal and
   atomic numeric scrubbing; no visual tooltips/scrollbar regressions. Validate
   rapid reversal, tab changes during morph, filter changes, resize and reduced
   motion mid-flight before shipping it.

## Implementation order and acceptance gates

### Batch A — safety and outcome correctness
- Password lock outcome, Sleep Timer fade recovery/conflicts.
- Reset wake generations, confirmed schedules and independent owner.
- Regression tests must reproduce each failure before the fix, pass after it,
  and not make real system mutations.

### Batch B — state/ownership composition
- Keep Awake request/default state machine.
- Per-owner lifetime and helperless Home Server core.
- Startup/permission/recovery health and truthful active state.
- Test pairwise owner acquisition/release orders and late asynchronous replies.

### Batch C — contracts, configuration and custom runtime
- Align or implement job/idle detection and closed-lid rearm promises.
- Validate connection configuration and Shortcut results.
- Baseline custom events, stored-value migration, circuit-breaker status/consent.
- UUID drive recovery and initial fan workload gating.

### Batch D — UX and motion acceptance
- Apply the common health UI and ownership explanations to all components.
- Render compact/large detail states, long inline choices and all error states.
- Test switches both drag directions, rejected enables, rapid close/reopen,
  navigation/resize and Reduce Motion. Preserve pixel reveal.

### Batch E — approved live matrix, then one release
- Ask permission for the specific component/system effect before live sleep,
  input lock, fan write, radio toggle, drive eject or firmware mutation.
- Capture before/apply/after/restore readback, timeout and emergency recovery.
- Do not call a component hardware-verified without that evidence.
- Build/sign once using the stable Wakely certificate; preserve existing
  installs and user settings. Verify permissions after upgrade, helper readiness and
  one launcher entry. Package only the approved, tested release.

## Definition of done

Every component has a traceable claim, eligibility, on/off/cancellation and
recovery contract, deterministic runtime tests, truthful UI state and an explicit
hardware-verification status. Passing tests and reachable helpers are never
substituted for proof of actual system effects. The plan is the deliverable for
this audit; the fixes above are not silently applied or installed.

## Implementation status (this pass)

Completed and installed:

- Password After Close now requires observed screen-lock state before changing
  Touch ID; the private API return is treated only as a request, never proof.
- Sleep Timer restores audio when another owner keeps the session armed or the
  sleep request is refused.
- Keep Awake now separates an explicit menu request from the saved default,
  resets indefinite state at teardown, and preserves the separate display hold.
- Sleep Until Reset uses lifecycle generations after every await; plans are
  published only after confirmed schedule/cancel results; arm/disarm is scoped to
  its own automatic-owner claim instead of globally ending other holds.
- Custom components prime their first observation without inventing lid/charger/
  session transitions, ignore icon-only edits in their state fingerprint, and
  normalize stored values against the current value specification.
- Home Server's AC/login core no longer requires the helper; the firmware
  auto-restart enhancement remains optional and unsupported on this Mac.
- App-wide motion foundation is present: shared restrained springs, stable tab
  panes, single-layer card morph text, submenu/height transitions and live Reduce
  Motion. Deterministic PixelReveal remains.
- **80 test steps pass**; build, signature, helper readiness, watchdog and
  offscreen morph/navigation renders verified. Accessibility remains trusted.
- Installed app and `dist/Wakely-2.0.0-component-audit.dmg` match.

Remaining from this plan: common health-state UI, job/idle contract alignment,
connection configuration validation, Shortcut outcome reporting, UUID-based drive
recovery, initial fan workload gating, and the approved live hardware matrix.
Motion needs visual acceptance for rapid reversal/resize/production transition.
