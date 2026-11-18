import Foundation

@main
struct ComponentDefaultsTests {
    static func main() {
        let suite = "ComponentDefaultsTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        // A fresh install has no stored values, so nothing is "modified".
        precondition(!ComponentDefaults.isModified("sleepUntilReset", defaults: defaults))

        // Only this component's keys are touched.
        defaults.set(75, forKey: "sleepUntilReset.idleMinutes")
        defaults.set(45, forKey: "agentLight.minutes")
        precondition(ComponentDefaults.isModified("sleepUntilReset", defaults: defaults))

        ComponentDefaults.restore("sleepUntilReset", defaults: defaults)
        precondition(defaults.integer(forKey: "sleepUntilReset.idleMinutes") == 30)
        precondition(defaults.integer(forKey: "sleepUntilReset.waitingMinutes") == 15)
        precondition(defaults.integer(forKey: "agentLight.minutes") == 45,
                     "restoring one component must not touch another")
        precondition(!ComponentDefaults.isModified("sleepUntilReset", defaults: defaults))
        precondition(ComponentDefaults.isModified("agentLight", defaults: defaults))

        // Booleans, strings and arrays all round-trip through the comparison.
        defaults.set(false, forKey: "agentNotifications.sound")
        defaults.set("HomeNet", forKey: "armOnWiFi.ssid")
        defaults.set([2, 4], forKey: "armOnSchedule.weekdays")
        precondition(ComponentDefaults.isModified("agentNotifications", defaults: defaults))
        precondition(ComponentDefaults.isModified("armOnWiFi", defaults: defaults))
        precondition(ComponentDefaults.isModified("armOnSchedule", defaults: defaults))

        ComponentDefaults.restore("agentNotifications", defaults: defaults)
        ComponentDefaults.restore("armOnWiFi", defaults: defaults)
        ComponentDefaults.restore("armOnSchedule", defaults: defaults)
        precondition(defaults.bool(forKey: "agentNotifications.sound"))
        precondition((defaults.string(forKey: "armOnWiFi.ssid") ?? "x").isEmpty)
        precondition(defaults.array(forKey: "armOnSchedule.weekdays") as? [Int] == Array(1...7))

        print("PASS: component defaults are scoped, detected and restored")
    }
}