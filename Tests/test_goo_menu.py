"""Compile the app minus its entry point, then exercise the native goo menu.

This briefly shows a disposable test window to exercise real Core Animation.
It never moves the pointer, changes system settings, or launches the installed app.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
sources = sorted(str(p) for p in (root / "Sources").glob("*.swift") if p.name != "main.swift")
harness_source = (root / "Tests/GooMenuTests.swift").read_text()

with tempfile.TemporaryDirectory(prefix="wakely-goo-menu-tests-") as directory:
    work = Path(directory)
    harness = work / "GooMenuRegression.swift"
    harness.write_text(harness_source)
    binary = work / "goo-menu"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-parse-as-library",
        "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
        "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "IOKit",
        "-framework", "ServiceManagement", "-framework", "AVFoundation",
        *sources, str(harness), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
