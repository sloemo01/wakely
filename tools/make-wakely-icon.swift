// Generates the Wakely app icon from a 32x32 pixel grid.
// Run: xcrun swift tools/make-wakely-icon.swift <output.iconset>
import AppKit
import CoreGraphics
import Foundation

let grid = 32
var pixels = [UInt8](repeating: 0, count: grid * grid * 4)

func put(_ x: Int, _ y: Int, _ hex: UInt32) {
    guard x >= 0, y >= 0, x < grid, y < grid else { return }
    let i = (y * grid + x) * 4
    pixels[i] = UInt8((hex >> 16) & 0xFF)
    pixels[i + 1] = UInt8((hex >> 8) & 0xFF)
    pixels[i + 2] = UInt8(hex & 0xFF)
    pixels[i + 3] = 255
}

let ink = UInt32(0x0B1220)
let edge = UInt32(0x26324A)

// Full square: Finder and the Dock already present it on the system's rounded
// tile, so the artwork itself stays a hard-edged pixel square.
for y in 0..<grid {
    for x in 0..<grid {
        let border = x == 0 || y == 0 || x == grid - 1 || y == grid - 1
        put(x, y, border ? edge : ink)
    }
}

// The app icon uses the exact menu-bar glyph: the same 11x11 eye-with-rays
// grid from Sources/BrandIcon.swift, scaled 2x and centred on the tile.
let glyph = [
    ".....1.....",
    ".1...1...1.",
    "..1.....1..",
    "..1111111..",
    ".1.......1.",
    "1....1....1",
    ".1.......1.",
    "..1111111..",
    "..1.....1..",
    ".1...1...1.",
    ".....1....."
]
let warmWhite = UInt32(0xFFF7E6)
let sunLight = UInt32(0xFDE68A)
let sunMid = UInt32(0xFBBF24)
let sunDeep = UInt32(0xF59E0B)
let pupilOrange = UInt32(0xF97316)

// Same glyph, warm sun shading: the eye rim stays warm white, the pupil is
// amber, and the rays step from light yellow at the tips to orange near the
// eye. No shape is added or removed.
for (row, line) in glyph.enumerated() {
    for (column, character) in line.enumerated() where character == "1" {
        let isEye = row >= 3 && row <= 7
        let isPupil = row == 5 && column == 5
        let ring = max(abs(column - 5), abs(row - 5))
        let shade: UInt32
        if isPupil {
            shade = pupilOrange
        } else if isEye {
            shade = warmWhite
        } else if ring >= 4 {
            shade = sunLight
        } else if ring == 3 {
            shade = sunMid
        } else {
            shade = sunDeep
        }
        let x = 5 + column * 2
        let y = 5 + row * 2
        for dy in 0..<2 {
            for dx in 0..<2 {
                put(x + dx, y + dy, shade)
            }
        }
    }
}

func image(_ size: Int) -> NSBitmapImageRep? {
    var out = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            let sx = x * grid / size
            let sy = y * grid / size
            let s = (sy * grid + sx) * 4
            let d = (y * size + x) * 4
            out[d] = pixels[s]
            out[d + 1] = pixels[s + 1]
            out[d + 2] = pixels[s + 2]
            out[d + 3] = pixels[s + 3]
        }
    }
    let data = Data(out) as CFData
    guard let provider = CGDataProvider(data: data),
          let cg = CGImage(width: size, height: size, bitsPerComponent: 8,
                           bitsPerPixel: 32, bytesPerRow: size * 4,
                           space: CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false,
                           intent: .defaultIntent) else { return nil }
    return NSBitmapImageRep(cgImage: cg)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Wakely.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let entries: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, size) in entries {
    guard let bitmap = image(size),
          let png = bitmap.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: out.appendingPathComponent(name))
}
print("wrote \(out.path)")
