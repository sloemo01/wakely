// Compile with Sources/ComponentSprites.swift to render its real SwiftUI colors.
import AppKit
import SwiftUI

@MainActor enum AppResources {
    static func url(name: String, extension ext: String, subdirectory: String) -> URL? {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(subdirectory)/\(name).\(ext)")
    }
}
enum Diagnostics { static func log(_ text: String) { print(text) } }
@MainActor enum ComponentIcon {
    static func image(named: String) -> NSImage { NSImage(size: NSSize(width: 28, height: 28)) }
}

@main struct SpriteProof {
    @MainActor static func main() throws {
        let names = ["finishWorkThenSleep", "capsLock", "cleaningLock", "quietClose",
                     "lidCloseSound", "lowPowerWhileClosed", "batteryBudget", "sleepMeansSleep",
                     "stayOffWhenOpened", "sleepWhenIdle", "sleepTimer", "ejectOnSleep",
                     "bluetoothOffWhileClosed", "lidShortcuts", "armWhileAppRuns", "armWhenDriveConnects"]
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/native-sprite-preview")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in names {
            let view = ComponentSprite(componentID: name, isOn: true, size: 140)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "SpriteProof", code: 1, userInfo: [NSLocalizedDescriptionKey: name])
            }
            try png.write(to: directory.appendingPathComponent(name + ".png"))
        }
        print("Rendered \(names.count) native SwiftUI sprite proofs")
    }
}
