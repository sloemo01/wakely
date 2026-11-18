import Foundation
import CoreGraphics

// Pure interpretation of the login session's lock dictionary. No login session
// is queried, no screen is locked, and nothing changes on the Mac.
@main
struct ScreenLockObserverTests {
    static func main() {
        var checks = 0
        func expect(_ value: Bool?, _ expected: Bool?, _ message: String) {
            precondition(value == expected, message)
            checks += 1
        }

        expect(ScreenLockObserver.interpret(nil), nil, "no dictionary is unknown")
        expect(ScreenLockObserver.interpret([:]), nil, "no keys is unknown")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: 0]), nil,
               "a non-console session with no lock key is unknown")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: 1]), false,
               "a console session with no lock key is unlocked (observed macOS behaviour)")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: "1"]), false,
               "string console flag is accepted")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: 1,
                                            ScreenLockObserver.screenLockedKey: 1]), true,
               "a present true lock key wins")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: 1,
                                            ScreenLockObserver.screenLockedKey: 0]), false,
               "a present false lock key means unlocked")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.screenLockedKey: 1]), true,
               "a present true lock key is enough without the console flag")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: 1,
                                            ScreenLockObserver.screenLockedKey: "YES"]), true,
               "string lock values parse")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: 1,
                                            ScreenLockObserver.screenLockedKey: "maybe"]), nil,
               "a garbled lock value is unknown, never unlocked")
        expect(ScreenLockObserver.interpret([ScreenLockObserver.onConsoleKey: 1,
                                            ScreenLockObserver.screenLockedKey: ["x": 1]]), nil,
               "an unexpected lock value type is unknown")

        print("Screen lock interpretation: \(checks) checks PASS")
    }
}
