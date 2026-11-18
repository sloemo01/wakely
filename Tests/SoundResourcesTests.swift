import Foundation
import AVFoundation

// Decodes the shipped assets without playing audio or changing system volume.
@main
struct SoundResourcesTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        for name in ["shell", "pearl", "chime", "lullaby", "tide", "sonar", "bubble", "arcade"] {
            let url = root.appendingPathComponent("close-sound-\(name).m4a")
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
                fatalError("Empty or invalid sound: \(name)")
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { fatalError("Cannot decode sound: \(name)") }
            print("PASS: \(name) decoded (\(String(format: "%.2f", Double(file.length) / file.processingFormat.sampleRate))s)")
        }
        print("8 sound resource tests passed")
    }
}
