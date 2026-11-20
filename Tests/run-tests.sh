#!/bin/bash
# Pure/unit test suite. Nothing here launches the app, changes system settings,
# touches the keyboard lock state, or prompts for permissions.
set -uo pipefail
cd "$(dirname "$0")/.."
BUILD_CACHE="${WAKELY_BUILD_CACHE:-$HOME/Library/Caches/Wakely/build}"
mkdir -p "$BUILD_CACHE"

SWIFTC=(xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -module-cache-path "$BUILD_CACHE")
FRAMEWORKS=(-framework AppKit -framework IOKit -framework AVFoundation -framework Network)
mkdir -p build/tests
fail=0

run() {
  local name="$1"; shift
  printf '== %s\n' "$name"
  if "$@" >/tmp/wakely-test-$name.log 2>&1; then
    echo "   PASS"
  else
    echo "   FAIL"; tail -20 /tmp/wakely-test-$name.log; fail=1
  fi
}

run card-morph "${SWIFTC[@]}" Sources/CardMorphModel.swift Tests/CardMorphModelTests.swift -o build/tests/card-morph
[[ -x build/tests/card-morph ]] && run card-morph-run build/tests/card-morph
run card-presentation "${SWIFTC[@]}" Sources/CardMorphModel.swift Tests/CardMorphPresentationTests.swift -o build/tests/card-presentation
[[ -x build/tests/card-presentation ]] && run card-presentation-run build/tests/card-presentation
run card-route-model "${SWIFTC[@]}" -framework SwiftUI -framework AppKit Sources/CardMorphModel.swift Sources/CardMorphPresentation.swift Tests/CardMorphPresentationModelTests.swift -o build/tests/card-route-model
[[ -x build/tests/card-route-model ]] && run card-route-model-run build/tests/card-route-model

run goo-shape "${SWIFTC[@]}" Sources/GooShape.swift Tests/GooShapeTests.swift -o build/tests/goo-shape
[[ -x build/tests/goo-shape ]] && run goo-shape-run build/tests/goo-shape
run goo-panel-motion "${SWIFTC[@]}" Sources/GooShape.swift Sources/GooPanelLayout.swift Tests/GooPanelMotionTests.swift -o build/tests/goo-panel-motion
[[ -x build/tests/goo-panel-motion ]] && run goo-panel-motion-run build/tests/goo-panel-motion
run goo-coordinator "${SWIFTC[@]}" Sources/GooShape.swift Sources/GooPanelLayout.swift Sources/GooMotionCoordinator.swift Tests/GooMotionCoordinatorTests.swift -o build/tests/goo-coordinator
[[ -x build/tests/goo-coordinator ]] && run goo-coordinator-run build/tests/goo-coordinator
run goo-menu python3 Tests/test_goo_menu.py
run torph-text "${SWIFTC[@]}" Sources/TorphText.swift Tests/TorphTextTests.swift -o build/tests/torph-text
[[ -x build/tests/torph-text ]] && run torph-text-run build/tests/torph-text

run inline-value "${SWIFTC[@]}" Sources/InlineValueModel.swift Tests/InlineValueModelTests.swift -o build/tests/inline-value
[[ -x build/tests/inline-value ]] && run inline-value-run build/tests/inline-value
run inline-interaction python3 Tests/test_inline_interaction_regressions.py
run appearance "${SWIFTC[@]}" -framework AppKit -framework SwiftUI Sources/AppAppearance.swift Tests/AppAppearanceTests.swift -o build/tests/appearance
[[ -x build/tests/appearance ]] && run appearance-run build/tests/appearance
run scroll-edges "${SWIFTC[@]}" Sources/ScrollEdgeState.swift Tests/ScrollEdgeStateTests.swift -o build/tests/scroll-edges
[[ -x build/tests/scroll-edges ]] && run scroll-edges-run build/tests/scroll-edges
run glass-policy "${SWIFTC[@]}" Sources/GlassSurfacePolicy.swift Tests/GlassSurfacePolicyTests.swift -o build/tests/glass-policy
[[ -x build/tests/glass-policy ]] && run glass-policy-run build/tests/glass-policy
run local-signing python3 Tests/test_local_signing.py
run keep-awake-selection "${SWIFTC[@]}" Sources/KeepAwakeSelection.swift Tests/KeepAwakeSelectionTests.swift -o build/tests/keep-awake-selection
[[ -x build/tests/keep-awake-selection ]] && run keep-awake-selection-run build/tests/keep-awake-selection
run keep-awake-options python3 Tests/test_keep_awake_options.py
run update-version "${SWIFTC[@]}" Sources/UpdateVersion.swift Tests/UpdateVersionTests.swift -o build/tests/update-version
[[ -x build/tests/update-version ]] && run update-version-run build/tests/update-version
run uninstall-watcher-policy "${SWIFTC[@]}" UninstallWatcher/Policy.swift Tests/UninstallWatcherPolicyTests.swift -o build/tests/uninstall-watcher-policy
[[ -x build/tests/uninstall-watcher-policy ]] && run uninstall-watcher-policy-run build/tests/uninstall-watcher-policy
run uninstall-watcher-structure python3 Tests/test_uninstall_watcher.py
run agent-screen-structure python3 Tests/test_agent_screen.py
run update-restart-structure python3 Tests/test_update_restart.py
run typography-scale "${SWIFTC[@]}" Sources/Typography.swift Tests/TypographyMetricsTests.swift -o build/tests/typography-scale
[[ -x build/tests/typography-scale ]] && run typography-scale-run build/tests/typography-scale
run guide-content "${SWIFTC[@]}" Sources/ComponentCatalog.swift Sources/GuideContent.swift Tests/GuideContentTests.swift -o build/tests/guide-content
[[ -x build/tests/guide-content ]] && run guide-content-run build/tests/guide-content
run onboarding-policy "${SWIFTC[@]}" Sources/OnboardingPolicy.swift Tests/OnboardingPolicyTests.swift -o build/tests/onboarding-policy
[[ -x build/tests/onboarding-policy ]] && run onboarding-policy-run build/tests/onboarding-policy
run guide-playback "${SWIFTC[@]}" Sources/GuidePlayback.swift Tests/GuidePlaybackTests.swift -o build/tests/guide-playback
[[ -x build/tests/guide-playback ]] && run guide-playback-run build/tests/guide-playback
run guide-coordinator "${SWIFTC[@]}" -framework AppKit Sources/ComponentCatalog.swift Sources/GuideContent.swift Sources/OnboardingPolicy.swift Sources/GuideCoordinator.swift Tests/GuideCoordinatorTests.swift -o build/tests/guide-coordinator
[[ -x build/tests/guide-coordinator ]] && run guide-coordinator-run build/tests/guide-coordinator
run brand-icon-stroke "${SWIFTC[@]}" -framework AppKit Sources/BrandIcon.swift Tests/BrandIconStrokeTests.swift -o build/tests/brand-icon-stroke
[[ -x build/tests/brand-icon-stroke ]] && run brand-icon-stroke-run build/tests/brand-icon-stroke
run guide-integration python3 Tests/test_guides_integration.py
run visual-system python3 Tests/test_visual_system.py
run app-motion python3 Tests/test_app_motion.py
run switch-drag "${SWIFTC[@]}" Sources/SwitchDragPolicy.swift Tests/SwitchDragPolicyTests.swift -o build/tests/switch-drag
run component-outcomes python3 Tests/test_component_outcomes.py
[[ -x build/tests/switch-drag ]] && run switch-drag-run build/tests/switch-drag

run component-defaults "${SWIFTC[@]}" Sources/ComponentDefaults.swift Tests/ComponentDefaultsTests.swift -o build/tests/component-defaults
[[ -x build/tests/component-defaults ]] && run component-defaults-run build/tests/component-defaults

run arm-policy "${SWIFTC[@]}" Sources/ArmPolicy.swift Tests/ArmPolicyTests.swift -o build/tests/arm-policy
[[ -x build/tests/arm-policy ]] && run arm-policy-run build/tests/arm-policy

run permission-policy "${SWIFTC[@]}" Sources/ComponentPermissionPolicy.swift Sources/ComponentCatalog.swift Tests/ComponentPermissionPolicyTests.swift -o build/tests/permission-policy
[[ -x build/tests/permission-policy ]] && run permission-policy-run build/tests/permission-policy
run permission-integration python3 Tests/test_permission_onboarding.py
run permission-generations python3 Tests/test_permission_generation.py

run component-enablement-lifecycle "${SWIFTC[@]}" Sources/ComponentBehaviorPolicy.swift Tests/ComponentEnablementLifecycleTests.swift -o build/tests/component-enablement-lifecycle
[[ -x build/tests/component-enablement-lifecycle ]] && run component-enablement-lifecycle-run build/tests/component-enablement-lifecycle

run component-policy "${SWIFTC[@]}" Sources/ComponentBehaviorPolicy.swift Tests/ComponentBehaviorPolicyTests.swift -o build/tests/component-policy
[[ -x build/tests/component-policy ]] && run component-policy-run build/tests/component-policy

run caps-lifecycle "${SWIFTC[@]}" -framework Carbon Sources/CapsLockLight.swift Tests/CapsLockLifecycleTests.swift -o build/tests/caps-lifecycle
[[ -x build/tests/caps-lifecycle ]] && run caps-lifecycle-run build/tests/caps-lifecycle

run protected "${SWIFTC[@]}" Sources/PrivilegedComponentService.swift Tests/PrivilegedComponentServiceTests.swift -o build/tests/protected
[[ -x build/tests/protected ]] && run protected-run build/tests/protected

run component-capability "${SWIFTC[@]}" Sources/ComponentCapability.swift Sources/ComponentCatalog.swift Tests/ComponentCapabilityTests.swift -o build/tests/component-capability
[[ -x build/tests/component-capability ]] && run component-capability-run build/tests/component-capability

run component-validator "${SWIFTC[@]}" Sources/ComponentValidator.swift Tests/ComponentValidatorTests.swift -o build/tests/component-validator
[[ -x build/tests/component-validator ]] && run component-validator-run build/tests/component-validator

run component-store "${SWIFTC[@]}" -framework AppKit Sources/ComponentValidator.swift Sources/ComponentKitLauncher.swift Sources/Components.swift Sources/LegacyVocabulary.swift Tests/ComponentStoreTests.swift -o build/tests/component-store
[[ -x build/tests/component-store ]] && run component-store-run build/tests/component-store

run component-kit-launcher "${SWIFTC[@]}" Sources/ComponentKitLauncher.swift Tests/ComponentKitLauncherTests.swift -o build/tests/component-kit-launcher
[[ -x build/tests/component-kit-launcher ]] && run component-kit-launcher-run build/tests/component-kit-launcher

run agent-state "${SWIFTC[@]}" Sources/AgentTaskState.swift Sources/AgentMonitor.swift Sources/AgentAppSessionState.swift Tests/AgentTaskStateTests.swift -o build/tests/agent-state
[[ -x build/tests/agent-state ]] && run agent-state-run build/tests/agent-state

run agent-display-policy "${SWIFTC[@]}" Sources/AgentTaskState.swift Sources/AgentMonitor.swift Sources/AgentAppSessionState.swift Sources/AgentDisplayPolicy.swift Tests/AgentDisplayPolicyTests.swift -o build/tests/agent-display-policy
[[ -x build/tests/agent-display-policy ]] && run agent-display-policy-run build/tests/agent-display-policy

run custom-screens "${SWIFTC[@]}" Sources/SupportPaths.swift Sources/CustomScreens.swift Tests/CustomScreensTests.swift -o build/tests/custom-screens
[[ -x build/tests/custom-screens ]] && run custom-screens-run build/tests/custom-screens
run custom-screens-contract python3 Tests/test_custom_screens.py


run brightness python3 Tests/test_shared_engine_brightness.py
run power-lifecycle python3 Tests/test_power_lifecycle.py
run shutdown-lifecycle python3 Tests/test_shutdown_lifecycle.py
run protected-recovery "${SWIFTC[@]}" Sources/ProtectedRecoveryPolicy.swift Tests/ProtectedRecoveryPolicyTests.swift -o build/tests/protected-recovery
[[ -x build/tests/protected-recovery ]] && run protected-recovery-run build/tests/protected-recovery

run password-after-close-policy "${SWIFTC[@]}" Sources/PasswordAfterClosePolicy.swift Tests/PasswordAfterClosePolicyTests.swift -o build/tests/password-after-close-policy
[[ -x build/tests/password-after-close-policy ]] && run password-after-close-policy-run build/tests/password-after-close-policy

run screen-lock "${SWIFTC[@]}" -framework CoreGraphics Sources/ScreenLockObserver.swift Tests/ScreenLockObserverTests.swift -o build/tests/screen-lock
[[ -x build/tests/screen-lock ]] && run screen-lock-run build/tests/screen-lock

run home-server-policy "${SWIFTC[@]}" Sources/HomeServerPolicy.swift Tests/HomeServerPolicyTests.swift -o build/tests/home-server-policy
[[ -x build/tests/home-server-policy ]] && run home-server-policy-run build/tests/home-server-policy
run close-gesture python3 Tests/test_close_gesture.py
run feedback-chime python3 Tests/test_feedback_chime.py

run helper-peer "${SWIFTC[@]}" -framework Security Helper/PeerAuthentication.swift Tests/HelperPeerAuthenticationTests.swift -o build/tests/helper-peer
if [[ -x build/tests/helper-peer ]]; then
  run helper-peer-sign /usr/bin/codesign --force --sign - --identifier dev.wakely.app build/tests/helper-peer
  run helper-peer-run build/tests/helper-peer --expect-adhoc
fi

run power-restore "${SWIFTC[@]}" Helper/PowerSettingRestorePolicy.swift Tests/PowerSettingRestorePolicyTests.swift -o build/tests/power-restore
[[ -x build/tests/power-restore ]] && run power-restore-run build/tests/power-restore

run wake-source-suppression "${SWIFTC[@]}" Helper/WakeSourceSuppression.swift Tests/WakeSourceSuppressionTests.swift -o build/tests/wake-source-suppression
[[ -x build/tests/wake-source-suppression ]] && run wake-source-suppression-run build/tests/wake-source-suppression
run sleep-means-sleep python3 Tests/test_sleep_means_sleep.py

run request-journal "${SWIFTC[@]}" Sources/HelperProtocol.swift Helper/RequestJournal.swift Tests/RequestJournalTests.swift -o build/tests/request-journal
[[ -x build/tests/request-journal ]] && run request-journal-run build/tests/request-journal

run wake-scheduling "${SWIFTC[@]}" Sources/HelperProtocol.swift Helper/WakeStore.swift Tests/WakeSchedulingTests.swift -o build/tests/wake-scheduling
[[ -x build/tests/wake-scheduling ]] && run wake-scheduling-run build/tests/wake-scheduling

run usage-reset-policy "${SWIFTC[@]}" Sources/UsageResetReader.swift Sources/UsageResetPolicy.swift Tests/UsageResetPolicyTests.swift -o build/tests/usage-reset-policy
[[ -x build/tests/usage-reset-policy ]] && run usage-reset-policy-run build/tests/usage-reset-policy

run usage-reset-reader "${SWIFTC[@]}" Sources/UsageResetReader.swift Tests/SleepUntilResetReaderTests.swift -o build/tests/usage-reset-reader
[[ -x build/tests/usage-reset-reader ]] && run usage-reset-reader-run build/tests/usage-reset-reader

run helper-client python3 Tests/test_helper_client_policy.py
run sleep-until-reset python3 Tests/test_sleep_until_reset.py
run protected-policy python3 Tests/test_protected_component_policy.py
run fan-policy python3 Tests/test_fan_policy.py
run fan-restore-policy python3 Tests/test_fan_restore_policy.py
run touchid-helper-policy python3 Tests/test_touchid_helper_policy.py
run boot-preference-policy python3 Tests/test_boot_preference_policy.py
run password-after-close python3 Tests/test_password_after_close.py
run home-server python3 Tests/test_home_server.py

run menu python3 Tests/test_menu_bar.py

# Independent component tooling: launcher compiles the shared manifest validator
# into build/tools and runs entirely in a temp directory.
run component-tool python3 Tests/test_component_tool.py
run component-kit-contract python3 Tests/test_component_kit_contract.py
run sprite-art python3 -m unittest Tests.test_sprites Tests.test_sprite_art Tests.test_idle_sprites Tests.test_selected_redesign_sprites
run sprite-states python3 Tests/test_sprite_states.py
run watchdog-policy python3 Tests/test_watchdog_policy.py

run sounds "${SWIFTC[@]}" -parse-as-library Tests/SoundResourcesTests.swift -o build/tests/sounds
[[ -x build/tests/sounds ]] && run sounds-run build/tests/sounds Resources

exit $fail
