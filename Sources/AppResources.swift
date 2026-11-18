import Foundation

/// Resolve real bundled files even if Foundation cached a missing resource
/// while a running development bundle was being rebuilt in place.
enum AppResources {
    static func url(name: String, extension ext: String, subdirectory: String? = nil) -> URL? {
        let fm = FileManager.default
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
           fm.isReadableFile(atPath: url.path) { return url }
        var roots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL { roots.append(resourceURL) }
        if let executableURL = Bundle.main.executableURL {
            roots.append(executableURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true))
        }
        for root in roots {
            let directory = subdirectory.map { root.appendingPathComponent($0, isDirectory: true) } ?? root
            let url = directory.appendingPathComponent(name).appendingPathExtension(ext)
            if fm.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }
}
