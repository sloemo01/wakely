// The OSS component tool: create, check and preview a Wakely component.
//
// Manifest rules are not repeated here. check calls the same
// Sources/ComponentValidator.swift the app uses, so the two cannot drift.

import Foundation

let usage = """
usage: wakely-component <command> <id> [--root DIR]

  new <id>       create <root>/<id>/ from the SDK template
  check <id>     validate component.json and icon.txt
  preview <id>   write .preview/icon.ppm, icon-8x.ppm and card.ppm

The root defaults to ~/Library/Application Support/Wakely/Components/components.
Pass --root DIR or set WAKELY_COMPONENTS_DIR to use another folder.
"""

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("wakely-component: \(message)\n".utf8))
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    printError(message)
    exit(code)
}

func expandedPath(_ path: String) -> String {
    if path == "~" { return NSHomeDirectory() }
    if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst()) }
    return path
}

func componentsRoot(_ override: String?) -> URL {
    if let path = override, !path.isEmpty {
        return URL(fileURLWithPath: expandedPath(path)).standardizedFileURL
    }
    if let path = ProcessInfo.processInfo.environment["WAKELY_COMPONENTS_DIR"], !path.isEmpty {
        return URL(fileURLWithPath: expandedPath(path)).standardizedFileURL
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wakely/Components/components", isDirectory: true)
        .standardizedFileURL
}

/// The folder the launcher compiled from. The environment value covers the
/// normal path; the walk up from the executable keeps a direct run working.
func repositoryRoot() -> URL {
    let environment = ProcessInfo.processInfo.environment["WAKELY_COMPONENT_TOOL_ROOT"]
    if let root = environment, !root.isEmpty {
        return URL(fileURLWithPath: root).standardizedFileURL
    }
    var candidate = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    for _ in 0..<3 { candidate.deleteLastPathComponent() }
    let marker = candidate.appendingPathComponent("Sources/ComponentValidator.swift")
    if FileManager.default.fileExists(atPath: marker.path) { return candidate }

    candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    while candidate.path != "/" {
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Sources/ComponentValidator.swift").path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
}

// MARK: - ids and folders

let idPattern = "^[a-z](?:[a-z0-9]|-(?=[a-z0-9])){1,39}$"

func isValidID(_ id: String) -> Bool {
    if id.isEmpty || id.contains("/") || id.contains("\\") || id == "." || id == ".." { return false }
    return id.range(of: idPattern, options: .regularExpression) != nil
}

func componentFolder(id: String, root: URL) throws -> URL {
    guard isValidID(id) else {
        throw ToolError("\"\(id)\" is not a valid component id; use 2 to 40 lowercase letters, digits and single hyphens, starting with a letter")
    }
    let folder = root.appendingPathComponent(id, isDirectory: true).standardizedFileURL
    let rootPath = root.standardizedFileURL.path
    let prefix = rootPath == "/" ? "/" : rootPath + "/"
    guard folder.path.hasPrefix(prefix) else {
        throw ToolError("\"\(id)\" would write outside \(root.path)")
    }
    return folder
}

func requireFolder(id: String, root: URL) throws -> URL {
    let folder = try componentFolder(id: id, root: root)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        throw ToolError("no component named \"\(id)\" in \(root.path)")
    }
    return folder
}

func readText(_ url: URL) throws -> String {
    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        throw ToolError("could not read \(url.path): \(error.localizedDescription)")
    }
}

// MARK: - new

func createComponent(id: String, root: URL) throws -> URL {
    let folder = try componentFolder(id: id, root: root)
    if FileManager.default.fileExists(atPath: folder.path) {
        throw ToolError("\(folder.path) already exists; choose another id or remove the folder first")
    }

    let template = repositoryRoot()
        .appendingPathComponent("harvest/components-kit/sdk/template", isDirectory: true)
    let iconURL = template.appendingPathComponent("icon.txt")
    let manifestURL = template.appendingPathComponent("component.json")
    guard FileManager.default.fileExists(atPath: iconURL.path), FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw ToolError("the SDK template was not found at \(template.path)")
    }

    let icon = try readText(iconURL)
    var manifest = try readText(manifestURL)
    manifest = manifest.replacingOccurrences(of: "\"my-component\"", with: "\"\(id)\"")

    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    } catch {
        throw ToolError("could not create \(folder.path): \(error.localizedDescription)")
    }
    do {
        try manifest.write(to: folder.appendingPathComponent("component.json"), atomically: true, encoding: .utf8)
        try icon.write(to: folder.appendingPathComponent("icon.txt"), atomically: true, encoding: .utf8)
    } catch {
        try? FileManager.default.removeItem(at: folder)
        throw ToolError("could not write the component files: \(error.localizedDescription)")
    }
    return folder
}

// MARK: - check

func manifestHint(_ message: String) -> String {
    if message.contains("unknown field") { return "remove it, or fix its spelling; format 1 rejects unknown fields" }
    if message.contains("unknown or missing event") { return "use a documented event, such as lidClosed, closedFor or batteryBelow" }
    if message.contains("unknown condition") { return "use a documented condition, such as onCharger, appRunning or timeBetween" }
    if message.contains("unknown value kind") { return "use apps, choice, duration, minutes, number or percent" }
    if message.contains("unknown action") { return "use endSession or notify" }
    if message.contains("must be 1") { return "set \"format\": 1" }
    if message.contains("must match the folder name") { return "set \"id\" to the component folder name" }
    if message.contains("must appear exactly once") { return "write each {key} exactly once in description.text" }
    if message.contains("undeclared value") { return "declare the key in description.values or remove the placeholder" }
    if message.contains("must be used by a rule") { return "reference the value from a rule, or remove it" }
    if message.contains("must be one line") { return "keep the text on one line within the documented length" }
    if message.contains("is required") { return "add the required field" }
    return "see sdk/reference.md for the expected shape"
}

func manifestLine(_ raw: String) -> String {
    guard let separator = raw.range(of: ": ") else {
        return "component.json: \(raw) (fix: \(manifestHint(raw)))"
    }
    let path = String(raw[..<separator.lowerBound])
    let message = String(raw[separator.upperBound...])
    let location = path == "component" ? "" : "\(path): "
    return "component.json: \(location)\(message) (fix: \(manifestHint(message)))"
}

func checkComponent(id: String, root: URL) -> Never {
    let folder: URL
    do { folder = try requireFolder(id: id, root: root) } catch { fail("\(error)") }

    var problems = 0
    let manifestURL = folder.appendingPathComponent("component.json")
    if FileManager.default.fileExists(atPath: manifestURL.path) {
        do {
            let data = try Data(contentsOf: manifestURL)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for error in ComponentValidator.validate(object, folderID: id) {
                    print(manifestLine(error))
                    problems += 1
                }
            } else {
                print("component.json: the manifest must be a JSON object (fix: start and end with braces)")
                problems += 1
            }
        } catch {
            print("component.json: not valid JSON: \(error.localizedDescription) (fix: check commas, quotes and braces)")
            problems += 1
        }
    } else {
        print("component.json: missing (fix: create component.json in \(folder.path))")
        problems += 1
    }

    let iconURL = folder.appendingPathComponent("icon.txt")
    if FileManager.default.fileExists(atPath: iconURL.path) {
        do {
            let text = try readText(iconURL)
            let references = repositoryRoot()
                .appendingPathComponent("harvest/components-kit/sdk/reference-sprites", isDirectory: true)
            let icon = Icon.parse(text, referenceDirectory: references)
            print(icon.summary)
            for warning in icon.warnings { print("warning: icon.txt: \(warning)") }
            for error in icon.errors {
                print("icon.txt: \(error)")
                problems += 1
            }
        } catch {
            print("icon.txt: \(error) (fix: make the file readable)")
            problems += 1
        }
    } else {
        print("icon.txt: missing (fix: draw a 32 by 32 icon in \(folder.path))")
        problems += 1
    }

    if problems == 0 {
        print("ok")
        exit(0)
    }
    exit(1)
}

// MARK: - preview

func previewComponent(id: String, root: URL) -> Never {
    let folder: URL
    do { folder = try requireFolder(id: id, root: root) } catch { fail("\(error)") }

    let iconURL = folder.appendingPathComponent("icon.txt")
    guard FileManager.default.fileExists(atPath: iconURL.path) else {
        fail("icon.txt is missing in \(folder.path)")
    }
    let text: String
    do { text = try readText(iconURL) } catch { fail("\(error)") }

    let references = repositoryRoot()
        .appendingPathComponent("harvest/components-kit/sdk/reference-sprites", isDirectory: true)
    let icon = Icon.parse(text, referenceDirectory: references)
    for warning in icon.warnings { printError("warning: icon.txt: \(warning)") }
    guard icon.errors.isEmpty else {
        for error in icon.errors { print("icon.txt: \(error)") }
        exit(1)
    }

    let preview = folder.appendingPathComponent(".preview", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        let pixels = SpriteRenderer.pixels(rows: icon.rows)
        try SpriteRenderer.writePPM(pixels, width: 32, height: 32,
                                   to: preview.appendingPathComponent("icon.ppm"))
        try SpriteRenderer.writePPM(SpriteRenderer.scaled(pixels, to: 256), width: 256, height: 256,
                                   to: preview.appendingPathComponent("icon-8x.ppm"))
        try SpriteRenderer.writePPM(SpriteRenderer.scaled(pixels, to: 56), width: 56, height: 56,
                                   to: preview.appendingPathComponent("card.ppm"))
    } catch {
        fail("could not write the preview: \(error)")
    }

    print(preview.appendingPathComponent("icon.ppm").path)
    print(preview.appendingPathComponent("icon-8x.ppm").path)
    print(preview.appendingPathComponent("card.ppm").path)
    exit(0)
}

// MARK: - argv

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.isEmpty || arguments[0] == "--help" || arguments[0] == "-h" {
    print(usage)
    exit(arguments.isEmpty ? 2 : 0)
}

let command = arguments.removeFirst()
var id: String?
var rootArgument: String?
var index = 0
while index < arguments.count {
    let argument = arguments[index]
    if argument == "--root" {
        guard index + 1 < arguments.count else { fail("--root needs a folder", code: 2) }
        rootArgument = arguments[index + 1]
        index += 2
    } else if argument.hasPrefix("--root=") {
        rootArgument = String(argument.dropFirst("--root=".count))
        index += 1
    } else if argument.hasPrefix("-") {
        fail("unknown option \(argument)\n\n\(usage)", code: 2)
    } else if id == nil {
        id = argument
        index += 1
    } else {
        fail("unexpected argument \(argument)\n\n\(usage)", code: 2)
    }
}

guard let id else {
    fail("a component id is required\n\n\(usage)", code: 2)
}

let root = componentsRoot(rootArgument)
switch command {
case "new":
    do {
        let folder = try createComponent(id: id, root: root)
        print("created \(folder.path)")
    } catch {
        fail("\(error)")
    }
case "check":
    checkComponent(id: id, root: root)
case "preview":
    previewComponent(id: id, root: root)
default:
    fail("unknown command \"\(command)\"\n\n\(usage)", code: 2)
}
