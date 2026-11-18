#!/bin/sh
# Inspect and remove a stale Wakely helper LaunchDaemon.
#
# Why this exists: an earlier build registered a daemon whose plist used
# BundleProgram. When that app bundle was removed, launchd kept retrying a
# program it could not resolve ("spawn failed", exit 78). The job is inert but
# noisy, and a leftover root job should not be left pointing at a bundle path.
#
# This script never runs anything privileged unless you pass --apply, and it
# still asks for your administrator password through sudo.
#
# Usage:
#   tools/fix-stale-helper-job.sh            # inspect only
#   tools/fix-stale-helper-job.sh --apply   # boot out and delete the job

set -eu

LABEL="dev.wakely.helper"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

echo "== job"
if launchctl print "system/${LABEL}" 2>/dev/null | sed -n '1,12p'; then :; else
  echo "no ${LABEL} job is registered"
fi

echo
echo "== plist"
if [ -f "$PLIST" ]; then
  ls -l "$PLIST"
  /usr/bin/plutil -p "$PLIST" 2>/dev/null | sed -n '1,20p'
  echo
  echo "The job uses BundleProgram, which only resolves relative to an app"
  echo "bundle registered with ServiceManagement. If that bundle is gone, the"
  echo "daemon cannot start and should be removed."
else
  echo "no $PLIST"
fi

echo
echo "== process"
if /usr/bin/pgrep -x WakelyHelper >/dev/null 2>&1; then
  echo "a WakelyHelper process is running; do not remove the job while it is"
  echo "actively restoring settings. Quit Wakely first, then re-run."
  exit 1
fi
echo "no WakelyHelper process is running"

if [ "${1:-}" != "--apply" ]; then
  echo
  echo "Inspection only. To remove the stale job, run:"
  echo "  $0 --apply"
  echo "You will be asked for your administrator password."
  exit 0
fi

echo
echo "== removing (administrator password required)"
sudo /bin/launchctl bootout "system/${LABEL}" 2>/dev/null || true
sudo /bin/rm -f "$PLIST"
if [ -e "$PLIST" ]; then
  echo "the plist is still present; nothing else was changed" >&2
  exit 1
fi
if sudo /bin/launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  echo "the job is still registered; check launchctl manually" >&2
  exit 1
fi
echo "removed ${LABEL}"
echo "Wakely will register a correct service only when you approve one"
echo "through System Settings > General > Login Items & Extensions."
