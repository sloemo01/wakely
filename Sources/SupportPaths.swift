// SupportPaths — the one place that resolves the per-user data directory.
//
// Wakely keeps its files in ~/Library/Application Support/Wakely. Subfolders
// inside it ("Components", "Components/components") keep their names for
// filesystem compatibility with kits the user may already have installed.

import Foundation

enum SupportPaths {
    /// Product directory under Application Support.
    static let directoryName = "Wakely"

    /// ~/Library/Application Support/Wakely, created on demand.
    static var baseDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let destination = support.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }
}
