"""Structural contract for the deletion watcher and the helper self-clean.

The pure decision table is tested by Tests/UninstallWatcherPolicyTests.swift
(compiled by run-tests.sh). This pass pins the wiring: the watcher binary is
built and signed, the app installs it on every launch, Delete Wakely retires
it, the helper watches for the app's absence, and the app/helper/watcher agree
on the install-record wire shape. No launchd, XPC or file system is touched.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]

policy = (root / "UninstallWatcher/Policy.swift").read_text()
presence = (root / "UninstallWatcher/Presence.swift").read_text()
watcher_main = (root / "UninstallWatcher/main.swift").read_text()
installer = (root / "Sources/UninstallWatcherInstaller.swift").read_text()
install_record = (root / "Sources/InstallRecord.swift").read_text()
app_delegate = (root / "Sources/AppDelegate.swift").read_text()
app_uninstaller = (root / "Sources/AppUninstaller.swift").read_text()
helper_main = (root / "Helper/main.swift").read_text()
app_removal = (root / "Helper/AppRemoval.swift").read_text()
operations = (root / "Helper/Operations.swift").read_text()
sleep_controller = (root / "Sources/SleepUntilResetController.swift").read_text()
build = (root / "build.sh").read_text()
continuity = (root / "Tools/Signing/verify-continuity.py").read_text()

# --- Purity of the shared policy file ---------------------------------------

assert "import AppKit" not in policy and "import ServiceManagement" not in policy, (
    "UninstallWatcher/Policy.swift must stay Foundation-only"
)
assert "FileManager" not in policy and "Process(" not in policy, (
    "UninstallWatcher/Policy.swift must stay pure: no file system, no processes"
)

# --- Watcher binary: built, signed, self-retiring ----------------------------

assert "UninstallWatcher/Policy.swift UninstallWatcher/Presence.swift UninstallWatcher/main.swift" in build, (
    "build.sh must compile the uninstall watcher from its three sources"
)
assert 'Contents/MacOS/WakelyUninstallWatcher' in build, "build.sh must place the watcher in the bundle"
assert 'signing_id="dev.wakely.uninstall-watcher"' in build, (
    "build.sh must sign the watcher with its own stable identifier"
)
assert "'Contents/MacOS/WakelyUninstallWatcher': 'dev.wakely.uninstall-watcher'" in continuity, (
    "verify-continuity.py must know the watcher's signing identity"
)

assert "KeepAlive" in installer and "true" in installer, (
    "the watcher agent plist must keep the job alive while the app is gone"
)
assert "RunAtLoad" in installer, "the watcher must start at login"
assert "WakelyUninstallWatcher.new" in installer, "the installer must replace changed bytes atomically"
assert '"kickstart", "-k"' in installer, (
    "a replaced watcher binary must restart the running job, or old code survives until logout"
)
assert installer.index("if !isLoaded()") < installer.index("let loaded = isLoaded()"), (
    "the installer must re-bootstrap a job that is not loaded, or cleanup stays disabled"
)

# App-side mirrors of the policy constants (the app test builds compile
# Sources/*.swift without UninstallWatcher/, so the values are inlined).
for symbol, source in [
    ("agentLabel", installer),
    ("agentPlistName", installer),
    ("installRecordFileName", install_record),
]:
    expected = re.search(rf"{symbol} = \"([^\"]+)\"", policy).group(1)
    assert f'"{expected}"' in source, (
        f"{source.splitlines()[0]} must mirror UninstallWatcherPolicy.{symbol} = {expected!r}"
    )

# The watcher must bootout ITSELF last: bootout kills the process, so any
# removal after it would never run.
wipe_body = watcher_main.split("private func wipeEverything", 1)[1]
bootout_self = wipe_body.rfind("bootout")
assert bootout_self > wipe_body.find("removeItem(supportDirectory())"), (
    "the watcher must remove the support directory BEFORE booting itself out"
)
assert wipe_body.rfind("removeItem(") < bootout_self, (
    "no file removal may happen after the self-bootout"
)
assert "tccutil" in wipe_body and "reset" in wipe_body and "All" in wipe_body, (
    "the wipe must reset TCC grants for the bundle id"
)
assert "defaults" in wipe_body and "delete" in wipe_body, "the wipe must delete the defaults domain"
assert "dev.wakely.agent" in wipe_body, "the wipe must retire the crash watchdog agent"
assert "agentPlistName" in wipe_body, "the wipe must remove its own plist"

# --- App wiring --------------------------------------------------------------

assert "InstallRecord.publish()" in app_delegate, "the app must publish its install location on launch"
assert "UninstallWatcherInstaller.installIfNeeded()" in app_delegate, (
    "the app must keep the deletion watcher installed on every launch"
)
assert "UninstallWatcherInstaller.uninstall()" in app_uninstaller, (
    "Delete Wakely must retire the watcher so it cannot race the uninstaller"
)

# --- Install-record wire agreement -------------------------------------------

record_fields = set(re.findall(r"var (\w+):", install_record.split("struct Record", 1)[1].split("}", 1)[0]))
assert "appPath" in record_fields and "bundleID" in record_fields, (
    "the install record must carry the app path and bundle id"
)
assert 'appPath' in presence and '"appPath"' not in presence or "appPath" in presence, (
    "the watcher presence probe must read the appPath field"
)
policy_name = re.search(r'installRecordFileName = "([^"]+)"', policy)
assert policy_name and policy_name.group(1) in install_record, (
    "the app and the watcher must agree on the install record file name"
)

# --- Move/rename/update safety ----------------------------------------------

# The path list alone cannot tell "trashed" from "moved to another folder" or
# "renamed": both vanish from the candidates. Spotlight still knows the bundle
# (the Trash is not indexed), so presence must consult it in BOTH wipers.
assert "spotlightFindsApp" in presence, "WakelyPresence must probe Spotlight"
assert "/usr/bin/mdfind" in presence and "kMDItemCFBundleIdentifier" in presence, (
    "the Spotlight probe must query by bundle identifier"
)
assert ".Trash" in presence, "the Spotlight probe must exclude the Trash"
assert "spotlightFindsApp" in watcher_main, "the user watcher must consult Spotlight"
assert "spotlightFindsApp" in app_removal, "the helper self-clean must consult Spotlight"

# A LaunchDaemon's own home is /var/root; probing it would miss the user's
# install record and ~/Applications copy, so the helper must target the
# console user's home.
assert "consoleHomeDirectory" in app_removal and "/dev/console" in app_removal, (
    "the helper must resolve the console user's home, not /var/root"
)
assert "userSupportDirectory(homeDirectory:" in app_removal, (
    "the helper must read the install record under the console user's home"
)

# --- Helper self-clean --------------------------------------------------------

assert "HelperAppRemoval.watchUntilAppReturnsOrWipe" in helper_main, (
    "the helper daemon must watch for the app's absence"
)
assert "DispatchQueue.global" in helper_main, "the helper watch must not block the XPC listener"
assert "system/" in app_removal and "bootout" in app_removal, "the helper must boot out its own system job"
for path in ["/Library/LaunchDaemons/", "/Library/PrivilegedHelperTools/", "/Library/Application Support/dev.wakely.helper"]:
    assert path in app_removal, f"the helper self-clean must cover {path}"
# Same ordering rule as the watcher: bootout last.
removal_body = app_removal.split("static func wipeAndExit", 1)[1]
assert removal_body.find("bootout") > removal_body.rfind("removeItem"), (
    "the helper must remove its files BEFORE booting itself out"
)
assert "WakelyPresence.appIsRunning" in app_removal or "appIsRunning" in app_removal, (
    "the helper must not wipe while any Wakely process runs"
)
assert "UninstallWatcherPolicy.daemonAbsentChecksBeforeWipe" in app_removal, (
    "the helper must use the longer daemon grace"
)

# --- Deletion must be positively confirmed, never inferred from absence ----

assert "trashContainsApp" in presence, (
    "the watcher needs a Trash probe: absence alone must never wipe"
)
assert "deletionConfirmed" in policy and "deletionConfirmed" in watcher_main, (
    "the decision must require positive Trash evidence"
)
assert watcher_main.index("trashContainsApp") < watcher_main.index("UninstallWatcherPolicy.decide"), (
    "the watcher must scan the Trash before deciding"
)
assert "trashContainsApp" in app_removal, (
    "the helper daemon must also require Trash evidence before wiping"
)
# macOS privacy protection bars a LaunchDaemon from reading the user's
# Trash, so the watcher hands the helper a fresh marker instead.
assert "writeDeletionMarker" in watcher_main, (
    "the watcher must leave deletion evidence for the helper daemon"
)
assert "deletionMarkerIsFresh" in app_removal, (
    "the helper must accept the watcher's fresh deletion marker"
)
assert "expectedOwnerID" in presence and "expectedOwnerID" in app_removal, (
    "the marker is world-writable in /tmp, so the helper must verify the console user's ownership"
)
assert "removeItem(atPath: WakelyPresence.deletionMarkerPath)" in app_removal, (
    "the helper must remove the marker once the wipe it authorized is done"
)
assert app_removal.index("restoreEverythingBeforeDeletion") < app_removal.index("removeItem(atPath: WakelyPresence.deletionMarkerPath)"), (
    "the marker is removed only after the rollback it authorized ran"
)

# --- System changes roll back before any wipe --------------------------------

assert "restoreEverythingBeforeDeletion" in operations, (
    "the helper must be able to roll back settings and wakes without a client"
)
assert "WakeStore" in operations and "scheduler.cancel" in operations, (
    "the delete rollback must cancel owned pending wakes"
)
# Rollback runs BEFORE the root data directory (which holds the backup
# store) is deleted.
assert app_removal.index("restoreEverythingBeforeDeletion") < app_removal.index("removeItem(atPath: rootDataPath)"), (
    "the helper must roll back system changes before deleting its records"
)
assert "cancelOwnedWakesForDelete" in app_uninstaller, (
    "Delete Wakely must cancel pending wakes before removing the helper"
)

print("uninstall watcher structure: all checks passed")

installer_src = (ROOT / "Sources/UninstallWatcherInstaller.swift").read_text() if "ROOT" in globals() else open("Sources/UninstallWatcherInstaller.swift").read()
assert "Pipe()" not in installer_src, "launchctl output is never left in an unread Pipe (blocks app launch)"
