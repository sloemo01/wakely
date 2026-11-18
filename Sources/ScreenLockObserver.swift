// ScreenLockObserver — a read-only window onto the login session's lock state.
//
// The original reads the session dictionary and checks CGSSessionScreenIsLocked.
// This does the same with public CoreGraphics API: no Accessibility permission,
// no distributed notifications, no private login.framework call to read state.
//
// Observed on macOS 14 (this Mac, verified): while the console session is
// unlocked the key is ABSENT, and while it is locked the key is present with a
// true value. Treating absence as "unknown" would leave Touch ID off forever
// after a close that never actually locked, so the interpretation is:
//
//   key present            -> that boolean value
//   key absent + on console -> false (unlocked)
//   otherwise               -> nil (unknown)
//
// `nil` still never means "safe to restore": the policy treats unknown as
// "not proven unlocked" for the late-turn-off decision and only restores on a
// proven false. The timer exists only between `start()` and `stop()`.

import Foundation
import CoreGraphics

@MainActor
final class ScreenLockObserver {

    /// The key the login session dictionary uses for the screen lock.
    nonisolated static let screenLockedKey = "CGSSessionScreenIsLocked"
    nonisolated static let onConsoleKey = "kCGSSessionOnConsoleKey"

    /// Poll interval while a hand-back is owed. One second is enough for an
    /// unlock prompt without spinning the CPU.
    nonisolated static let pollInterval: TimeInterval = 1

    /// Interpret a session dictionary. Pure, so the tri-state rule is testable
    /// without a login session.
    nonisolated static func interpret(_ dictionary: [String: Any]?) -> Bool? {
        guard let dictionary else { return nil }
        if let value = dictionary[screenLockedKey] {
            if let number = value as? NSNumber { return number.boolValue }
            if let text = value as? String {
                switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "1", "true", "yes": return true
                case "0", "false", "no": return false
                default: return nil
                }
            }
            return nil
        }
        // The key is omitted while unlocked. Only trust that within a console
        // session; elsewhere the dictionary carries no lock evidence either way.
        if let onConsole = dictionary[onConsoleKey] as? NSNumber, onConsole.boolValue {
            return false
        }
        if let onConsole = dictionary[onConsoleKey] as? String,
           ["1", "true", "yes"].contains(onConsole.lowercased()) {
            return false
        }
        return nil
    }

    /// Read the current lock state. `nil` means the dictionary was unavailable
    /// or carried no lock evidence: unknown, not unlocked.
    nonisolated static func readIsLocked() -> Bool? {
        guard let raw = CGSessionCopyCurrentDictionary() else { return nil }
        return interpret(raw as? [String: Any])
    }

    /// Convenience spelling for callers that only need a sample.
    nonisolated static var isLocked: Bool? { readIsLocked() }

    /// Fired on a false -> true transition (including the first true sample).
    var onLocked: (() -> Void)?
    /// Fired on a true -> false transition. A `nil` sample never fires this.
    var onUnlocked: (() -> Void)?

    private(set) var isRunning = false
    private(set) var lastKnown: Bool?
    private var timer: Timer?

    var hasTimer: Bool { isRunning }

    /// Start polling. The first sample seeds `lastKnown` and does not fire a
    /// callback: a caller that owes a hand-back checks `isLocked` itself when it
    /// starts the observer. Every later change fires exactly one transition.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastKnown = Self.readIsLocked()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        lastKnown = nil
    }

    /// One manual sample. Public so a caller can settle a trigger immediately
    /// without waiting for the next timer tick; it still only reports a real
    /// transition.
    @discardableResult
    func poll() -> Bool? {
        guard isRunning else { return lastKnown }
        let current = Self.readIsLocked()
        // Unknown stays unknown: keep the last proven value and fire nothing.
        guard let current else { return lastKnown }
        let previous = lastKnown
        lastKnown = current
        guard previous != current else { return current }
        if current { onLocked?() } else { onUnlocked?() }
        return current
    }
}
