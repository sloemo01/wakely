import Foundation

@main struct ComponentValidatorTests {
    static func main() throws {
        var checks = 0
        func check(_ result: Bool, _ message: String) {
            precondition(result, message); checks += 1
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let examples = root.appendingPathComponent("harvest/components-kit/sdk/examples")
        for folder in try FileManager.default.contentsOfDirectory(at: examples, includingPropertiesForKeys: nil) where folder.hasDirectoryPath {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("component.json"))) as! [String: Any]
            let errors = ComponentValidator.validate(json, folderID: folder.lastPathComponent)
            check(errors.isEmpty, "SDK example \(folder.lastPathComponent): \(errors)")
        }
        let valid: [String: Any] = ["format": 1, "id": "test-component", "name": "Test Component", "tagline": "Notify when the Mac wakes.", "description": "Notifies you when the Mac wakes up.", "rules": [["on": "wake", "do": [["notify": "Awake now"]]]]]
        func rejects(_ mutate: (inout [String: Any]) -> Void, _ message: String) {
            var json = valid; mutate(&json)
            check(!ComponentValidator.validate(json, folderID: "test-component").isEmpty, message)
        }
        check(ComponentValidator.validate(valid, folderID: "test-component").isEmpty, "plain description is supported")
        for field in ["format", "id", "name", "tagline", "description", "rules"] {
            rejects({ $0.removeValue(forKey: field) }, "reject missing \(field)")
        }
        rejects({ $0["format"] = true }, "boolean is not a format number")
        rejects({ $0["id"] = "test--component" }, "reject repeated hyphens")
        rejects({ $0["rules"] = [["on": "wkae", "do": [["notify": "Hello"]]]] }, "reject unknown event")
        rejects({ $0["rules"] = [["on": "closedFor", "do": [["endSession": "Done"]]]] }, "timed event requires after")
        rejects({ $0["rules"] = [["on": "batteryBelow", "below": true, "do": [["notify": "Hello"]]]] }, "reject boolean numeric operand")
        rejects({ $0["rules"] = [["keepAwakeWhile": ["not": "lidClosed"]]] }, "nested lid condition cannot keep awake")
        rejects({ $0["rules"] = [["keepAwakeWhile": ["all": []]]] }, "reject vacuously true all")
        rejects({ $0["rules"] = [["keepAwakeWhile": ["timeBetween": ["24:00", "01:00"]]]] }, "reject invalid time")
        rejects({ $0["rules"] = [["on": "wake", "do": [["run": "arbitrary code"]]]] }, "reject unsupported action")
        rejects({ $0["rules"] = [["keepAwakeWhile": ["onBattery": true, "not": "onCharger"]]] }, "one condition operator only")
        rejects({ $0["description"] = ["text": "Wait for {mode} before notifying you.", "values": ["mode": ["kind": "choice", "options": ["yes", "no"], "default": -1]]] }, "negative choice index rejected")
        rejects({ $0["rules"] = [["keepAwakeWhile": ["batteryAbove": "missing"]]] }, "reject undeclared value reference")
        rejects({ $0["description"] = "Unknown {missing} value in description." }, "reject undeclared placeholder")
        rejects({ $0["name"] = "Test\nComponent" }, "text is single line")
        print("Component validator: \(checks) checks PASS")
    }
}
