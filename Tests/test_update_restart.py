"""Restart Now must quit only after the install task has returned."""
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / "Sources/UpdateChecker.swift").read_text()
restart = source.split("private func offerRestart()", 1)[1].split("\n    }\n", 1)[0]
assert "NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)" in restart, \
    "terminate runs from a run-loop timer, outside the install task and the main queue"
assert "DispatchQueue.main.async { NSApp.terminate" not in restart, \
    "a main-queue block cannot drain the main-actor cleanup either"
assert "\n        NSApp.terminate(nil)" not in restart, "no synchronous terminate inside the task"
print("update restart structure: ok")
