// App-free feedback tests. AppResources is the existing compile stub, so no
// bundle asset is opened and no audio device is touched.
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@main
struct FeedbackChimeTests {
    @MainActor
    static func main() async {
        expect(NotificationText.appleScriptLiteral("plain") == "plain", "plain notification text")
        expect(NotificationText.appleScriptLiteral("\\\"") == "\\\\\\\"", "escape slash before quote")
        expect(NotificationText.appleScriptLiteral("a\nb\r") == "a\\nb\\r", "escape line breaks")
        var starts = 0
        var completions: [Bool] = []
        let accepted = CloseSoundPlayer.shared.play(preview: true, started: {
            starts += 1
        }, completion: { success in
            completions.append(success)
        })
        expect(!accepted, "a missing bundled sound must be rejected up front")
        expect(starts == 0, "a request that never starts must not report started")
        expect(completions.isEmpty, "a rejected request has no completion")

        // No active ticket: the completed-state query returns immediately and
        // never blocks a sleep handshake on silence.
        let waited = await CloseSoundPlayer.shared.waitForPlaybackCompletion(timeout: 0.2)
        expect(waited, "no queued playback reports the last successful state")

        print("PASS: 2 feedback chime start-callback tests (no audio device)")
    }
}
