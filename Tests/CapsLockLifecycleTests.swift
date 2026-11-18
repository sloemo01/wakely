import Foundation

// Pure policy tests. No app launch, event tap, HID read/write, TCC request, or
// keyboard mutation. Compile together with Sources/CapsLockLight.swift only.
enum Diagnostics { static func log(_ message: String) {} }

@main
struct CapsLockLifecycleTests {
    static func main() {
        var p = CapsLockFilterPolicy()
        p.request(true)
        assert(!p.shouldFilter, "Disabled component cannot start filtering")
        assert(p.updateSecureInput(true, capsOn: true) == nil)
        p.start()
        assert(!p.shouldFilter, "Watching is independent of session protection")
        p.request(true)
        assert(p.shouldFilter)
        assert(p.updateSecureInput(true, capsOn: true) == false, "Password entry clears an active Caps switch")
        assert(!p.shouldFilter)
        assert(p.updateSecureInput(true, capsOn: false) == nil, "No repeated write after successful clear")
        assert(p.updateSecureInput(false, capsOn: false) == true, "Active session restores after secure entry")
        assert(p.shouldFilter)
        assert(p.updateSecureInput(false, capsOn: true) == nil)

        _ = p.updateSecureInput(true, capsOn: true)
        p.request(false)
        assert(p.updateSecureInput(false, capsOn: false) == nil, "Unarm during password entry cancels restoration")
        assert(!p.shouldFilter)
        p.request(true)
        _ = p.updateSecureInput(true, capsOn: true)
        p.stop()
        assert(!p.watching && !p.requested && !p.shouldFilter)
        assert(!p.restoreAfterSecureInput)
        assert(p.updateSecureInput(false, capsOn: false) == nil, "Disable never restores Caps Lock")
        p.start()
        assert(!p.shouldFilter, "Restart does not inherit the previous session request")
        assert(p.updateSecureInput(true, capsOn: true) == nil, "No session means no keyboard mutation")
        p.request(true)
        assert(p.updateSecureInput(true, capsOn: true) == false, "Arming in secure input protects the password")
        p.stop()
        p.stop()
        assert(!p.shouldFilter, "Stop is idempotent")
        print("PASS Caps Lock lifecycle / secure-input policy (pure tests; no keyboard changes)")
    }
}
