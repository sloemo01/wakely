"""Source-contract guards for permission intent/presentation generations.

These complement the policy tests. They only inspect source; they never prompt,
open System Settings, or mutate an enabled component.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
permissions = (root / "Sources/ComponentPermissions.swift").read_text()
settings = (root / "Sources/SettingsUI.swift").read_text()

assert "enableIntentGeneration" in permissions
assert "presentationGeneration" in permissions
assert "autoCloseTask" in permissions
assert "enableIntentGeneration == intent" in permissions
assert "presentation == presentationGeneration" in permissions
assert "scheduleAutoClose" in permissions
assert "self.presentationGeneration == token" in permissions
assert "presentRequirementsIfNeeded(" in permissions
assert "isRouteCurrent" in permissions
assert "route: event.sessionID" in settings
assert "presentation.session?.id == event.sessionID" in settings
assert "DispatchQueue.main.asyncAfter(deadline: .now() + 0.6)" not in permissions, (
    "Ready auto-close must be owned and token-guarded, not an unguarded sleep"
)
print("PASS: permission intent, presentation token and route-keyed setup guards")
