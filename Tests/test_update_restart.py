"""Restart Now must quit only after the install task has returned."""
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / "Sources/UpdateChecker.swift").read_text()
restart = source.split("private func offerRestart()", 1)[1].split("\n    }\n", 1)[0]
assert "DispatchQueue.main.async { NSApp.terminate(nil) }" in restart, \
    "terminate runs on a later main-queue turn, not inside the install task"
assert "\n        NSApp.terminate(nil)" not in restart, "no synchronous terminate inside the task"
print("update restart structure: ok")
