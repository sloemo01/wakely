// The 32 by 32 letter icon: parsing, the style numbers, and preview pixels.
//
// Hard format errors (line count, line length, palette) stop check. The style
// rules are warnings: the original checker's exact thresholds are not
// established, so the OSS tool reports them instead of refusing the component.

import Foundation

struct Icon {
    static let palette: Set<Character> = [".", "n", "u", "d", "b", "s", "l", "i", "w"]
    private static let brightSymbols: Set<Character> = ["i", "w"]

    let rows: [String]
    let errors: [String]
    let warnings: [String]
    let fillPercent: Double
    let toneCount: Int
    let brightPercent: Double

    var summary: String {
        "icon.txt: fill \(Icon.percent(fillPercent))%, \(toneCount) tones, bright \(Icon.percent(brightPercent))%"
    }

    static func percent(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func parse(_ text: String, referenceDirectory: URL?) -> Icon {
        let lines = splitLines(text).map(stripRowNumber)
        var errors: [String] = []
        var warnings: [String] = []

        if lines.count != 32 {
            errors.append("expected 32 lines; found \(lines.count) (fix: draw 32 rows of 32 characters)")
        }
        for (offset, line) in lines.enumerated() {
            if line.count != 32 {
                errors.append("line \(offset + 1): expected 32 characters; found \(line.count) (fix: draw 32 characters per row)")
            }
            let illegal = Set(line.filter { !palette.contains($0) }).sorted()
            if !illegal.isEmpty {
                let names = illegal.map { "\"\($0)\"" }.joined(separator: ", ")
                errors.append("line \(offset + 1): illegal character\(illegal.count == 1 ? "" : "s") \(names) (fix: use only .nudbsliw)")
            }
        }

        let cells = lines.flatMap { Array($0) }
        let drawn = cells.filter { $0 != "." }
        let tones = Set(drawn)
        let fill = Double(drawn.count) / 1024.0 * 100
        let bright = Double(drawn.filter { brightSymbols.contains($0) }.count)
        let brightPercent = drawn.isEmpty ? 0 : bright / Double(drawn.count) * 100

        if errors.isEmpty {
            if lines[0].contains(where: { $0 != "." }) {
                warnings.append("the top row is not empty (fix: leave row 1 empty)")
            }
            if fill < 18 || fill > 70 {
                warnings.append("fill \(percent(fill))% is outside 18% to 70% (fix: draw an object about the middle 26 by 26 cells)")
            }
            if tones.count < 5 {
                warnings.append("only \(tones.count) tone\(tones.count == 1 ? "" : "s"); use at least 5 (fix: shade the body with n/u/d/b/s/l)")
            }
            if brightPercent >= 12 {
                warnings.append("bright share \(percent(brightPercent))%; keep i and w under 12% of the drawing")
            }
            if let bottom = lines.lastIndex(where: { $0.contains(where: { $0 != "." }) }),
               lines[bottom].contains(where: { $0 != "." && $0 != "u" && $0 != "n" }) {
                warnings.append("the bottom row of the drawing is not a contact shadow (fix: end with a row of u or n)")
            }
            if let directory = referenceDirectory,
               let reference = matchingReference(lines, in: directory) {
                warnings.append("matches the reference sprite \(reference); draw an original object (fix: change the silhouette, not just the shading)")
            }
        }

        return Icon(rows: errors.isEmpty ? lines : [],
                    errors: errors,
                    warnings: warnings,
                    fillPercent: fill,
                    toneCount: tones.count,
                    brightPercent: brightPercent)
    }

    private static func splitLines(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    private static func stripRowNumber(_ line: String) -> String {
        guard let bar = line.firstIndex(of: "|") else { return line }
        let prefix = line[..<bar]
        guard !prefix.isEmpty, prefix.allSatisfy({ $0.isASCII && $0.isNumber }) else { return line }
        return String(line[line.index(after: bar)...])
    }

    private static func matchingReference(_ rows: [String], in directory: URL) -> String? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "txt" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let reference = splitLines(text).map(stripRowNumber)
            guard reference.count == 32,
                  reference.allSatisfy({ $0.count == 32 && $0.allSatisfy(palette.contains) }) else { continue }
            if reference == rows { return file.lastPathComponent }
        }
        return nil
    }
}

enum SpriteRenderer {
    private static let colors: [Character: (UInt8, UInt8, UInt8)] = [
        "n": (0x0B, 0x10, 0x20),
        "u": (0x16, 0x20, 0x3A),
        "d": (0x24, 0x40, 0x6E),
        "b": (0x3F, 0x66, 0xA8),
        "s": (0x7F, 0xA3, 0xD8),
        "l": (0xB9, 0xD2, 0xF4),
        "i": (0xDB, 0xE8, 0xFF),
        "w": (0xFF, 0xFF, 0xFF),
        ".": (0x0B, 0x0B, 0x0E)
    ]
    private static let background: (UInt8, UInt8, UInt8) = (0x0B, 0x0B, 0x0E)

    static func pixels(rows: [String]) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 32 * 32 * 3)
        for y in 0..<32 {
            let row = y < rows.count ? Array(rows[y]) : []
            for x in 0..<32 {
                let symbol = x < row.count ? row[x] : "."
                let (red, green, blue) = colors[symbol] ?? background
                let offset = (y * 32 + x) * 3
                pixels[offset] = red
                pixels[offset + 1] = green
                pixels[offset + 2] = blue
            }
        }
        return pixels
    }

    static func scaled(_ pixels: [UInt8], to size: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: size * size * 3)
        for y in 0..<size {
            let sourceY = min(31, y * 32 / size)
            for x in 0..<size {
                let sourceX = min(31, x * 32 / size)
                let source = (sourceY * 32 + sourceX) * 3
                let target = (y * size + x) * 3
                output[target] = pixels[source]
                output[target + 1] = pixels[source + 1]
                output[target + 2] = pixels[source + 2]
            }
        }
        return output
    }

    static func writePPM(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        var data = Data("P6\n\(width) \(height)\n255\n".utf8)
        data.append(contentsOf: pixels)
        try data.write(to: url)
    }
}
