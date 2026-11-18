import Foundation
import IOKit
import IOKit.hid

let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
guard service != 0 else { fatalError("IOHIDSystem unavailable") }
defer { IOObjectRelease(service) }
var connection: io_connect_t = 0
let opened = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
guard opened == kIOReturnSuccess else { fatalError("open: \(opened)") }
defer { IOServiceClose(connection) }
var initial = false
let read = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &initial)
guard read == kIOReturnSuccess else { fatalError("read: \(read)") }
print("initial=\(initial)")
let targets: [Bool] = CommandLine.arguments.contains("--on") ? [true] : CommandLine.arguments.contains("--read") ? [] : [true, false]
for target in targets {
    let result = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), target)
    var actual = !target
    let verification = IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &actual)
    print("requested=\(target) set=\(result) read=\(verification) actual=\(actual)")
    guard result == kIOReturnSuccess, verification == kIOReturnSuccess, actual == target else {
        _ = IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), initial)
        fatalError("verification failed")
    }
}
