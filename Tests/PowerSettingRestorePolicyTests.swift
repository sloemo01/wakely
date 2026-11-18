import Foundation

@main
struct PowerSettingRestorePolicyTests {
    static func main() {
        typealias Policy = PowerSettingRestorePolicy
        for prior in 0...2 {
            for written in 0...2 {
                for current in 0...2 {
                    let plan = Policy.plan(previous: String(prior), written: String(written), current: current)
                    if current == prior {
                        precondition(plan == .alreadyRestored, "Already-prior state is idempotent without writing")
                    } else if current == written {
                        precondition(plan == .write(prior), "Owned value restores exact prior integer")
                    } else {
                        guard case .refuse(let text) = plan else { preconditionFailure("External edits must refuse") }
                        precondition(text.contains("lease is retained"))
                    }
                }
            }
        }
        precondition(Policy.plan(previous: "2", written: "1", current: 1) == .write(2),
                     "Do not coerce automatic low-power mode 2 to Boolean 1")
        for invalid in ["", "true", " 1", "01", "3", "-1"] {
            guard case .refuse = Policy.plan(previous: invalid, written: "1", current: 1) else {
                preconditionFailure("Malformed baseline accepted")
            }
            guard case .refuse = Policy.plan(previous: "0", written: invalid, current: 1) else {
                preconditionFailure("Malformed ownership accepted")
            }
        }
        for unreadable in [nil, -1, 3] as [Int?] {
            guard case .refuse = Policy.plan(previous: "0", written: "1", current: unreadable) else {
                preconditionFailure("Unreadable current state accepted")
            }
        }
        print("Power setting restoration tests passed (ownership, idempotence, exact integers; no pmset execution)")
    }
}
