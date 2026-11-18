import Foundation

enum OnboardingDisposition: String, Codable {
    case unseen, dismissed, completed, existingUser
}

/// Persisted navigation only. Reading or advancing this value has no app effects.
struct OnboardingProgress: Codable, Equatable {
    static let currentVersion = 2
    static let lastStep = 13
    var step: Int
    var disposition: OnboardingDisposition
    var version: Int

    init(step: Int = 0, disposition: OnboardingDisposition = .unseen, version: Int = OnboardingProgress.currentVersion) {
        self.step = Self.clamped(step)
        self.disposition = disposition
        self.version = version
    }

    private static func clamped(_ value: Int) -> Int { min(lastStep, max(0, value)) }
    mutating func go(to step: Int) { self.step = Self.clamped(step) }
    mutating func next() { step = Self.clamped(step); if step < Self.lastStep { step += 1 } }
    mutating func back() { step = Self.clamped(step); if step > 0 { step -= 1 } }
    mutating func dismiss() { disposition = .dismissed }
    mutating func complete() { step = Self.lastStep; disposition = .completed }

    private enum CodingKeys: String, CodingKey { case step, disposition, version }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Missing or malformed persisted fields must not masquerade as a fresh install.
        self.init(step: try values.decode(Int.self, forKey: .step),
                  disposition: try values.decode(OnboardingDisposition.self, forKey: .disposition),
                  version: try values.decode(Int.self, forKey: .version))
    }
}

enum OnboardingLaunchPolicy {
    static func shouldAutoPresent(isNewUser: Bool, isLoginLaunch: Bool,
                                  receivedCommand: Bool, hasPresented: Bool,
                                  progress: OnboardingProgress) -> Bool {
        isNewUser && !isLoginLaunch && !receivedCommand && !hasPresented
            && progress.disposition == .unseen
            && progress.version == OnboardingProgress.currentVersion
    }
}
