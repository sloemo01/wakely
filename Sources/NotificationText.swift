import Foundation

/// Escape backslashes first: escaping only quotes lets a preceding backslash
/// terminate the AppleScript string. Component text must remain data, never code.
enum NotificationText {
    static func appleScriptLiteral(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
