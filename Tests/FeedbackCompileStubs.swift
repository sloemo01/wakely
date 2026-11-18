// Used only for typechecking Feedback.swift without loading the app.
// Do not link this fixture into the application target.
import Foundation
enum AppResources {
    static func url(name: String, extension ext: String) -> URL? { nil }
}
enum Diagnostics {
    static func log(_ message: String) {}
}

// Deliberately replaces the native notification service in the isolated fixture.
// No UNUserNotificationCenter access, authorization requests, or deliveries.
@MainActor
final class WakelyNotifications {
    static let shared = WakelyNotifications()
    func post(title: String, body: String, sound: Bool) async {}
}
