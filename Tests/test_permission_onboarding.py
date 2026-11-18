#!/usr/bin/env python3
"""Source-contract tests, not a live TCC or input-lock test."""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PermissionIntegrationTests(unittest.TestCase):
    def test_every_catalog_component_is_audited(self):
        catalog = set(re.findall(r'ComponentDefinition\(id: "([^"]+)"',
                                 (ROOT / 'Sources/ComponentCatalog.swift').read_text()))
        audit = (ROOT / 'plans/component-behavior-audit.md').read_text()
        audited = set(re.findall(r'^\| ([A-Za-z0-9]+) \|', audit, re.M))
        self.assertEqual(len(catalog), 31)
        self.assertEqual(catalog, audited)

    def test_usage_strings(self):
        info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
        self.assertTrue(info['NSLocationUsageDescription'])
        self.assertTrue(info['NSLocationWhenInUseUsageDescription'])

    def test_engine_gate_is_not_only_ui(self):
        source = (ROOT / 'Sources/ComponentBehaviors.swift').read_text()
        self.assertIn('ComponentPermissions.shared.interceptEnable(id, on: on)', source)
        self.assertIn('guard id != "cleaningLock" else { return false }', source)
        self.assertIn('if on, id == "cleaningLock"', source)
        self.assertIn('beginCleaningLock(seconds:', source)
        self.assertIn('ComponentEngine.shared.isEnabled("ejectOnSleep")', source)

    def test_switch_only_cleaning_lock(self):
        ui = (ROOT / 'Sources/SettingsUI.swift').read_text()
        self.assertNotIn('Button("Lock now")', ui)
        controller = (ROOT / 'Sources/CleaningLockController.swift').read_text()
        self.assertIn('guard CGEvent.tapIsEnabled(tap: port)', controller)
        self.assertNotIn('NSApp.activate(ignoringOtherApps: true)', controller)
        self.assertNotIn('foreignAppSince', controller)
        self.assertIn('ComponentEngine.shared.setEnabled("cleaningLock", false)', controller)
        self.assertIn('DispatchQueue.global', controller)  # independent escape deadline

    def test_native_notifications_and_sleep(self):
        feedback = (ROOT / 'Sources/Feedback.swift').read_text()
        self.assertIn('WakelyNotifications.shared.post', feedback)
        self.assertNotIn('display notification', feedback)
        behavior = (ROOT / 'Sources/ComponentBehaviors.swift').read_text()
        self.assertIn('IOPMSleepSystem(connection)', behavior)
        self.assertNotIn('tell application \\"System Events\\" to sleep', behavior)

    def test_panel_cancellation_and_drag(self):
        source = (ROOT / 'Sources/ComponentPermissions.swift').read_text()
        self.assertIn('Bundle.main.bundleURL as NSURL', source)
        self.assertIn('activateFileViewerSelecting([Bundle.main.bundleURL])', source)
        self.assertIn('func hidePresentation', source)
        self.assertIn('setupPresented', source)
        self.assertNotIn('NSWindow(contentRect', source)
        self.assertIn('pendingEnable = nil', source)
        self.assertIn('resumesEnableAfterGrant(id)', source)
        self.assertNotIn('AXIsProcessTrustedWithOptions', source)

    def test_helper_registration_is_not_reachability(self):
        helper = (ROOT / 'Sources/HelperClient.swift').read_text()
        self.assertIn('if await isReachable()', helper)
        self.assertIn('daemonService.unregister()', helper)
        permissions = (ROOT / 'Sources/ComponentPermissions.swift').read_text()
        self.assertIn('helperReachable', permissions)
        self.assertIn('installed — not reachable yet', permissions)

    def test_no_hardcoded_keychain_unlock(self):
        build = (ROOT / 'build.sh').read_text()
        self.assertNotIn('security unlock-keychain', build)
        self.assertNotIn(' -p wakely', build)
        self.assertTrue((ROOT / 'package-dmg.sh').exists())

if __name__ == '__main__':
    unittest.main()
