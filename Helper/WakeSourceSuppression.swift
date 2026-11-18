import Foundation

/// The exact battery wake-source settings Sleep Means Sleep owns. The helper
/// refuses to write anything else, records every prior value, and restores the
/// same set. This is not a general pmset surface.
enum WakeSourceSuppression {
    static let settingNames = ["powernap", "proximitywake", "womp"]
    static let operation = "suppressWakeSources"

    struct Lease: Equatable {
        let previous: [String: Int]
        let written: [String: Int]
    }

    enum PolicyError: LocalizedError {
        case unsupported
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "This Mac does not report battery powernap, proximitywake or womp settings."
            case .malformed(let detail):
                return "Invalid saved wake-source lease: \(detail)"
            }
        }
    }

    struct SettingChange: Equatable {
        let key: String
        let value: Int
    }

    enum RestorePlan: Equatable {
        case write([SettingChange])
        case refuse(String)
    }

    /// Capture only settings the Mac actually reports. The helper never invents
    /// a setting or claims to suppress one it cannot read back.
    static func makeLease(from snapshot: [String: Int]) throws -> Lease {
        var previous: [String: Int] = [:]
        for key in settingNames {
            guard let value = snapshot[key], (0...2).contains(value) else { continue }
            previous[key] = value
        }
        guard !previous.isEmpty else { throw PolicyError.unsupported }
        let written = Dictionary(uniqueKeysWithValues: previous.keys.map { ($0, 0) })
        return Lease(previous: previous, written: written)
    }

    /// Deterministic encoding for the helper's existing key/value backup store.
    static func encode(_ values: [String: Int]) -> String {
        settingNames.compactMap { key in
            values[key].map { "\(key)=\($0)" }
        }.joined(separator: ",")
    }

    static func decode(_ text: String) -> [String: Int]? {
        guard !text.isEmpty else { return nil }
        var values: [String: Int] = [:]
        for pair in text.split(separator: ",") {
            let pieces = pair.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2,
                  settingNames.contains(String(pieces[0])),
                  let value = Int(pieces[1]),
                  (0...2).contains(value) else { return nil }
            guard values.updateValue(value, forKey: String(pieces[0])) == nil else { return nil }
        }
        return values.isEmpty ? nil : values
    }

    /// Refuse to overwrite a setting changed outside Wakely. For every owned
    /// key the current value must still be either what the helper wrote or the
    /// original value; only then is the original written back.
    static func restoration(previousText: String, writtenText: String,
                            current: [String: Int]) -> RestorePlan {
        guard let previous = decode(previousText),
              let written = decode(writtenText) else {
            return .refuse("Invalid saved wake-source values; the lease is retained.")
        }
        guard Set(previous.keys) == Set(written.keys) else {
            return .refuse("Saved wake-source keys disagree; the lease is retained.")
        }
        var writes: [SettingChange] = []
        for key in settingNames where previous[key] != nil {
            guard let prior = previous[key], let owned = written[key] else {
                return .refuse("Saved wake-source lease is incomplete; the lease is retained.")
            }
            guard let now = current[key], (0...2).contains(now) else {
                return .refuse("Could not read current \(key); the lease is retained.")
            }
            if now == prior { continue }
            guard now == owned else {
                return .refuse("\(key) changed outside Wakely; the lease is retained.")
            }
            writes.append(SettingChange(key: key, value: prior))
        }
        return .write(writes)
    }
}
