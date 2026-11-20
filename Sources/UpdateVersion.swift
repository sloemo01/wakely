// UpdateVersion — pure release-tag comparison, kept Foundation-only so the
// unit tests compile without the app.

import Foundation

enum UpdateVersion {
    /// "v2.0.7" → "2.0.7"; anything without digits is returned trimmed.
    static func normalizedTag(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }

    /// Dot-separated non-negative integers ("2", "2.0", "2.0.7"). nil otherwise.
    static func parse(_ raw: String) -> [Int]? {
        let parts = normalizedTag(raw).split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // Tolerate a build suffix on the last component ("7-beta" → 7).
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            numbers.append(value)
        }
        return numbers
    }

    /// Numeric compare, missing components count as zero: 2.0.7 > 2.0.6,
    /// 2.0 == 2.0.0, 2.1 > 2.0.9.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult? {
        guard let a = parse(lhs), let b = parse(rhs) else { return nil }
        let count = max(a.count, b.count)
        for index in 0..<count {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left < right ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// "Wakely-2.0.6-r9.dmg" → "2.0.6"; nil for anything else.
    static func version(fromDownloadName name: String) -> String? {
        guard name.hasPrefix("Wakely-"), name.hasSuffix(".dmg") else { return nil }
        let core = name.dropFirst("Wakely-".count).dropLast(".dmg".count)
        guard let version = core.split(separator: "-").first.map(String.init),
              parse(version) != nil else { return nil }
        return version
    }
}

enum AppVersion {
    /// The running bundle's marketing version, falling back to "0.0.0" so a
    /// dev run never compares as up to date.
    static var current: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return UpdateVersion.parse(raw) != nil ? UpdateVersion.normalizedTag(raw) : "0.0.0"
    }
}
