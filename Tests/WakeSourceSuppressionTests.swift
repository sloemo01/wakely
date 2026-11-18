import Foundation

@main
struct WakeSourceSuppressionTests {
    static let pmsetSnapshot = [
        "powernap": 1,
        "proximitywake": 1,
        "womp": 0,
        "sleep": 3
    ]

    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        let lease = try WakeSourceSuppression.makeLease(from: pmsetSnapshot)
        check(lease.previous == ["powernap": 1, "proximitywake": 1, "womp": 0],
              "only the three owned settings are captured")
        check(lease.written == ["powernap": 0, "proximitywake": 0, "womp": 0],
              "all supported wake sources are asked to turn off")
        check(WakeSourceSuppression.encode(lease.previous) == "powernap=1,proximitywake=1,womp=0",
              "the lease uses a deterministic encoding")
        check(WakeSourceSuppression.decode(WakeSourceSuppression.encode(lease.previous)) == lease.previous,
              "the previous map round-trips")
        check(WakeSourceSuppression.encode(lease.written) == "powernap=0,proximitywake=0,womp=0",
              "the written map is independent of the previous values")

        let partial = try WakeSourceSuppression.makeLease(from: ["powernap": 0])
        check(partial.previous == ["powernap": 0],
              "models that report one setting capture only that setting")
        do {
            _ = try WakeSourceSuppression.makeLease(from: ["sleep": 3])
            check(false, "an unsupported machine must be refused")
        } catch {
            check(error.localizedDescription.contains("does not report"), "the unsupported refusal is explicit")
        }

        for malformed in ["", "powernap=3", "unknown=1", "powernap=1,powernap=0", "powernap", "powernap=x"] {
            check(WakeSourceSuppression.decode(malformed) == nil, "malformed lease '\(malformed)' is rejected")
        }
        check(WakeSourceSuppression.decode("powernap=2,proximitywake=1") == ["powernap": 2, "proximitywake": 1],
              "valid 0...2 values decode")

        let previous = "powernap=1,proximitywake=1,womp=0"
        let written = "powernap=0,proximitywake=0,womp=0"
        let restored = WakeSourceSuppression.restoration(
            previousText: previous, writtenText: written,
            current: ["powernap": 0, "proximitywake": 0, "womp": 0])
        check(restored == .write([
            .init(key: "powernap", value: 1),
            .init(key: "proximitywake", value: 1)
        ]), "only values the helper actually changed are written back")
        check(WakeSourceSuppression.restoration(
            previousText: previous, writtenText: written,
            current: ["powernap": 1, "proximitywake": 1, "womp": 0]) == .write([]),
              "an already-restored machine writes nothing")
        check(WakeSourceSuppression.restoration(
            previousText: previous, writtenText: written,
            current: ["powernap": 2, "proximitywake": 0, "womp": 0])
                == .refuse("powernap changed outside Wakely; the lease is retained."),
              "an external change is never overwritten")
        check(WakeSourceSuppression.restoration(
            previousText: previous, writtenText: written, current: ["powernap": 0])
                == .refuse("Could not read current proximitywake; the lease is retained."),
              "a missing current value refuses the restore")
        check(WakeSourceSuppression.restoration(
            previousText: "powernap=1", writtenText: "powernap=0,proximitywake=0",
            current: ["powernap": 0, "proximitywake": 0])
                == .refuse("Saved wake-source keys disagree; the lease is retained."),
              "mismatched saved keys are refused")
        check(WakeSourceSuppression.restoration(
            previousText: "powernap=x", writtenText: written, current: [:])
                == .refuse("Invalid saved wake-source values; the lease is retained."),
              "malformed saved values are refused")

        print("PASS: \(checks) wake-source lease checks; no pmset command executed")
    }
}
