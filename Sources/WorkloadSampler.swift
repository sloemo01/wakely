// WorkloadSampler — "is this Mac actually working right now?"
//
// The fan component needs a real load signal rather than a guessed percentage:
// the original spins the fans while a closed Mac works and returns them to
// firmware control when it rests. CPU load alone would miss an agent that is
// waiting on a network call, so a working agent counts as busy too.

import Foundation
import Darwin

enum WorkloadSampler {
    /// Sustained CPU load above this fraction counts as work.
    static let busyCPUThreshold: Double = 0.20

    private static var lastTicks: (user: Double, system: Double, idle: Double, nice: Double)?

    /// Fraction of CPU time spent working since the previous sample.
    static func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)

        defer { lastTicks = (user, system, idle, nice) }
        guard let previous = lastTicks else { return nil }

        let total = (user - previous.user) + (system - previous.system)
            + (idle - previous.idle) + (nice - previous.nice)
        guard total > 0 else { return nil }
        return ((user - previous.user) + (system - previous.system) + (nice - previous.nice)) / total
    }

    /// True when the Mac is working: sustained CPU load or an agent task that is
    /// actively running. Deliberately conservative: an idle Mac must return the
    /// fans to automatic.
    @MainActor
    static func isBusy() -> Bool {
        if let load = cpuLoad(), load >= busyCPUThreshold { return true }
        let working = AgentMonitor.shared.threads.filter { $0.state == .working }.count
        return working > 0
    }
}
