import Foundation

@main
struct OnboardingPolicyTests {
    static func main() throws {
        precondition(OnboardingProgress.currentVersion == 2)
        precondition(OnboardingProgress.lastStep == 13)
        let last = OnboardingProgress.lastStep
        let current = OnboardingProgress.currentVersion
        var progress = OnboardingProgress()
        precondition(progress == OnboardingProgress(step: 0, disposition: .unseen, version: current))
        progress.back(); precondition(progress.step == 0)
        for step in 1...last {
            progress.next(); precondition(progress.step == step)
        }
        for step in (0..<last).reversed() {
            progress.back(); precondition(progress.step == step)
        }
        for _ in 0..<(last + 10) { progress.next() }
        precondition(progress.step == last && progress.disposition == .unseen)
        progress.dismiss()
        precondition(progress.step == last && progress.disposition == .dismissed)
        progress.back(); progress.next()
        precondition(progress.disposition == .dismissed)
        progress.complete()
        precondition(progress.step == last && progress.disposition == .completed)
        progress.back(); precondition(progress.disposition == .completed)
        for step in [Int.min, -1, 0, 2, last - 1, last, last + 1, Int.max] {
            let expected = min(last, max(0, step))
            precondition(OnboardingProgress(step: step).step == expected)
            progress.go(to: step); precondition(progress.step == expected)
            let json = "{\"step\":\(step),\"disposition\":\"unseen\",\"version\":1}"
            let decoded = try JSONDecoder().decode(OnboardingProgress.self, from: Data(json.utf8))
            precondition(decoded.step == expected)
        }
        // Public stored properties may be changed by a caller; navigation still clamps safely.
        for step in [Int.min, -1, 0, last, last + 1, Int.max] {
            let clamped = min(last, max(0, step))
            progress.step = step; progress.next()
            precondition(progress.step == min(last, clamped + 1))
            progress.step = step; progress.back()
            precondition(progress.step == max(0, clamped - 1))
        }
        // Legacy records retain their identity and never become fresh-v2 launch permission.
        let legacy = try JSONDecoder().decode(OnboardingProgress.self,
            from: Data("{\"step\":4,\"disposition\":\"unseen\",\"version\":1}".utf8))
        precondition(legacy.version == 1 && legacy.step == 4)
        precondition(!OnboardingLaunchPolicy.shouldAutoPresent(isNewUser: true,
            isLoginLaunch: false, receivedCommand: false, hasPresented: false, progress: legacy))
        for disposition in [OnboardingDisposition.unseen, .dismissed, .completed, .existingUser] {
            for version in [-1, 0, 1, 2, Int.max] {
                let value = OnboardingProgress(step: 3, disposition: disposition, version: version)
                let encoded = try JSONEncoder().encode(value)
                let decoded = try JSONDecoder().decode(OnboardingProgress.self, from: encoded)
                precondition(decoded == value)
                for newUser in [false, true] {
                    for login in [false, true] {
                        for command in [false, true] {
                            for presented in [false, true] {
                                let actual = OnboardingLaunchPolicy.shouldAutoPresent(
                                    isNewUser: newUser, isLoginLaunch: login,
                                    receivedCommand: command, hasPresented: presented, progress: value)
                                let expected = newUser && !login && !command && !presented
                                    && disposition == .unseen && version == current
                                precondition(actual == expected)
                            }
                        }
                    }
                }
            }
        }
        for invalid in ["{}", "{\"step\":0,\"disposition\":\"unknown\",\"version\":1}",
                        "{\"step\":\"0\",\"disposition\":\"unseen\",\"version\":1}",
                        "{\"step\":0,\"disposition\":\"unseen\"}",
                        "{\"step\":null,\"disposition\":\"unseen\",\"version\":1}"] {
            do {
                _ = try JSONDecoder().decode(OnboardingProgress.self, from: Data(invalid.utf8))
                preconditionFailure("Malformed progress must not decode as a fresh user")
            } catch { /* Expected: caller must handle corrupt storage conservatively. */ }
        }
        print("PASS: navigation, clamping, explicit completion, strict decoding, round trips and all launch-policy combinations")
    }
}
