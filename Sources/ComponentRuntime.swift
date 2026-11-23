// ComponentRuntime — evaluates component rules against the world and turns them into
// arm/disarm/notify actions. Same vocabulary as the shipped SDK.

import Foundation
import AppKit

struct ComponentEnvironment {
    var lidClosed: Bool
    var sessionActive: Bool
    var onCharger: Bool
    var batteryPercent: Int?
    var externalDisplay: Bool
    var runningBundleIDs: Set<String>
    var now: Date
    var sessionSeconds: TimeInterval
    var closedSeconds: TimeInterval
}

@MainActor
final class ComponentRuntime {
    static let shared = ComponentRuntime()

    private struct State {
        var lidClosed = false
        var onCharger = false
        var batteryWasBelow: Set<String> = []
        var firedClosedFor: Set<Int> = []
        var firedSessionFor: Set<Int> = []
        var sessionStartedAt: Date?
        var closedStartedAt: Date?
        var letGoTimes: [Date] = []
        var stopped = false
        var lastNotificationAt: Date?
        /// False until the first tick seeds observations. A newly enabled or
        /// reloaded component must not invent lid/charger/session transitions
        /// from its default false state.
        var primed = false
    }

    private var states: [String: State] = [:]
    private var definitions: [String: Data] = [:]
    private var timer: Timer?
    private var enablementObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private let tickInterval: TimeInterval = 2

    private init() {}

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Common modes keep rules running while a modal alert is open.
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.didWake() }
        }
        enablementObserver = NotificationCenter.default.addObserver(forName: .componentEnablementChanged, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let id = note.object as? String else { return }
                self?.reset(id: id)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let enablementObserver {
            NotificationCenter.default.removeObserver(enablementObserver)
            self.enablementObserver = nil
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        for id in Array(states.keys) { reset(id: id) }
    }

    private func didWake() {
        tick()
        for component in ComponentStore.shared.components where ComponentStore.shared.isEnabled(component.id) {
            guard var state = states[component.id], !state.stopped else { continue }
            dispatch(event: "wake", component: component, env: currentEnvironment(), state: &state)
            states[component.id] = state
        }
    }

    private func owner(_ id: String) -> String { "custom:\(id)" }

    private func reset(id: String) {
        PowerEngine.shared.releaseAutomaticArm(owner: owner(id), reason: "component disabled or reloaded")
        states.removeValue(forKey: id)
        definitions.removeValue(forKey: id)
    }

    // MARK: - Tick

    private func tick() {
        let engine = PowerEngine.shared
        let enabled = ComponentStore.shared.components.filter { ComponentStore.shared.isEnabled($0.id) }
        let activeIDs = Set(enabled.map(\.id))
        for id in Array(states.keys) where !activeIDs.contains(id) { reset(id: id) }

        for component in enabled {
            let definition = try? JSONSerialization.data(withJSONObject: ["rules": component.rules, "values": component.values], options: [.sortedKeys])
            if definitions[component.id] != definition { reset(id: component.id) }
            definitions[component.id] = definition
            var env = currentEnvironment()
            var state = states[component.id] ?? State()
            guard !state.stopped else { continue }

            let wantsHold = component.rules.contains { rule in
                guard let condition = rule["keepAwakeWhile"] else { return false }
                return evaluate(condition, component: component, env: env, state: &state)
            }

            if wantsHold {
                let wasArmed = engine.isArmed
                _ = engine.requestAutomaticArm(owner: owner(component.id), source: "component \(component.name)")
                if !wasArmed && engine.isArmed {
                    Notifier.post(title: component.name, body: "Wakely armed. You can close the lid.")
                }
            } else {
                let wasOwner = engine.isAutomaticOwner(owner(component.id))
                engine.releaseAutomaticArm(owner: owner(component.id), reason: "\(component.name) let go")
                if wasOwner {
                    state.letGoTimes.append(Date())
                    state.letGoTimes.removeAll { Date().timeIntervalSince($0) >= 600 }
                    if state.letGoTimes.count > 6 {
                        state.stopped = true
                        Diagnostics.log("component \(component.id): stopped after repeated let-go")
                    }
                }
            }
            env = currentEnvironment()
            if !state.primed {
                state.primed = true
                state.lidClosed = env.lidClosed
                state.onCharger = env.onCharger
                state.sessionStartedAt = engine.armedAt
                state.closedStartedAt = engine.closedSince
            }
            let sessionStart = engine.armedAt
            let closedStart = engine.closedSince
            if state.sessionStartedAt != sessionStart {
                let hadSession = state.sessionStartedAt != nil
                state.firedSessionFor.removeAll()
                state.sessionStartedAt = sessionStart
                if hadSession { dispatch(event: "sessionEnded", component: component, env: env, state: &state) }
                env = currentEnvironment()
                if engine.armedAt == sessionStart && sessionStart != nil {
                    dispatch(event: "sessionStarted", component: component, env: env, state: &state)
                }
            }
            env = currentEnvironment()
            if state.closedStartedAt != closedStart {
                let hadClosedSession = state.closedStartedAt != nil
                state.firedClosedFor.removeAll()
                state.closedStartedAt = closedStart
                if hadClosedSession { dispatch(event: "closedSessionEnded", component: component, env: env, state: &state) }
                env = currentEnvironment()
                if engine.closedSince == closedStart && closedStart != nil {
                    dispatch(event: "closedSessionStarted", component: component, env: env, state: &state)
                }
            }
            env = currentEnvironment()

            // Moment events
            if env.lidClosed != state.lidClosed {
                dispatch(event: env.lidClosed ? "lidClosed" : "lidOpened", component: component, env: env, state: &state)
                state.lidClosed = env.lidClosed
            }

            if env.onCharger != state.onCharger {
                dispatch(event: env.onCharger ? "pluggedIn" : "unplugged", component: component, env: env, state: &state)
                state.onCharger = env.onCharger
            }

            dispatchTimedEvents(component: component, env: currentEnvironment(), state: &state)
            dispatchBatteryCrossing(component: component, env: currentEnvironment(), state: &state)
            states[component.id] = state
        }
    }

    private func dispatchTimedEvents(component: ComponentSpec, env: ComponentEnvironment, state: inout State) {
        for (index, rule) in component.rules.enumerated() {
            let env = currentEnvironment()
            guard let event = rule["on"] as? String else { continue }
            if let condition = rule["when"], !evaluate(condition, component: component, env: env, state: &state) {
                continue
            }
            switch event {
            case "closedFor":
                guard !state.firedClosedFor.contains(index), env.lidClosed, env.sessionActive,
                      env.closedSeconds >= minutes(rule["after"], component: component) * 60 else { continue }
                state.firedClosedFor.insert(index)
                run(actions: rule["do"], component: component, event: event, env: env, state: &state)
            case "sessionFor":
                guard !state.firedSessionFor.contains(index), env.sessionActive,
                      env.sessionSeconds >= minutes(rule["after"], component: component) * 60 else { continue }
                state.firedSessionFor.insert(index)
                run(actions: rule["do"], component: component, event: event, env: env, state: &state)
            default:
                continue
            }
        }
    }

    private func dispatchBatteryCrossing(component: ComponentSpec, env: ComponentEnvironment, state: inout State) {
        guard let battery = env.batteryPercent else { return }
        for (index, rule) in component.rules.enumerated() {
            let env = currentEnvironment()
            guard let event = rule["on"] as? String, event == "batteryBelow" else { continue }
            let threshold = minutes(rule["below"], component: component)
            let key = String(index)
            if Double(battery) < threshold {
                if !state.batteryWasBelow.contains(key) {
                    state.batteryWasBelow.insert(key)
                    if let condition = rule["when"], !evaluate(condition, component: component, env: env, state: &state) {
                        continue
                    }
                    run(actions: rule["do"], component: component, event: event, env: env, state: &state)
                }
            } else {
                state.batteryWasBelow.remove(key)
            }
        }
    }

    private func dispatch(event: String, component: ComponentSpec, env: ComponentEnvironment, state: inout State) {
        for rule in component.rules {
            let env = currentEnvironment()
            guard let ruleEvent = rule["on"] as? String, ruleEvent == event else { continue }
            if let condition = rule["when"], !evaluate(condition, component: component, env: env, state: &state) {
                continue
            }
            run(actions: rule["do"], component: component, event: event, env: env, state: &state)
        }
    }

    private func run(actions: Any?, component: ComponentSpec, event: String, env: ComponentEnvironment, state: inout State) {
        guard let list = actions as? [[String: Any]] else { return }
        for action in list {
            if let reason = action["endSession"] as? String {
                guard PowerEngine.shared.isArmed else { continue }
                PowerEngine.shared.disarm(reason: reason)
                Diagnostics.log("component \(component.id) ended the session: \(reason)")
            } else if action["notify"] != nil {
                let now = Date()
                guard state.lastNotificationAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { continue }
                state.lastNotificationAt = now
                if let text = action["notify"] as? String {
                    Notifier.post(title: component.name, body: text)
                } else if let payload = action["notify"] as? [String: Any] {
                    Notifier.post(title: payload["title"] as? String ?? component.name,
                                  body: payload["body"] as? String ?? component.tagline)
                }
            }
        }
    }

    // MARK: - Conditions

    private func evaluate(_ condition: Any, component: ComponentSpec, env: ComponentEnvironment, state: inout State) -> Bool {
        if let name = condition as? String {
            switch name {
            case "onCharger": return env.onCharger
            case "onBattery": return !env.onCharger
            case "externalDisplay": return env.externalDisplay
            case "lidClosed": return env.lidClosed
            case "sessionActive": return env.sessionActive
            default: return false
            }
        }
        guard let dict = condition as? [String: Any], let (key, value) = dict.first else { return false }
        switch key {
        case "all":
            return (value as? [Any])?.allSatisfy { evaluate($0, component: component, env: env, state: &state) } ?? false
        case "any":
            return (value as? [Any])?.contains { evaluate($0, component: component, env: env, state: &state) } ?? false
        case "not":
            return !evaluate(value, component: component, env: env, state: &state)
        case "appRunning":
            let ids = bundleIDs(for: value, component: component)
            return !ids.isDisjoint(with: env.runningBundleIDs)
        case "batteryAbove":
            guard let battery = env.batteryPercent else { return false }
            return Double(battery) > number(value, component: component)
        case "batteryBelow":
            guard let battery = env.batteryPercent else { return false }
            return Double(battery) < number(value, component: component)
        case "timeBetween":
            guard let pair = value as? [String], pair.count == 2 else { return false }
            return insideWindow(now: env.now, start: pair[0], end: pair[1])
        case "choiceIs":
            guard let choice = value as? [String: String], let (key, word) = choice.first else { return false }
            let current = resolvedValue(for: key, component: component) as? String ?? ""
            return current == word
        default:
            return false
        }
    }

    private func bundleIDs(for value: Any, component: ComponentSpec) -> Set<String> {
        if let ids = value as? [String] { return Set(ids.filter { !$0.isEmpty }) }
        guard let key = value as? String else { return [] }
        let stored = resolvedValue(for: key, component: component)
        return Set((stored as? [String] ?? []).filter { !$0.isEmpty })
    }

    /// Persisted overrides are user data and can outlive a component's edited
    /// schema. Normalize them against the current specification before rules
    /// consume them, rather than trusting an old type or range.
    private func resolvedValue(for key: String, component: ComponentSpec) -> Any? {
        guard let spec = component.values[key], let kind = spec["kind"] as? String else { return nil }
        let raw = ComponentStore.shared.storedValue(componentID: component.id, key: key)
            ?? spec["default"]
        switch kind {
        case "apps":
            return (raw as? [String])?.filter { !$0.isEmpty } ?? []
        case "choice":
            let options = spec["options"] as? [String] ?? []
            if let index = (raw as? NSNumber)?.intValue, options.indices.contains(index) {
                return options[index]
            }
            if let text = raw as? String, options.contains(text) { return text }
            if let fallback = spec["default"] as? NSNumber,
               options.indices.contains(fallback.intValue) { return options[fallback.intValue] }
            return options.first
        case "duration", "minutes", "percent", "number":
            guard let number = raw as? NSNumber, number.doubleValue.isFinite else { return nil }
            let fallbackBounds: ClosedRange<Double> = kind == "duration" ? 15...720
                : kind == "minutes" ? 1...720 : kind == "percent" ? 1...100
                : -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
            let lower = (spec["min"] as? NSNumber)?.doubleValue ?? fallbackBounds.lowerBound
            let upper = (spec["max"] as? NSNumber)?.doubleValue ?? fallbackBounds.upperBound
            return NSNumber(value: min(max(number.doubleValue, lower), upper))
        default:
            return nil
        }
    }

    private func number(_ value: Any, component: ComponentSpec) -> Double {
        if let n = value as? NSNumber { return n.doubleValue }
        guard let key = value as? String else { return 0 }
        return (resolvedValue(for: key, component: component) as? NSNumber)?.doubleValue ?? 0
    }

    private func minutes(_ value: Any?, component: ComponentSpec) -> Double {
        guard let value else { return 0 }
        return number(value, component: component)
    }

    private func insideWindow(now: Date, start: String, end: String) -> Bool {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let current = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        func parse(_ text: String) -> Double? {
            let parts = text.split(separator: ":")
            guard parts.count == 2, let h = Double(parts[0]), let m = Double(parts[1]) else { return nil }
            return h * 60 + m
        }
        guard let s = parse(start), let e = parse(end) else { return false }
        return s <= e ? (current >= s && current < e) : (current >= s || current < e)
    }

    // MARK: - Environment

    private func currentEnvironment() -> ComponentEnvironment {
        let engine = PowerEngine.shared
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return ComponentEnvironment(
            lidClosed: engine.lidClosed,
            sessionActive: engine.isArmed,
            onCharger: !engine.onBattery(),
            batteryPercent: engine.batteryPercent(),
            externalDisplay: engine.externalDisplayCount() > 0,
            runningBundleIDs: running,
            now: Date(),
            sessionSeconds: engine.armedAt.map { Date().timeIntervalSince($0) } ?? 0,
            closedSeconds: engine.closedSince.map { Date().timeIntervalSince($0) } ?? 0)
    }
}
