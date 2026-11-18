"""Compile the whole app minus its entry point, then build the status menu headlessly."""
from pathlib import Path
import subprocess, sys, tempfile

root = Path(__file__).resolve().parents[1]
sources = sorted(str(p) for p in (root / "Sources").glob("*.swift") if p.name != "main.swift")
harness = (root / "Tests/MenuBarTests.swift").read_text()
with tempfile.TemporaryDirectory(prefix="wakely-menu-tests-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text(harness)
    binary = work / "menu"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
        "-framework", "AppKit", "-framework", "SwiftUI", "-framework", "IOKit",
        "-framework", "ServiceManagement", "-framework", "AVFoundation",
        *sources, str(work / "main.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
