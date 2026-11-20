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
assert screen.index("guard !engine.agentScreenLockExpired") < screen.index("let holdDisplay"), \
    "expired sessions cannot retake the display assertion, even for active agents"
assert "releaseDisplayAssertion()" in screen.split("let holdDisplay", 1)[0]
safety = body(power, "private func checkSafety()")
assert "agentScreenLockTimer.expireIfNeeded" in safety
assert safety.index("releaseAgentScreenForLock()") < safety.index("requestLockScreen()")
assert "sleepDisplays(force: true)" in safety, "deadline sleeps displays regardless of agent needs"
sleep = body(power, "private func sleepDisplays(force: Bool)")
assert "if !force && agentsNeedScreen" in sleep
end = body(power, "private func endClosedSession(restoreBrightness: Bool)")
assert "agentScreenLockTimer = AgentScreenLockTimer()" in end, "ending a session resets the timer"
settings = (root / "Sources/SettingsUI.swift").read_text()
assert '"{lockAfter}"' in settings and 'range: 15...2880, step: 15' in settings
wake = body(behaviors, "private func wakeDisplayForAgents()")
assert "IOPMAssertionDeclareUserActivity" in wake and "IOPMAssertionRelease" in wake
print("agent screen structure: ok")
