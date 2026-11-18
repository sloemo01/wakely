"""Compile and run only the pure fan policy; no IOKit, no SMC access."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Helper/SMC.swift").read_text()
block = source.split("// BEGIN TESTABLE FAN POLICY\n", 1)[1].split(
    "// END TESTABLE FAN POLICY", 1
)[0]
harness = r'''
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

for p in [Int.min, -1, 0, 1, 29, 101, Int.max] {
    expect(FanPolicy.targetRPM(percent: p, minimumRPM: 1000, maximumRPM: 6000) == nil, "invalid percent rejected")
}
for maximum in [Double.nan, .infinity, -.infinity, 0, -1] {
    expect(FanPolicy.targetRPM(percent: 50, minimumRPM: 1000, maximumRPM: maximum) == nil, "invalid maximum rejected")
}
let minima: [Double?] = [nil, .nan, .infinity, -.infinity, -1, 6000, 7000]
for minimum in minima {
    expect(FanPolicy.targetRPM(percent: 50, minimumRPM: minimum, maximumRPM: 6000) == 6000, "invalid minimum falls back to maximum")
}
expect(FanPolicy.targetRPM(percent: 30, minimumRPM: 1000, maximumRPM: 6000) == 2500, "30 percent interval")
expect(FanPolicy.targetRPM(percent: 50, minimumRPM: 1000, maximumRPM: 6000) == 3500, "half interval not half maximum")
expect(FanPolicy.targetRPM(percent: 100, minimumRPM: 1000, maximumRPM: 6000) == 6000, "maximum endpoint")
expect(FanPolicy.targetRPM(percent: 30, minimumRPM: 0, maximumRPM: 6000) == 1800, "zero minimum valid")
expect(FanPolicy.targetRPM(percent: 31, minimumRPM: 1000, maximumRPM: 6001) == 2551, "ceil fractional RPM")
expect(FanPolicy.targetRPM(percent: 50, minimumRPM: 1000, maximumRPM: 6000, floorRPM: 4000.2) == 4001, "floor before ceil")
expect(FanPolicy.targetRPM(percent: 50, minimumRPM: 1000, maximumRPM: 6000, floorRPM: 9000) == 6000, "floor capped")
for floor in [Double.nan, .infinity, -.infinity, -100] {
    expect(FanPolicy.targetRPM(percent: 50, minimumRPM: 1000, maximumRPM: 6000, floorRPM: floor) == 3500, "invalid floor ignored or low floor inert")
}
for p in 30...100 {
    let rpm = FanPolicy.targetRPM(percent: p, minimumRPM: 1000, maximumRPM: 6001)!
    expect(FanPolicy.percent(rpm: rpm, minimumRPM: 1000, maximumRPM: 6001) == p, "interval inverse round trip")
}
expect(FanPolicy.percent(rpm: 1000, minimumRPM: 1000, maximumRPM: 6000) == nil, "unrepresentable manual backup rejected")
expect(FanPolicy.percent(rpm: .nan, minimumRPM: 1000, maximumRPM: 6000) == nil, "invalid inverse")
expect(FanPolicy.percent(rpm: 6000, minimumRPM: nil, maximumRPM: 6000) == 100, "fallback inverse")

expect(FanPolicy.modeName(from: 0) == "auto", "0 is automatic")
expect(FanPolicy.modeName(from: 3) == "auto", "3 is the Apple Silicon automatic mode")
expect(FanPolicy.modeName(from: 1) == "manual", "1 is manual")
expect(FanPolicy.modeName(from: 2) == "unknown", "2 is unknown")

for value in [0.0, 1.0, 1234.5, 6000.0] {
    let bytes = FanPolicy.bigEndianBytes(from: value)
    expect(bytes.count == 4, "four SMC bytes")
    if let back = FanPolicy.float(fromBigEndian: bytes) {
        expect(abs(back - value) < 0.5, "float round trip \(value)")
    } else {
        expect(false, "float must decode")
    }
}
expect(FanPolicy.float(fromBigEndian: [0, 0]) == nil, "short buffers are rejected")
print("PASS: fan policy validates, maps intervals and decodes without touching IOKit")
'''
with tempfile.TemporaryDirectory(prefix="wakely-fan-tests-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text("import Foundation\n" + block + "\n" + harness)
    binary = work / "tests"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5",
        "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(Path.home() / "Library/Caches/Wakely/build"),
        str(work / "main.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
