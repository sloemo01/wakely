# Built-in component implementation/lifecycle audit

Scope: read-only source inspection of all 31 catalog entries; narrowly coordinated source fixes and pure tests. No app launch, settings changes, helper operations, permission prompts, audio playback, ejection, radio changes, or hardware interaction were performed for this audit. `ComponentCapability` is descriptive data, not evidence that a feature works.

## Catalog-to-code map

Paths below are relative to this repository. All rows have source inspection only unless their test scope is explicitly stated. Generic enable persists the ID then ticks; disable releases its automatic arm owner before per-ID teardown. These mechanics are in [ComponentBehaviors.swift](../Sources/ComponentBehaviors.swift).

| Catalog ID | Underlying implementation / disable or restoration |
|---|---|
| agentScreen | ComponentEngine.agentScreen uses display-sleep IOPM assertion and AgentDisplayPolicy; teardown releases assertion. Original transcript/schema interpretation remains partial. |
| agentStatus | [MenuBar.swift](../Sources/MenuBar.swift) rebuild gates the row; [AgentMonitor.swift](../Sources/AgentMonitor.swift) supplies threads/counts. Off hides UI, not shared agent monitoring. |
| finishWorkThenSleep | reconcileAutomaticHolds + BoundedWorkSnapshot + automatic owner; teardown resets snapshot and releases owner. Bounded work policy is not proof of real agent completion. |
| agentNotifications | agentNotifications/consumeFinished/installAgentFinishHook; enable seeds existing finished/waiting snapshots to avoid replay; consume checks enabled. Delivery now uses app-owned UserNotifications authorization rather than osascript. |
| agentLight | MenuBar.stateColor uses waiting/working counts and lastFinishedAt retention; disabled branch falls back to normal power colors. Not a physical light peripheral. |
| sleepUntilReset | [SleepUntilResetController.swift](../Sources/SleepUntilResetController.swift) owns planning, wake requests, close/open/disable/quit cancellation; local reset metadata is a defensive adapter. No real scheduled wake tested. |
| capsLock | [CapsLockLight.swift](../Sources/CapsLockLight.swift) watches key; typing filter active only while armed. Off stops watcher/filter. No real HID/tap exercised. |
| cleaningLock | [CleaningLockController.swift](../Sources/CleaningLockController.swift); turning the component on begins the timed lock, off/timeout/Escape/arming ends it and resets the switch. Requires Accessibility; a missing grant opens setup instead of failing silently. |
| lidCloseSound | CloseSoundPlayer in [Feedback.swift](../Sources/Feedback.swift), PowerEngine hinge/close path, enable flag and prepare. No actual audibility verified. |
| quietClose | lidChanged waits for the close sound then mutes the exact output device on every real close; open/session-end/disable restores that device and checks API status. |
| passwordAfterClose | PasswordAfterCloseController lock observer/phase persistence + ProtectedComponents touchID helper operations. Disable/quit/unlock restoration paths exist. No actual lock/password/Watch/Touch ID test. |
| bagCheck | One notice per closed/unarmed episode after 60s; the episode flag resets on lid open or disable. |
| alwaysOnPluggedIn | AC automatic persistent-lifetime owner in reconcileAutomaticHolds; disable releases only its own owner. |
| homeServer | AC hold + HomeServerAutomation rearm budget bridge + login registration; protected persistent autorestart path. Firmware boot/restart unverified. |
| lowPowerWhileClosed | ProtectedComponents session plan calls helper low-power operation, restores on open/end/disable/quit. Closed-session epoch gating fixed; battery eligibility may go stale during async request. |
| batteryBudget | ClosedBatteryBudget.sample accounts closed armed battery discharge; disarms at configured share; teardown resets accounting. |
| keepAwake | startKeepAwake/updateKeepAwake/endKeepAwake separate lid-open IOPM assertion, deadline/manual indefinite; close and disable release. Toggle is not proof of assertion creation. |
| sleepMeansSleep | **No automatic implementation.** setEnabled refuses the toggle with a visible reason; the obsolete per-component administrator panel was removed from the UI. Manual settings are not automatic scheduled-wake suppression. |
| stayOffWhenOpened | ProtectedComponents persistent bootOnLidOpen helper/NVRAM operation; disable restores. Hardware/firmware acceptance unverified. |
| finishJobsThenSleep | WorkProcesses.currentIDs known transfer/backup/render names or selected bundle IDs + BoundedWorkSnapshot/owner; off resets. Process presence does not establish active download/export; arbitrary network jobs not captured. |
| sleepWhenIdle | Busy predicate across agents, SSH, network and known jobs; idle disarm/rearm flags. Fixed stale flags surviving disable. Hardware sleep/rearm not exercised. |
| sleepTimer | Deadline + Audio.fadeOut then disarm, delayed System.sleep guarded by enabled and session generation; disable cancels pending task and restores fade. Sleep rejection/wake audio behavior unverified. |
| fanBoost | ProtectedComponents SMC gate now probes FNum/F0Md/F0Tg through AppleSMC selector 2; unsupported models refuse, supported models force a target and restore. Physical RPM change remains unverified. |
| ejectOnSleep | Real-sleep preparation -> Volumes.ejectForSleep, Time Machine and arm/lid/external-display safety checks; wake remount helper. Disable during async preparation originally lacked enabled rechecks; see remaining findings. |
| bluetoothOffWhileClosed | Sleep preparation private IOBluetooth symbols; recorded restoration on wake/open/start/disable/quit and timeout. Getter/setter availability and success handling originally incomplete; see remaining findings. |
| awakeWhileConnected | SSH.activeSessions lsof/who + ConditionGrace/owner on AC; disable releases owner/resets grace. Process visibility/remote session detection unverified. |
| lidShortcuts | lidChanged -> Shortcuts.run configured name; missing or renamed shortcut and completion are not validated. Already launched shortcut is not canceled on off. |
| armWhileAppRuns | NSWorkspace.runningApplications bundle-ID predicate/owner; disable releases owner. |
| armOnWiFi | CoreWLAN SSID + AC/ConditionGrace/owner; disable resets grace/releases owner. SSID visibility requires permission; hardware association untested. |
| armOnSchedule | [ComponentBehaviorPolicy.swift](../Sources/ComponentBehaviorPolicy.swift) ComponentSchedulePolicy, weekdays/time window and AC owner; never wakes a sleeping Mac. |
| armWhenDriveConnects | Volumes external mounted UUID/path identity intersects chosen IDs, AC owner; disable releases owner. Real drive/mount transitions untested. |

## Fixed in this audit subtask

- Pending protected enables previously could not be canceled by off: persisted state was already false, so equality guard returned before removing pending work. UUID tokens now coalesce repeated on, invalidate on off/stop, reject off/on ABA and consume at most once.
- Protected session applications previously checked armed but not closed and accepted late helper writes after opening/reclosing. Capture an epoch before asynchronous preparation/queuing; require closed, armed, enabled, current epoch before/after writing and roll back stale successful writes. Restore invalidates even when a write has not yet entered `applied`. Ordinary periodic retries no longer advance the epoch.
- Sleep When Idle teardown now clears idleMayRearm and idleHadActivity as well as idleSince, avoiding stale automatic rearm after off/on.
- Quiet Close now snapshots the exact output AudioDeviceID and readable mute state after playback; only records ownership after a successful mute API result. Restoration targets that device rather than the new default, checks API status, and retains the saved state if restore fails. It now mutes on every real close, not only armed sessions.
- Bag Check now emits one notice per closed episode rather than one every minute.
- Cleaning Lock is switch-driven: the separate Lock Now button is gone; a failed event tap keeps the switch off with a visible reason, and cancellation no longer depends on which unrelated app is frontmost.
- Notifications use Wakely-owned UNUserNotificationCenter authorization; sleep uses the public IOKit power-management API instead of an Apple Events request to System Events.
- Eject on Sleep rechecks the component's enabled state before touching each drive.
- Bluetooth requires both getter and setter, treats an unknown prior state as unavailable, and only clears ownership after a verified restore readback.
- Permission onboarding is now part of the engine gate: required Accessibility, Location, notifications and helper setup are detected before enablement, with a real setup window, Settings deep link, and a draggable current-app tile where macOS supports file drops.

## Remaining concrete risks / missing checks

These describe the code inspected by this subtask; parent changes made concurrently may supersede individual entries.

1. Quiet Close overwrites a user's own mute change made while the lid is closed; restore failure is retained in memory but has no durable recovery after shutdown.
2. Ejection cannot undo an OS ejection already in progress. Remount still stores display names rather than stable volume IDs, and removes the saved list before attempts; duplicate/renamed volumes or command failure can lose retry evidence.
3. Bluetooth power is a private framework preference; readback is now required before claiming restoration, but completion is not transactional and hardware behavior is unverified.
4. Async protected eligibility for battery/external display can go stale independently of the fixed lid/session epoch; already applied low-power state is not reconciled on AC/display change during a session.
5. CommandRead collapses process failure to an empty observation in some callers; holds can release when observation fails rather than only when work ends.
6. Hardware/TCC paths remain unverified: actual input blocking, audio, Wi-Fi authorization, notification delivery, mutating helper writes, SMC/firmware effects, wakes and restarts. The ad-hoc helper install and read-only XPC capability round trips were exercised; that is not proof that a component changed hardware correctly. Capability prose was corrected where it was stale, but it is still descriptive data, not proof.

## What was actually verified

[ComponentEnablementLifecycleTests.swift](../Tests/ComponentEnablementLifecycleTests.swift) was compiled with the real pure policies and executed successfully: **19 assertions**, covering pending-token duplicate/coalesced on, off cancellation, off/on ABA, one-shot completion, stop/restart invalidation; and protected enabled/armed/closed/shutdown/epoch/persistent-scope decisions. It is wired into [run-tests.sh](../Tests/run-tests.sh).

Additional parent verification:

- Permission policy test covers all 31 catalog ids, clean-install missing state, revocation, optional Accessibility for Caps Lock, mandatory Accessibility for Cleaning Lock, no auto-lock on grant, exact Settings routes, and the manual-only Sleep Means Sleep exception. Pure simulation only.
- Source integration tests cover engine-level permission interception, switch-only Cleaning Lock, native notification/IOKit sleep substitution, drag/reveal wiring, window cancellation, keychain removal and audit-table coverage of all 31 ids.
- Full harness: **71 PASS**, exit 0.
- Built-in read-only report: **22 implemented, 6 partial, 3 protected/manual-only, 0 unsupported** across 31 ids.
- Helper setup is one shared installation (General → PRIVILEGED HELPER, or the first helper component); the setup window resolves helper reachability before appearing and no longer leaves a dead Install panel over a working helper.
- Listen-only Accessibility input-tap check: **PASS**; creation and activation work without blocking any input. This does not prove the consuming tap blocks every event for a full lock.
- Clean-install simulation: packaged DMG, mounted read-only, copied to a disposable Applications folder, launched with isolated HOME, rendered permission onboarding and component UI. Real quarantine/notarization/TCC/helper approval were not exercised.
- No live component was enabled, disabled, locked, ejected, played or asked for a permission during this verification.

## No-Apple-ID helper path (2026-11-13)

The shipped build is ad-hoc, so SMAppService cannot launch a daemon (macOS requires
a Team ID; `taskgated` rejects it and `backgroundtaskmanagementd` reports no Team ID).
A second, supported install path now exists:

- One administrator prompt copies a standalone signed/ad-hoc `WakelyHelper` to
  `/Library/PrivilegedHelperTools/dev.wakely.helper`, writes a plist with an absolute
  `ProgramArguments`, bootstraps it, and enables it.
- A root-owned `dev.wakely.helper.peer` file pins the exact ad-hoc cdhash of the app
  and watchdog. The XPC listener accepts only those hashes (plus the identifiers),
  rather than requiring an Apple-issued certificate.
- The watchdog uses a per-user `~/Library/LaunchAgents/dev.wakely.agent.plist` with an
  absolute `ProgramArguments`; no BackgroundTaskManagement/SMAppService agent.
- Rebuilding the app changes its cdhash, so the helper must be reinstalled once after
  an app update. The setup UI offers that administrator install again.
- Uninstall removes the plist, root helper and peer pin.

Verified on this Mac with the final ad-hoc build:

- Administrator install: success; `launchctl` reports the helper running as root.
- XPC `ping`/`status`: reachable; protocol 1 helper ready.
- Read-only capability results: low power, Touch ID, boot-on-lid-open, restore,
  request status, restore session, schedule/cancel wake and wake schedules supported;
  fan SMC unsupported (`kern_return_t 0xE00002C7`); `pmset autorestart` not reported.
- Watchdog user LaunchAgent loaded; while the app runs it logs
  `watching app pid … the agent stays up while it runs`.
- Final DMG mounts read-only with `Wakely.app`, `Applications` symlink and `Install.txt`;
  deep code-signature verification passes; app, helper and watchdog are ad-hoc with no
  Team ID. Gatekeeper will not treat this DMG as notarized.

Not executed: mutating helper operations (low power, Touch ID, NVRAM, SMC, wake
schedule, restore), a real crash-recovery run, or hardware verification. Those remain
code-path/read-only checks only. The 31-component report above is unchanged.
