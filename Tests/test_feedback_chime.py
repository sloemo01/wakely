"""Compile and run Feedback's start/completion contract with nil assets.

AppResources is deliberately the compile stub, so this opens no audio device and
never launches the app.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="wakely-feedback-tests-") as directory:
    work = Path(directory)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-parse-as-library",
        "-module-cache-path", str(work / "cache"),
        "-framework", "AppKit",
        "-framework", "AVFoundation",
        "-framework", "AudioToolbox",
        str(root / "Tests/FeedbackCompileStubs.swift"),
        str(root / "Sources/Feedback.swift"),
        str(root / "Sources/NotificationText.swift"),
        str(root / "Tests/FeedbackChimeTests.swift"),
        "-o", str(work / "tests")
    ], check=True)
    subprocess.run([str(work / "tests")], check=True)
