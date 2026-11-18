// Feedback — serialized audio work, completion-aware lid feedback and notices.

import Foundation
import AVFoundation
import AudioToolbox
import AppKit

/// All framework audio objects belong to this queue, never to the main actor.
/// A cancellation ticket is invalidated synchronously, including while a backend
/// is blocked opening an audio device. Late returns cannot start a fallback.
private final class CloseSoundTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    func cancel() { lock.lock(); valid = false; lock.unlock() }
    var isValid: Bool { lock.lock(); defer { lock.unlock() }; return valid }
}

private final class CloseSoundBackend: @unchecked Sendable {
    let queue = DispatchQueue(label: "dev.wakely.close-sound", qos: .userInitiated)
    private var systemSounds: [URL: SystemSoundID] = [:]
    private var durations: [URL: TimeInterval] = [:]
    private var filePlayer: AVAudioPlayer?
    private var appKitSound: NSSound?
    private var currentSystemSound: SystemSoundID?

    func prepare(url: URL?, cafURL: URL?) {
        queue.async { [self] in
            if let url { _ = duration(url) }
            if let cafURL { _ = systemSound(cafURL) }
        }
    }

    private func duration(_ url: URL) -> TimeInterval {
        if let value = durations[url] { return value }
        if let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 {
            let value = Double(file.length) / file.processingFormat.sampleRate
            durations[url] = value
            return value
        }
        return 2
    }

    private func systemSound(_ url: URL) -> SystemSoundID? {
        if let sound = systemSounds[url] { return sound }
        var sound: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(url as CFURL, &sound) == kAudioServicesNoError else { return nil }
        systemSounds[url] = sound
        return sound
    }

    func play(url: URL?, cafURL: URL?, ticket: CloseSoundTicket,
              started: @escaping @Sendable (TimeInterval) -> Void,
              finished: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            guard ticket.isValid else { return }
            stopCurrent()
            // The system-sound API has a real completion callback and avoids a
            // synchronous NSSound.play() device-open on the event-handling thread.
            if let cafURL, let sound = systemSound(cafURL), ticket.isValid {
                currentSystemSound = sound
                let length = duration(cafURL)
                let startedAt = Date()
                started(length)
                AudioServicesPlaySystemSoundWithCompletion(sound) { [self] in
                    let elapsed = Date().timeIntervalSince(startedAt)
                    queue.async { [self] in
                        guard ticket.isValid else { return }
                        // A completion far ahead of the CAF's known duration means
                        // the output device never opened (typical once the lid
                        // switch cuts audio). Fall through to a file backend.
                        if elapsed < max(0.15, length * 0.4) {
                            Diagnostics.log("close sound caf finished early; trying file fallback")
                            stopCurrent()
                            playFileBackends(url: url, ticket: ticket, started: started,
                                             finished: finished)
                        } else {
                            finished(true)
                        }
                    }
                }
                return
            }
            // Missing/unsupported CAF: use a file player off-main. A failed play
            // must fall through, not silently prevent every remaining backend.
            playFileBackends(url: url, ticket: ticket, started: started, finished: finished)
        }
    }

    /// Queue-confined AV/NSSound fallback, used when the CAF cannot be created or
    /// its completion shows that playback never actually started.
    private func playFileBackends(url: URL?, ticket: CloseSoundTicket,
                                  started: @escaping @Sendable (TimeInterval) -> Void,
                                  finished: @escaping @Sendable (Bool) -> Void) {
        if let url, ticket.isValid, let player = try? AVAudioPlayer(contentsOf: url) {
            player.volume = 0.7
            filePlayer = player
            if player.prepareToPlay(), ticket.isValid, player.play() {
                guard ticket.isValid else { player.stop(); return }
                started(player.duration)
                pollCompletion(ticket: ticket, player: player, sound: nil, finished: finished)
                return
            }
            player.stop()
        }
        if let url, ticket.isValid, let sound = NSSound(contentsOf: url, byReference: false) {
            sound.volume = 0.7
            appKitSound = sound
            if sound.play() {
                guard ticket.isValid else { sound.stop(); return }
                started(sound.duration)
                pollCompletion(ticket: ticket, player: nil, sound: sound, finished: finished)
                return
            }
            sound.stop()
        }
        if ticket.isValid { finished(false) }
    }

    private func pollCompletion(ticket: CloseSoundTicket, player: AVAudioPlayer?, sound: NSSound?,
                                finished: @escaping @Sendable (Bool) -> Void) {
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            guard ticket.isValid else { player?.stop(); sound?.stop(); return }
            if player?.isPlaying == true || sound?.isPlaying == true {
                pollCompletion(ticket: ticket, player: player, sound: sound, finished: finished)
            } else {
                finished(true)
            }
        }
    }

    private func stopCurrent() {
        filePlayer?.stop(); filePlayer = nil
        appKitSound?.stop(); appKitSound = nil
        if let sound = currentSystemSound {
            // Dispose instead of replaying the same ID with a stale completion.
            AudioServicesDisposeSystemSoundID(sound)
            systemSounds = systemSounds.filter { $0.value != sound }
            currentSystemSound = nil
        }
    }

    func stop() { queue.async { [self] in stopCurrent() } }
}

@MainActor
final class CloseSoundPlayer {
    static let shared = CloseSoundPlayer()
    static let availableSounds = ["shell", "pearl", "chime", "lullaby", "tide", "sonar", "bubble", "arcade"]
    private let backend = CloseSoundBackend()
    private var ticket: CloseSoundTicket?
    private var completion: ((Bool) -> Void)?
    private var startedHandler: (() -> Void)?
    private var startedReported = false
    private var lastPlaybackSucceeded = true
    private var deadline: TimeInterval = 0
    private var watchdog: Task<Void, Never>?
    private let startupAllowance: TimeInterval = 1.5
    private let maximumPlayback: TimeInterval = 10

    /// Includes queued startup as well as every active backend, so sleep and
    /// Quiet Close do not treat a queued/playing CAF or NSSound as silence.
    var playbackRemaining: TimeInterval {
        guard ticket != nil else { return 0 }
        return max(0, deadline - ProcessInfo.processInfo.systemUptime)
    }

    private var selectedName: String {
        Self.availableSounds.contains(soundName) ? soundName : "shell"
    }

    func prepare() {
        let name = selectedName
        backend.prepare(url: AppResources.url(name: "close-sound-\(name)", extension: "m4a"),
                        cafURL: AppResources.url(name: "close-sound-\(name)", extension: "caf"))
    }

    var soundName: String {
        get { UserDefaults.standard.string(forKey: "lidCloseSoundName") ?? "shell" }
        set { UserDefaults.standard.set(newValue, forKey: "lidCloseSoundName") }
    }
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "lidCloseSoundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "lidCloseSoundEnabled") }
    }

    /// Returns whether a request was accepted, not proof it was audible.
    /// `started` fires only after a backend has actually begun playback; the
    /// completion reports backend completion/failure. All opening/play calls are
    /// off-main. Existing preview callers can keep ignoring the return value.
    @discardableResult
    func play(preview: Bool = false, started: (() -> Void)? = nil,
              completion: ((Bool) -> Void)? = nil) -> Bool {
        guard preview || isEnabled else { return false }
        let name = selectedName
        let url = AppResources.url(name: "close-sound-\(name)", extension: "m4a")
        let cafURL = AppResources.url(name: "close-sound-\(name)", extension: "caf")
        guard url != nil || cafURL != nil else {
            Diagnostics.log("close sound missing: \(name)")
            return false
        }
        cancel()
        let request = CloseSoundTicket()
        ticket = request
        startedHandler = started
        startedReported = false
        self.completion = completion
        lastPlaybackSucceeded = false
        deadline = ProcessInfo.processInfo.systemUptime + startupAllowance
        armWatchdog(for: request)
        backend.play(url: url, cafURL: cafURL, ticket: request, started: { duration in
            Task { @MainActor [weak self] in
                guard let self, self.ticket === request, request.isValid else { return }
                self.deadline = ProcessInfo.processInfo.systemUptime + min(max(0.1, duration), self.maximumPlayback) + 0.2
                self.armWatchdog(for: request)
                Diagnostics.log("close sound backend started: \(name), duration=\(duration)s")
                self.reportStarted(request)
            }
        }, finished: { success in
            Task { @MainActor [weak self] in self?.finish(request, success: success) }
        })
        Diagnostics.log("close sound queued: \(name)")
        return true
    }

    /// Reports the first real backend start for this request. A request that is
    /// superseded or cancelled before any backend starts never reports.
    private func reportStarted(_ request: CloseSoundTicket) {
        guard ticket === request, !startedReported, request.isValid else { return }
        startedReported = true
        let handler = startedHandler
        startedHandler = nil
        handler?()
    }

    private func armWatchdog(for request: CloseSoundTicket) {
        watchdog?.cancel()
        let delay = playbackRemaining
        watchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, delay) * 1_000_000_000)) }
            catch { return }
            guard let self, self.ticket === request else { return }
            Diagnostics.log("close sound completion timed out")
            self.finish(request, success: false)
        }
    }

    private func finish(_ request: CloseSoundTicket, success: Bool) {
        guard ticket === request else { return }
        // A successful completed playback necessarily started; report it even if
        // the backend's start callback lost the race with completion.
        if success { reportStarted(request) }
        let callback = completion
        completion = nil
        startedHandler = nil
        startedReported = false
        lastPlaybackSucceeded = success
        ticket = nil
        deadline = 0
        request.cancel()
        watchdog?.cancel(); watchdog = nil
        if !success { backend.stop() }
        Diagnostics.log("close sound completed: success=\(success)")
        callback?(success)
    }

    /// Wait for the current request, including backend startup. A newer preview,
    /// cancellation, or timeout returns false rather than delaying a caller forever.
    func waitForPlaybackCompletion(timeout: TimeInterval = 4) async -> Bool {
        guard let request = ticket else { return lastPlaybackSucceeded }
        let limit = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while ticket === request {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < limit else { return false }
            do { try await Task.sleep(nanoseconds: 25_000_000) } catch { return false }
        }
        return ticket == nil && lastPlaybackSucceeded
    }

    func cancel() {
        guard let ticket else { return }
        finish(ticket, success: false)
    }
}

enum Notifier {
    static func post(title: String, body: String, sound: Bool = true) {
        Diagnostics.log("notification: \(title) — \(body)")
        Task { @MainActor in
            await WakelyNotifications.shared.post(title: title, body: body, sound: sound)
        }
    }
}
