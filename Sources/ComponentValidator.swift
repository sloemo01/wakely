import Foundation
import CoreFoundation

/// Format-1 validation shared by loading and the side-effect-free tests.
/// Reject malformed rules before the runtime can silently ignore or misread them.
enum ComponentValidator {
    static func validate(_ json: [String: Any], folderID: String) -> [String] {
        var errors: [String] = []
        func error(_ path: String, _ message: String) { errors.append("\(path): \(message)") }
        func fields(_ object: [String: Any], _ allowed: Set<String>, _ path: String) {
            for key in object.keys.sorted() where !allowed.contains(key) { error(path, "unknown field \"\(key)\"") }
        }
        func text(_ value: Any?, _ range: ClosedRange<Int>, _ path: String) {
            guard let s = value as? String, range.contains(s.count), !s.contains(where: { $0.isNewline }) else {
                error(path, "must be one line, \(range.lowerBound) to \(range.upperBound) characters"); return
            }
        }
        func integer(_ value: Any?) -> Int? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue,
                  n.doubleValue >= Double(Int.min), n.doubleValue < Double(Int.max) else { return nil }
            return n.intValue
        }
        fields(json, ["format", "id", "name", "tagline", "keywords", "description", "rules"], "component")
        if integer(json["format"]) != 1 { error("format", "must be 1") }
        if let id = json["id"] as? String {
            if id != folderID { error("id", "must match the folder name") }
            if id.range(of: "^[a-z](?:[a-z0-9]|-(?=[a-z0-9])){1,39}$", options: .regularExpression) == nil {
                error("id", "must be 2 to 40 lowercase letters/digits separated by single hyphens")
            }
        } else { error("id", "is required") }
        text(json["name"], 3...30, "name")
        text(json["tagline"], 10...90, "tagline")
        if let raw = json["keywords"] {
            if let words = raw as? [String], words.count <= 12 {
                for word in words { text(word, 1...30, "keywords") }
            } else { error("keywords", "must be at most 12 words") }
        }
        var values: [String: [String: Any]] = [:]
        var description = ""
        if let s = json["description"] as? String { description = s }
        else if let object = json["description"] as? [String: Any] {
            fields(object, ["text", "values"], "description")
            description = object["text"] as? String ?? ""
            if let raw = object["values"] {
                if let specs = raw as? [String: [String: Any]], specs.count <= 6 { values = specs }
                else { error("description.values", "must contain at most 6 value objects") }
            }
        }
        text(description, 20...480, "description.text")
        for key in values.keys.sorted() {
            let spec = values[key]!, path = "values.\(key)"
            fields(spec, ["kind", "default", "min", "max", "step", "unit", "unitPlural", "options"], path)
            guard let kind = spec["kind"] as? String else { error(path, "kind is required"); continue }
            switch kind {
            case "apps":
                if let raw = spec["default"], raw as? [String] == nil { error(path, "apps default must be bundle identifiers") }
            case "choice":
                guard let options = spec["options"] as? [String], options.count == 2,
                      Set(options).count == 2, options.allSatisfy({ !$0.isEmpty }) else { error(path, "choice needs two distinct options"); continue }
                if let index = integer(spec["default"]), options.indices.contains(index) {} 
                else if let s = spec["default"] as? String, options.contains(s) {}
                else { error(path, "choice default must be an option or index 0/1") }
            case "duration", "minutes", "percent", "number":
                let bounds = kind == "duration" ? 15...720 : kind == "minutes" ? 1...720 : kind == "percent" ? 1...100 : Int.min...Int.max
                let min = integer(spec["min"]) ?? bounds.lowerBound
                let max = integer(spec["max"]) ?? bounds.upperBound
                if min > max || !bounds.contains(min) || !bounds.contains(max) { error(path, "invalid min/max range") }
                for field in ["min", "max", "step"] where spec[field] != nil && integer(spec[field]) == nil { error(path, "\(field) must be an integer") }
                if let step = integer(spec["step"]), step < 1 { error(path, "step must be positive") }
                if let n = integer(spec["default"]), n >= min, n <= max {} else { error(path, "default must be an integer within min/max") }
                if kind == "number" {
                    if integer(spec["max"]) == nil { error(path, "number requires max") }
                    text(spec["unit"], 1...40, path + ".unit")
                }
            default: error(path, "unknown value kind")
            }
            if description.components(separatedBy: "{\(key)}").count != 2 { error(path, "must appear exactly once in description") }
        }
        let regex = try! NSRegularExpression(pattern: "\\{([^{}]+)\\}")
        for match in regex.matches(in: description, range: NSRange(description.startIndex..., in: description)) {
            if let range = Range(match.range(at: 1), in: description), values[String(description[range])] == nil { error("description", "undeclared value \(description[range])") }
        }
        var used: Set<String> = []
        func operand(_ raw: Any?, kinds: Set<String>, range: ClosedRange<Int>, path: String) {
            if let key = raw as? String {
                if let spec = values[key], let kind = spec["kind"] as? String, kinds.contains(kind) { used.insert(key) }
                else { error(path, "must reference a \(kinds.sorted().joined(separator: "/")) value") }
            } else if let n = integer(raw), range.contains(n) {} else { error(path, "invalid numeric operand") }
        }
        func condition(_ raw: Any?, hold: Bool, depth: Int, path: String) {
            guard depth <= 4 else { error(path, "conditions may nest at most 4 levels"); return }
            if let name = raw as? String {
                guard ["onCharger", "onBattery", "externalDisplay", "lidClosed", "sessionActive"].contains(name) else { error(path, "unknown condition"); return }
                if hold && ["lidClosed", "sessionActive"].contains(name) { error(path, "session/lid conditions cannot keep awake") }
                return
            }
            guard let object = raw as? [String: Any], object.count == 1, let (key, value) = object.first else { error(path, "condition must have exactly one operator"); return }
            switch key {
            case "all", "any":
                guard let list = value as? [Any], (1...8).contains(list.count) else { error(path, "needs 1 to 8 conditions"); return }
                for child in list { condition(child, hold: hold, depth: depth + 1, path: path + "." + key) }
            case "not": condition(value, hold: hold, depth: depth + 1, path: path + ".not")
            case "batteryAbove", "batteryBelow": operand(value, kinds: ["percent"], range: 1...100, path: path)
            case "appRunning":
                if let ids = value as? [String], (1...8).contains(ids.count), ids.allSatisfy({ !$0.isEmpty }) {}
                else if let key = value as? String, values[key]?["kind"] as? String == "apps" { used.insert(key) }
                else { error(path, "appRunning needs an apps value or 1 to 8 bundle identifiers") }
            case "timeBetween":
                if let pair = value as? [String], pair.count == 2, pair.allSatisfy({ $0.range(of: "^([01][0-9]|2[0-3]):[0-5][0-9]$", options: .regularExpression) != nil }) {}
                else { error(path, "timeBetween needs two HH:mm times") }
            case "choiceIs":
                if let pair = value as? [String: String], pair.count == 1, let (key, word) = pair.first,
                   values[key]?["kind"] as? String == "choice", let options = values[key]?["options"] as? [String], options.contains(word) { used.insert(key) }
                else { error(path, "choiceIs must reference a declared choice option") }
            default: error(path, "unknown condition operator \(key)")
            }
        }
        if let rules = json["rules"] as? [[String: Any]], (1...12).contains(rules.count) {
            for (index, rule) in rules.enumerated() {
                let path = "rules[\(index)]"
                if let hold = rule["keepAwakeWhile"] {
                    fields(rule, ["keepAwakeWhile"], path)
                    condition(hold, hold: true, depth: 1, path: path)
                } else {
                    fields(rule, ["on", "when", "after", "below", "do"], path)
                    let event = rule["on"] as? String ?? ""
                    if !["lidClosed", "lidOpened", "sessionStarted", "sessionEnded", "closedSessionStarted", "closedSessionEnded", "wake", "pluggedIn", "unplugged", "batteryBelow", "closedFor", "sessionFor"].contains(event) { error(path, "unknown or missing event") }
                    if let when = rule["when"] { condition(when, hold: false, depth: 1, path: path + ".when") }
                    if ["closedFor", "sessionFor"].contains(event) { operand(rule["after"], kinds: ["duration", "minutes"], range: 1...720, path: path + ".after") }
                    if event == "batteryBelow" { operand(rule["below"], kinds: ["percent"], range: 1...100, path: path + ".below") }
                    guard let actions = rule["do"] as? [[String: Any]], (1...4).contains(actions.count) else { error(path, "do needs 1 to 4 actions"); continue }
                    for action in actions {
                        guard action.count == 1, let (key, value) = action.first else { error(path, "action must have exactly one operator"); continue }
                        if key == "endSession" { text(value, 2...60, path + ".endSession") }
                        else if key == "notify" {
                            if let payload = value as? [String: Any] {
                                fields(payload, ["title", "body"], path + ".notify")
                                text(payload["body"], 0...140, path + ".notify.body")
                                if let title = payload["title"] { text(title, 0...40, path + ".notify.title") }
                            } else { text(value, 2...140, path + ".notify") }
                        } else { error(path, "unknown action \(key)") }
                    }
                }
            }
        } else { error("rules", "1 to 12 rule objects are required") }
        for key in values.keys.sorted() where !used.contains(key) { error("values.\(key)", "must be used by a rule") }
        return errors
    }
}
