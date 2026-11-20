"""Agent Screen keeps a closed Mac's screen usable for agents."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
power = (root / "Sources/PowerEngine.swift").read_text()
behaviors = (root / "Sources/ComponentBehaviors.swift").read_text()


def body(source, signature):
    return source.split(signature, 1)[1].split("\n    }\n", 1)[0]


close = body(power, "private func beginClosedSession()")
skip = close.split('isEnabled("agentScreen")', 1)
assert len(skip) == 2, "an armed close checks Agent Screen"
kept, otherwise = skip[1].split("} else {", 1)
assert "requestLockScreen()" not in kept and "sleepDisplays" not in kept, \
    "with Agent Screen on, an armed close neither locks nor sleeps the display"
assert "requestLockScreen()" in otherwise and "sleepDisplaysUnlessAgentsNeedThem()" in otherwise, \
    "with Agent Screen off, an armed close still locks and sleeps the display"

screen = body(behaviors, "private func agentScreen(agents: AgentMonitor, engine: PowerEngine)")
assert "engine.closedSince != nil" in screen, "an armed closed session holds the display"
assert "wakeDisplayForAgents()" in screen, "starting the hold wakes a display that already slept"
wake = body(behaviors, "private func wakeDisplayForAgents()")
assert "IOPMAssertionDeclareUserActivity" in wake and "IOPMAssertionRelease" in wake
print("agent screen structure: ok")
