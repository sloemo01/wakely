// Diagnostics — the same append-only log the original writes, at
// ~/Library/Application Support/Wakely/diagnostics.log

import Foundation

enum Diagnostics {
    /// Resolved through SupportPaths so every subsystem uses one directory
    /// before anything writes here.
    static var supportDirectory: URL { SupportPaths.baseDirectory }

    private static let logURL: URL = supportDirectory.appendingPathComponent("diagnostics.log")

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let queue = DispatchQueue(label: "dev.wakely.diagnostics")

    static func log(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }

    static func truncateIfNeeded() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path)
        if let size = attrs?[.size] as? Int, size > 512 * 1024 {
            try? FileManager.default.removeItem(at: logURL)
        }
    }
}
