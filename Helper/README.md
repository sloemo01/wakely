# Privileged helper

The app ships a root **LaunchDaemon** with an XPC Mach service plus a per-user
watchdog **LaunchAgent**:

```
Contents/Library/LaunchDaemons/dev.wakely.helper.plist
  BundleProgram: Contents/MacOS/WakelyHelper   MachServices: dev.wakely.helper
Contents/Library/LaunchAgents/dev.wakely.agent.plist
  BundleProgram: Contents/MacOS/WakelyWatchdog
```

The table below is the full inventory:

| Piece | File | Role |
|---|---|---|
| Daemon | `Helper/main.swift` | root-only XPC listener on `dev.wakely.helper`; refuses to run unless `geteuid() == 0` |
| Operations | `Helper/Operations.swift` | allowlisted `pmset`, `bioutil`, `nvram`, SMC and restore operations; fixed argv, 5 s deadline, snapshot → write → verify |
| Fan control | `Helper/SMC.swift` | AppleSMC `F0Md`/`F0Tg` write with read-back verification; reports unsupported when the keys are absent |
| Backup store | `Helper/BackupStore.swift` | `/Library/Application Support/dev.wakely.helper/backup.json`, root-only, atomic, earliest-prior preserved |
| Watchdog | `Watchdog/main.swift` | restores saved settings if the app dies while armed |
| Plists | `Resources/dev.wakely.{helper,agent}.plist` | LaunchDaemon + LaunchAgent, embedded by `build.sh` |

Install is one approval. A Developer ID build uses `SMAppService.daemon`
("Login Items"). An ad-hoc build cannot use SMAppService because macOS requires a
Team ID, so it uses one administrator prompt instead: the app copies a standalone
helper to `/Library/PrivilegedHelperTools/dev.wakely.helper`, installs a plist with
an absolute `ProgramArguments`, bootstraps the job, and writes a root-owned cdhash
pin for the app and watchdog. No Apple ID, Team ID, notarization or network access
is involved.

The same ad-hoc branch installs the watchdog as an ordinary per-user LaunchAgent at
`~/Library/LaunchAgents/dev.wakely.agent.plist`, because BackgroundTaskManagement
rejects an ad-hoc SMAppService agent. The app still kicks it on launch.

## What each protected component does through the helper

| Component | Operation | Honest limits |
|---|---|---|
| `lowPowerWhileClosed` | `pmset -b lowpowermode 1` on a closed battery session | needs the helper; restored on end/open/disable/quit |
| `fanBoost` | SMC `F0Md=1` + `F0Tg` per fan, verified within ±2 rpm | only on Macs that expose `F0Md`/`F0Tg`; MacBook Pro Mac15,6 reports support through selector 2 |
| `passwordAfterClose` | `bioutil -w -u 0` inside the console user's session | restored at the next unlock, lid open, launch or quit when the screen is provably unlocked |
| `stayOffWhenOpened` | `nvram BootPreference=%00` | a firmware that ignores the key is not detectable; a refused write is reported |
| `homeServer` | `pmset -c autorestart 1` | only when `pmset` reports `autorestart` |
| `sleepUntilReset` | owned `pmset schedule wake` at a supplied reset time | caller supplies the timestamp; wake may be deferred by hardware |
| `sleepMeansSleep` | battery `powernap`, `proximitywake` and `womp` set to 0 with every prior value leased | only settings this Mac reports; does not cancel third-party scheduled wake events |

Anything the hardware does not expose is refused with the exact missing key rather
than reported as success — see the capability report (`docs/capability.txt`).

## Peer identity

- Developer ID / self-signed: the listener requires the app or watchdog identifier
  plus the exact leaf certificate of the running helper.
- Ad-hoc: the listener requires the app or watchdog identifier plus the exact
  cdhash recorded in `/Library/PrivilegedHelperTools/dev.wakely.helper.peer`
  (root:wheel, not group/world writable). A rebuilt app must reinstall the helper
  once so the pin matches.

## The older, helper-free path

`Sources/PrivilegedComponentService.swift` is retained as legacy source, but the
app UI no longer exposes its per-component administrator prompt. Every helper
component uses the one shared daemon installation instead.

## Legacy notes (helper-free path)

This directory deliberately contains **no root daemon, installer, launchd service, socket, generic shell RPC, password, signing identity, or privileged executable**. The implementation is source in [PrivilegedComponentService.swift](../Sources/PrivilegedComponentService.swift). It uses the system's `osascript` administrator-authorization dialog for a narrowly generated `pmset` operation. Nothing is installed automatically.

## Implemented scope (current limits)

| Component ID | Operation | Limitations |
|---|---|---|
| `lowPowerWhileClosed` | Battery-only `pmset -b lowpowermode 1`; exact prior value retained | Caller must gate on a genuine closed, armed, battery session and restore on open, AC transition, disable, and quit. Settings absent from `pmset -g custom` are unsupported. |
| `sleepMeansSleep` | Legacy manual path only; the shared helper now owns the battery wake-source lease | Does **not** cancel another application's scheduled events or guarantee against all system/user/lid wakes. |
| `homeServer` | AC `autorestart 1`, only if the setting is reported | Does not configure login launch, invent firmware support, change auto-boot NVRAM, or guarantee battery recovery/reboot behavior. Unsupported on models that do not report `autorestart`. |
| `sleepUntilReset` | One explicitly owned wake at a supplied real account reset + 60 seconds | Requires a future account reset within 30 days. No guessed accounts, no repeated wake, no automatic sleep, no power-on request. Caller must supply account reset information and decide post-wake agent activity/sleep. Wake execution is not guaranteed by macOS/hardware. Cancellation is by exact timestamp + generated owner, never `cancelall`. |
| `passwordAfterClose` | Legacy manual path only | The shared helper is the supported path; this legacy source does not safely disable Touch ID. |
| `fanBoost` | Legacy row is outdated | The shared helper now validates and writes SMC fan targets; see the table above. |
| `stayOffWhenOpened` | Legacy row is outdated | The shared helper writes/restores `BootPreference`; firmware acceptance is still unverified. |

## API integration

All instance APIs are `@MainActor`.

```swift
let service = PrivilegedComponentService.shared
let capability = await service.inspectCapability(for: "lowPowerWhileClosed")
guard capability.ready else {
    // Display capability.reason; do not enable the component as if it worked.
    return
}
// ONLY from an explicit user-authorized action, never a timer tick.
do {
    let lease = try await service.apply(componentID: "lowPowerWhileClosed")
    // Applied settings have been read back and verified.
    // lease.componentID, lease.changes, lease.wake are available for UI/status.
} catch {
    // Display localizedDescription. Cancellation is failure, never success.
}
// Restoration can require another administrator dialog. It too must be an
// explicit user action; do not silently spawn repeated authentication prompts.
try await service.restore(componentID: "lowPowerWhileClosed")
```

Other APIs:
- `capability(for:resetDate:)`: synchronous structural readiness/reason (no system access).
- `inspectCapability(for:resetDate:)`: asynchronous live read-only `pmset` support inspection.
- `hasActiveLease(_:)`: a recovery record exists; **not** proof an apply succeeded.
- `pendingRestorations`: persisted non-secret recovery records, including failed/canceled/partial operations.
- `operationInProgress`, `lastError`, and `onChange`: UI feedback.

The service is **not a drop-in autonomous privileged helper**. Because it does not install one or retain credentials, changing a protected setting on close and restoring on open cannot be promised to work invisibly. The parent UI must explain/obtain authorization and expose pending restoration, or keep the component unavailable for fully automatic operation. Do not call `apply`/`restore` unconditionally from `ComponentEngine.tick()`.

## Safety and recovery

1. Read `pmset -g custom`; only closed-enum setting/source names and validated integers can reach script generation.
2. Save the old and requested values to UserDefaults **before** requesting authorization. These are non-secret recovery data. A crash/canceled dialog may leave a pending record even if no write happened.
3. Immediately after the administrator dialog, the generated script rereads relevant settings and refuses changes if they no longer match the snapshot. No arbitrary caller-provided command, path, environment override, executable, or root RPC exists.
4. After apply, read back and verify. Failure retains the recovery record and must leave the component reported inactive/error.
5. Restore the exact prior values, not assumed defaults. Refuse restoration if another tool changed a setting to a third value. This protects external edits; the UI must resolve that conflict rather than overwrite blindly.
6. Apply is not fully atomic: if a later `pmset` command fails, earlier changes may have occurred. The persisted recovery record is intentionally retained for explicit restoration. No hidden best-effort rollback is reported as success.
7. Restore requires current settings to match either prior or requested state, and checks again after authorization. There remains a small read/write race with other power-setting tools because macOS supplies no transaction lock shared with them.
8. Owned wake requests are canceled individually. A fired/already-removed owned wake needs no cancellation. Other applications' wake schedules are never canceled.
9. No root/system writes have been executed during implementation or tests. Only read-only `pmset -g custom`, `-g cap`, and `-g sched` discovery was performed.

## Pure tests

```sh
swiftc -swift-version 5 -module-cache-path build/componentcache \
  Sources/PrivilegedComponentService.swift Tests/PrivilegedComponentServiceTests.swift \
  -o build/test-protected-components
build/test-protected-components
```

Tests only parse fixtures, build plans and scripts, and reject invalid operations/data. They do not invoke `apply`, `restore`, `pmset`, `osascript`, administrator dialogs, installations, scheduled events, or real power changes.
