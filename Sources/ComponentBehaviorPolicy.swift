import Foundation

/// Pure policies shared by runtime and regression tests; no IOKit or app effects.
struct ClosedBatteryBudget {
    private(set) var consumed = 0
    private var previous: Int?
    mutating func sample(percent: Int?, closed: Bool, armed: Bool, onBattery: Bool) -> Int {
        guard closed && armed else { reset(); return 0 }
        guard onBattery, let percent else { previous = nil; return consumed }
        if let previous { consumed += max(0, previous - percent) }
        previous = percent
        return consumed
    }
    mutating func reset() { consumed = 0; previous = nil }
}

struct ConditionGrace {
    private var lastTrue: Date?
    mutating func active(_ condition: Bool, now: Date, seconds: TimeInterval, eligible: Bool = true) -> Bool {
        guard eligible else { lastTrue = nil; return false }
        if condition { lastTrue = now; return true }
        return lastTrue.map { now.timeIntervalSince($0) < seconds } ?? false
    }
    mutating func reset() { lastTrue = nil }
}

struct BoundedWorkSnapshot {
    private(set) var ids: Set<String> = []
    private(set) var started: Date?
    private var waitingSince: Date?
    private(set) var completed = false
    mutating func begin(ids: Set<String>, now: Date) {
        self.ids = ids; started = now; waitingSince = nil; completed = false
    }
    mutating func active(current: Set<String>, waiting: Set<String> = [], now: Date,
                         maximum: TimeInterval, waitingMaximum: TimeInterval? = nil) -> Bool {
        guard !completed, let started else { return false }
        let remaining = ids.intersection(current)
        if remaining.isEmpty || now.timeIntervalSince(started) >= maximum { completed = true; return false }
        if remaining.isSubset(of: waiting) {
            waitingSince = waitingSince ?? now
            if let limit = waitingMaximum, let since = waitingSince, now.timeIntervalSince(since) >= limit {
                completed = true; return false
            }
        } else { waitingSince = nil }
        return true
    }
    mutating func reset() { self = BoundedWorkSnapshot() }
}

enum ComponentSchedulePolicy {
    /// Weekdays use Calendar conventions: Sunday=1 ... Saturday=7. Overnight
    /// windows belong to the day on which they started.
    static func contains(now: Date, start: String, end: String, weekdays: [Int], calendar: Calendar = .current) -> Bool {
        func parse(_ text: String) -> Int? {
            let pieces = text.split(separator: ":")
            guard pieces.count == 2, let h = Int(pieces[0]), let m = Int(pieces[1]),
                  (0...23).contains(h), (0...59).contains(m) else { return nil }
            return h * 60 + m
        }
        guard let a = parse(start), let b = parse(end), a != b else { return false }
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        var weekday = components.weekday ?? 1
        let inside = a < b ? minute >= a && minute < b : minute >= a || minute < b
        if a > b && minute < b { weekday = weekday == 1 ? 7 : weekday - 1 }
        return inside && Set(weekdays).contains(weekday)
    }
}

enum TimeMachineStatus {
    static func isDefinitelyIdle(_ text: String) -> Bool {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last,
              let data = String(text[first...last]).data(using: .utf8),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any], let running = dictionary["Running"] else { return false }
        if let number = running as? NSNumber { return !number.boolValue }
        if let string = running as? String { return string == "0" }
        return false
    }
}

/// One token per pending enable. Cancellation and stop invalidate old replies,
/// including an off/on ABA sequence; repeated on requests share one probe.
struct PendingComponentEnablement {
    private var requests: [String: UUID] = [:]
    mutating func begin(_ id: String) -> UUID? {
        guard requests[id] == nil else { return nil }
        let token = UUID()
        requests[id] = token
        return token
    }
    mutating func cancel(_ id: String) { requests.removeValue(forKey: id) }
    mutating func cancelAll() { requests.removeAll() }
    mutating func consume(_ id: String, token: UUID) -> Bool {
        guard requests[id] == token else { return false }
        requests.removeValue(forKey: id)
        return true
    }
}

/// A session-only helper write remains wanted only for the exact closed session
/// that requested it. Persistent settings deliberately do not inherit that scope.
enum ProtectedApplyLifetime {
    static func wanted(enabled: Bool, persistent: Bool, shuttingDown: Bool,
                       armed: Bool, lidClosed: Bool, requestedEpoch: Int,
                       currentEpoch: Int) -> Bool {
        enabled && (persistent || (!shuttingDown && armed && lidClosed
                                  && requestedEpoch == currentEpoch))
    }
}

struct SleepSafetyContext {
    let lidClosed: Bool
    let armed: Bool
    let externalDisplay: Bool
    var permitsPeripheralChanges: Bool { lidClosed && !armed && !externalDisplay }
}
