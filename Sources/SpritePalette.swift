import SwiftUI

/// The authored golden material shared by built-in PNGs and user-authored
/// 32x32 icons. Values mirror `generate-sprites.py`; art tests compare both
/// representations so the two cannot silently drift apart.
enum GoldenSpritePalette {
    struct Tone: Equatable {
        let character: Character
        let light: UInt32
        let dark: UInt32
    }

    static let enabled: [Tone] = [
        .init(character: "n", light: 0x3A2404, dark: 0x2A1B05),
        .init(character: "u", light: 0x563706, dark: 0x4A2E06),
        .init(character: "d", light: 0x7B4F08, dark: 0x70470A),
        .init(character: "b", light: 0xA86F06, dark: 0xB9820F),
        .init(character: "s", light: 0xC98F10, dark: 0xE3AF24),
        .init(character: "l", light: 0xE7B52F, dark: 0xF7D66A),
        .init(character: "i", light: 0xF8D975, dark: 0xFFF0B3),
        .init(character: "w", light: 0xFFF0B8, dark: 0xFFF9DC),
    ]
    static let off: [Tone] = [
        .init(character: "n", light: 0x3D3528, dark: 0x1E1912),
        .init(character: "u", light: 0x564B36, dark: 0x30271A),
        .init(character: "d", light: 0x746446, dark: 0x4C3C23),
        .init(character: "b", light: 0x8F7A50, dark: 0x715A32),
        .init(character: "s", light: 0xAD9562, dark: 0x998146),
        .init(character: "l", light: 0xC6B17F, dark: 0xBFA461),
        .init(character: "i", light: 0xDCCB9F, dark: 0xD8C189),
        .init(character: "w", light: 0xEADDBB, dark: 0xE8D9AE),
    ]

    static func colors(on: Bool, appearance: ColorScheme) -> [Character: Color] {
        let tones = on ? enabled : off
        return Dictionary(uniqueKeysWithValues: tones.map { tone in
            (tone.character, Color(hex: appearance == .dark ? tone.dark : tone.light))
        })
    }

    static func nsColors(on: Bool, appearance: NSAppearance) -> [Character: NSColor] {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let tones = on ? enabled : off
        return Dictionary(uniqueKeysWithValues: tones.map { tone in
            let hex = dark ? tone.dark : tone.light
            return (tone.character, NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                                           green: Double((hex >> 8) & 255) / 255,
                                           blue: Double(hex & 255) / 255, alpha: 1))
        })
    }
}
