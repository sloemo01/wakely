"""Structural wiring for Sleep Means Sleep; no helper or pmset command runs."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = root / "Sources"
helper = root / "Helper"
catalog = (src / "ComponentCatalog.swift").read_text()
capability = (src / "ComponentCapability.swift").read_text()
behaviors = (src / "ComponentBehaviors.swift").read_text()
settings = (src / "SettingsUI.swift").read_text()
protocol_text = (src / "HelperProtocol.swift").read_text()
operations = (helper / "Operations.swift").read_text()
policy = (helper / "WakeSourceSuppression.swift").read_text()

assert "scheduled wakes are skipped" not in catalog, "the old overpromise must be gone"
assert "Power Nap, proximity wake and Wake-on-LAN" in catalog
assert "Other apps' scheduled wake events are left alone" in catalog
assert '"sleepMeansSleep", status: .partial' in capability
assert "powernap, proximitywake and womp" in capability
assert "Manual-only" not in settings and "switch stays off" not in settings
assert "battery Power Nap, proximity wake and Wake-on-LAN" in settings

assert "case suppressWakeSources" in protocol_text
assert 'public static let protocolVersion = "5"' in protocol_text
assert "case .autoRestartAfterPowerLoss, .bootOnLidOpen, .suppressWakeSources:" in protocol_text

for contract in (
    "case .suppressWakeSources:",
    "setWakeSourcesSuppressed(componentID:",
    "readBatteryWakeSources()",
    "applyBatteryWakeSource(key, value: 0)",
    "WakeSourceSuppression.restoration(",
    'capability("suppressWakeSources"',
):
    assert contract in operations, f"missing helper wiring: {contract}"

for contract in (
    "Step(componentID: \"sleepMeansSleep\", action: .suppressWakeSources",
    '"homeServer", "stayOffWhenOpened", "sleepMeansSleep"',
    'case "sleepMeansSleep": return "suppressWakeSources"',
    "case .suppressWakeSources:",
    "api.suppressWakeSources()",
    'case "suppressWakeSources": return .suppressWakeSources',
):
    assert contract in behaviors, f"missing component-engine wiring: {contract}"

main = (src / "main.swift").read_text()
assert '"--test-wake-source-suppression"' in main
assert 'api.suppressWakeSources()' in main and 'api.restore(component: "sleepMeansSleep")' in main

assert "if isEnabled(\"sleepMeansSleep\") { noopHelper" not in behaviors
assert "noopHelper" not in behaviors
assert "Cannot" not in policy and "sudo" not in policy
assert "settingNames" in policy and "powernap" in policy and "womp" in policy
print("PASS: Sleep Means Sleep is wired through the shared helper, has an owned lease and no manual-only dead end")
