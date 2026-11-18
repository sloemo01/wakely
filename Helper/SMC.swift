// SMC — fan control through IOKit's AppleSMC service.
//
// This is the only place in the helper that talks to the SMC. It is written to
// fail closed:
//
//  * Support is probed with reads only. A write is never attempted unless the
//    probe proved that FNum and every fan's F0Md/F0Tg are readable.
//  * Every reply is bounds-checked before a byte is copied or interpreted. A
//    short or malformed reply throws; it never traps or reads past the struct.
//  * The AppleSMC connection is closed on every path, including errors.
//  * setPercent verifies F0Md and F0Tg after writing. If anything fails, it
//    makes one best-effort attempt to restore automatic mode before throwing.
//  * A backup is an exact per-fan snapshot. Restoration validates every fan,
//    re-reads the live state and preflights every key before the first write;
//    anything incomplete, changed elsewhere or legacy-manual is refused.
//
// Values follow the standard AppleSMC struct protocol: scalar struct fields are
// host-endian, while `flt` payload bytes are big-endian IEEE 754 (see FanPolicy
// below).

import Darwin
import Foundation
import IOKit

// MARK: - AppleSMC ABI

/// Apple Silicon's 80-byte SMC parameter block.
///
/// The classic C `SMCKeyData_t` puts `result`, `data8`, `dataSize` and `bytes`
/// at different offsets. Apple Silicon's selector-2 interface uses this layout
/// instead (confirmed against the reference implementation):
///
///   0x00 key (UInt32, little-endian)
///   0x1c dataSize (UInt32)
///   0x20 dataType (UInt32)
///   0x30 payload (32 bytes)
///   0x28 result (UInt8)
///   0x2a command (UInt8: 5 read, 6 write, 9 key info)
///
/// A raw buffer is deliberate: Swift struct layout must not be assumed here.
private struct SMCBuffer {
    static let size = 80
    var bytes = [UInt8](repeating: 0, count: SMCBuffer.size)

    private func u32(at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private mutating func setU32(_ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    var key: UInt32 {
        get { u32(at: 0) }
        set { setU32(newValue, at: 0) }
    }
    var dataSize: UInt32 {
        get { u32(at: 0x1c) }
        set { setU32(newValue, at: 0x1c) }
    }
    var dataType: UInt32 {
        get { u32(at: 0x20) }
        set { setU32(newValue, at: 0x20) }
    }
    var result: UInt8 {
        get { bytes[0x28] }
        set { bytes[0x28] = newValue }
    }
    var command: UInt8 {
        get { bytes[0x2a] }
        set { bytes[0x2a] = newValue }
    }
    var payload: [UInt8] {
        get { Array(bytes[0x30..<0x30 + 32]) }
        set {
            for index in 0..<min(newValue.count, 32) {
                bytes[0x30 + index] = newValue[index]
            }
        }
    }
}

/// Selectors accepted by AppleSMC's struct method. Only read/write/read-info
/// are used for fans; `getKeyFromIndex` is part of the ABI and documented here
/// so the selector list is not guessed at call sites.
private enum SMCCommand: UInt32 {
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case readKeyInfo = 9
}

private enum SMCType {
    static let ui8: UInt32 = 0x75693820 // "ui8 "
    static let flt: UInt32 = 0x666C7420 // "flt "
}

private func kernReturnHex(_ value: Int32) -> String {
    String(format: "0x%08X", UInt32(bitPattern: value))
}

// MARK: - Connection

private final class SMCSession {
    private var connection: io_connect_t = 0

    init() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else {
            throw FanControlError.io("AppleSMC is not available on this Mac.")
        }
        defer { IOObjectRelease(service) }

        var opened: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &opened)
        guard result == KERN_SUCCESS else {
            throw FanControlError.io(
                "Could not open AppleSMC (kern_return_t \(kernReturnHex(result)))."
            )
        }
        guard opened != 0 else {
            throw FanControlError.io("AppleSMC returned an empty connection.")
        }
        connection = opened
    }

    deinit {
        close()
    }

    /// Idempotent. Public entry points close explicitly with `defer`; deinit is
    /// the backstop for an early throw or a forgotten path.
    func close() {
        guard connection != 0 else { return }
        _ = IOServiceClose(connection)
        connection = 0
    }

    /// One `IOConnectCallStructMethod`. Checks the kernel result and the reply
    /// length before the caller reads any field.
    ///
    /// AppleSMC's generic method is selector 2; the actual operation is the
    /// command byte in `data8` (5 read, 6 write, 9 key info). Calling selectors
    /// 5/6/9 directly works on some Intel drivers but returns
    /// `kIOReturnUnsupported` on Apple Silicon. This is the same dispatch
    /// reference helper uses.
    func call(_ command: SMCCommand, request: inout SMCBuffer) throws -> SMCBuffer {
        guard connection != 0 else {
            throw FanControlError.io("The AppleSMC connection is closed.")
        }
        request.command = UInt8(truncatingIfNeeded: command.rawValue)
        var output = SMCBuffer()
        var outputSize = SMCBuffer.size
        let result: kern_return_t = request.bytes.withUnsafeMutableBytes { requestBytes in
            output.bytes.withUnsafeMutableBytes { outputBytes in
                IOConnectCallStructMethod(
                    connection,
                    2,
                    requestBytes.baseAddress,
                    SMCBuffer.size,
                    outputBytes.baseAddress,
                    &outputSize
                )
            }
        }
        guard result == KERN_SUCCESS else {
            throw FanControlError.io(
                "SMC command \(command.rawValue) failed (kern_return_t \(kernReturnHex(result)))."
            )
        }
        guard outputSize >= SMCBuffer.size else {
            throw FanControlError.io(
                "SMC command \(command.rawValue) returned \(outputSize) bytes; "
                    + "expected \(SMCBuffer.size)."
            )
        }
        return output
    }
}

// MARK: - Errors

enum FanControlError: LocalizedError {
    case unsupported(String)
    case io(String)
    case verify(String)
    case noFans

    var errorDescription: String? {
        switch self {
        case .unsupported(let message):
            return message
        case .io(let message):
            return message
        case .verify(let message):
            return message
        case .noFans:
            return "This Mac reports no controllable fans."
        }
    }
}

// MARK: - Fan control

enum FanControl {
    /// Serializes all SMC access. `NSRecursiveLock` keeps a best-effort restore
    /// inside `setPercent` from deadlocking on its own call path.
    private static let operationLock = NSRecursiveLock()

    private static let fnumKey: UInt32 = 0x464E756D // "FNum"

    /// True only when FNum is readable, it reports 1...10 fans, and every fan's
    /// F0Md and F0Tg are readable as the expected modes/floats.
    static func isSupported() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        return probeSupportLocked().supported
    }

    /// When unsupported, names the exact key or value that was missing. When
    /// supported, reports the fan count. Both paths are read-only.
    static func supportReason() -> String {
        operationLock.lock()
        defer { operationLock.unlock() }
        return probeSupportLocked().reason
    }

    /// Exact, read-only per-fan snapshot. Returns nil when the fan count is
    /// outside 1...10, any fan's mode is not a known 0/1 raw value, its target
    /// is not a finite 4-byte `flt`, or its maximum is not a positive finite
    /// `flt`. A minimum that the hardware does not expose is recorded as nil,
    /// matching the existing interval fallback; the target itself is always
    /// stored as the exact SMC bytes, so a missing minimum cannot change what
    /// restoration writes.
    static func currentSnapshot() -> FanSnapshotPolicy.Snapshot? {
        operationLock.lock()
        defer { operationLock.unlock() }

        do {
            let session = try SMCSession()
            defer { session.close() }
            return try snapshotLocked(session: session)
        } catch {
            return nil
        }
    }

    /// Rejects requests outside 30...100, maps the reported interval, forces
    /// the fan, and verifies the selected mode key and F0Tg.
    ///
    /// Any failure triggers a best-effort `restoreAutomatic`-equivalent on the
    /// same connection before the original error is rethrown.
    static func setPercent(_ percent: Int) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        guard (30...100).contains(percent) else {
            throw FanControlError.io("Fan percent must be between 30 and 100.")
        }
        let probe = probeSupportLocked()
        if let count = probe.fanCount, count == 0 {
            throw FanControlError.noFans
        }
        guard probe.supported, let fanCount = probe.fanCount else {
            throw FanControlError.unsupported(probe.reason)
        }

        let session = try SMCSession()
        defer { session.close() }

        do {
            for index in 0..<fanCount {
                guard let targetKey = fanKey(index, "Tg"),
                      let maximumKey = fanKey(index, "Mx") else {
                    throw FanControlError.io("Fan \(index): could not encode its SMC keys.")
                }
                let (modeKey, modeValue) = try readMode(index, session: session)
                let minimumRPM = readMinimum(index, session: session)

                let maximumValue = try readValue(maximumKey, session: session)
                guard maximumValue.size == 4,
                      maximumValue.type == SMCType.flt,
                      let maximumRPM = FanPolicy.float(fromBigEndian: maximumValue.bytes) else {
                    throw FanControlError.io("F\(index)Mx: expected a 4-byte flt value.")
                }
                guard let targetRPM = FanPolicy.targetRPM(
                    percent: percent, minimumRPM: minimumRPM, maximumRPM: maximumRPM
                ) else {
                    throw FanControlError.io("F\(index): invalid percentage or maximum RPM.")
                }
                let targetFloat = Float(targetRPM)
                guard targetRPM > 0, targetFloat.isFinite else {
                    throw FanControlError.io(
                        "F\(index): computed a non-positive or non-finite target "
                            + "(\(targetRPM) rpm); refusing to write."
                    )
                }

                // Forced mode first, then the target. Both are verified below.
                try writeValue(modeKey, bytes: [1], type: modeValue.type, session: session)
                try writeValue(
                    targetKey,
                    bytes: FanPolicy.bigEndianBytes(from: targetRPM),
                    type: SMCType.flt,
                    session: session
                )

                let readbackMode = try readValue(modeKey, session: session)
                guard readbackMode.size == 1, readbackMode.bytes.first == 1 else {
                    throw FanControlError.verify(
                        "F\(index)Md did not read back as forced (1)."
                    )
                }

                let readbackTarget = try readValue(targetKey, session: session)
                guard readbackTarget.size == 4,
                      readbackTarget.type == SMCType.flt,
                      let readbackRPM = FanPolicy.float(fromBigEndian: readbackTarget.bytes) else {
                    throw FanControlError.verify(
                        "F\(index)Tg could not be read back as a 4-byte flt."
                    )
                }
                guard abs(readbackRPM - targetRPM) <= 2.0 else {
                    throw FanControlError.verify(
                        "F\(index)Tg read back \(readbackRPM) rpm; "
                            + "expected \(targetRPM) rpm ± 2."
                    )
                }
            }
        } catch {
            try? restoreLocked(session: session, fanCount: fanCount)
            throw error
        }
    }

    /// Writes F0Md = 0 for every fan and verifies the read-back. If one fan
    /// fails, the remaining fans are still attempted so a partial restoration
    /// is as complete as the hardware allows; the first error is then thrown.
    static func restoreAutomatic() throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        let probe = probeSupportLocked()
        if let count = probe.fanCount, count == 0 {
            throw FanControlError.noFans
        }
        guard probe.supported, let fanCount = probe.fanCount else {
            throw FanControlError.unsupported(probe.reason)
        }

        let session = try SMCSession()
        defer { session.close() }
        try restoreLocked(session: session, fanCount: fanCount)
    }

    /// Restores one exact per-fan snapshot captured by `currentSnapshot()`.
    ///
    /// Every fallible check — snapshot validation, support probe, fan-count
    /// agreement, the re-read of the live state (`verifiedCurrent`) and a
    /// preflight read of every resolved mode/target key — happens before the
    /// first write. If anything disagrees, no fan is written and the lease is
    /// left to the caller.
    ///
    /// Write order is per fan: a manual fan gets its forced mode (1) before its
    /// target; an automatic fan gets its target before its automatic mode (0).
    /// Targets are the exact captured SMC bytes. Nothing here reduces a floor
    /// or otherwise "improves" a prior setting.
    static func restore(
        _ snapshot: FanSnapshotPolicy.Snapshot,
        verifiedCurrent: FanSnapshotPolicy.Snapshot
    ) throws {
        operationLock.lock()
        defer { operationLock.unlock() }

        if let reason = FanSnapshotPolicy.validate(snapshot) {
            throw FanControlError.verify(
                "Refusing to restore an incomplete fan snapshot: \(reason) No fan was written."
            )
        }

        let probe = probeSupportLocked()
        if let count = probe.fanCount, count == 0 {
            throw FanControlError.noFans
        }
        guard probe.supported, let fanCount = probe.fanCount else {
            throw FanControlError.unsupported(probe.reason)
        }
        guard snapshot.fans.count == fanCount else {
            throw FanControlError.verify(
                "The saved fan snapshot covers \(snapshot.fans.count) fans but this Mac reports "
                    + "\(fanCount); no fan was written."
            )
        }

        let session = try SMCSession()
        defer { session.close() }

        // The caller verified ownership a moment ago. Re-read under this lock so
        // an external change between that read and the first write is caught.
        let fresh = try snapshotLocked(session: session)
        if let mismatch = FanSnapshotPolicy.ownershipMismatch(
            saved: verifiedCurrent, current: fresh
        ) {
            throw FanControlError.verify(
                "Fan state changed before it could be restored (\(mismatch)); no fan was written."
            )
        }

        struct Resolved {
            let fan: FanSnapshotPolicy.Fan
            let modeKey: UInt32
            let targetKey: UInt32
        }

        // Preflight every key before writing anything. A snapshot whose exact
        // mode suffix or data type is no longer present is refused here, not
        // halfway through the fan list.
        var resolved: [Resolved] = []
        resolved.reserveCapacity(fanCount)
        for fan in snapshot.fans {
            guard let modeKey = fanKey(fan.index, fan.modeKey),
                  let targetKey = fanKey(fan.index, "Tg") else {
                throw FanControlError.verify(
                    "F\(fan.index): the saved SMC key names cannot be encoded; no fan was written."
                )
            }

            let modeValue: SMCValue
            let targetValue: SMCValue
            do {
                modeValue = try readValue(modeKey, session: session)
                targetValue = try readValue(targetKey, session: session)
            } catch {
                throw FanControlError.verify(
                    "F\(fan.index): its saved SMC keys are no longer readable "
                        + "(\(message(for: error))); no fan was written."
                )
            }
            guard modeValue.size == 1, modeValue.type == fan.modeType else {
                throw FanControlError.verify(
                    "F\(fan.index)\(fan.modeKey): the mode key no longer matches the snapshot "
                        + "(size \(modeValue.size), type \(typeString(modeValue.type))); no fan was written."
                )
            }
            guard targetValue.size == 4, targetValue.type == fan.targetType else {
                throw FanControlError.verify(
                    "F\(fan.index)Tg: the target key no longer matches the snapshot "
                        + "(size \(targetValue.size), type \(typeString(targetValue.type))); no fan was written."
                )
            }
            resolved.append(Resolved(fan: fan, modeKey: modeKey, targetKey: targetKey))
        }

        for item in resolved {
            do {
                if item.fan.modeRaw == 1 {
                    // Manual: enter forced mode before writing its target.
                    try writeValue(item.modeKey, bytes: [1],
                                   type: item.fan.modeType, session: session)
                    try writeValue(item.targetKey, bytes: item.fan.targetBytes,
                                   type: item.fan.targetType, session: session)
                } else {
                    // Automatic: restore the exact target bytes first, then hand
                    // the fan back to automatic mode.
                    try writeValue(item.targetKey, bytes: item.fan.targetBytes,
                                   type: item.fan.targetType, session: session)
                    try writeValue(item.modeKey, bytes: [item.fan.modeRaw],
                                   type: item.fan.modeType, session: session)
                }
            } catch {
                throw FanControlError.verify(
                    "F\(item.fan.index): restore failed "
                        + "(\(message(for: error))); the lease is retained."
                )
            }
        }

        // Read every fan back, reporting the first failure after all reads.
        // Automatic targets are firmware-owned once mode 0 is written, so only
        // the mode is proof there; a manual fan must show its saved target.
        var firstError: Error?
        for item in resolved {
            do {
                let modeBack = try readValue(item.modeKey, session: session)
                guard modeBack.size == 1, modeBack.bytes.first == item.fan.modeRaw else {
                    throw FanControlError.verify(
                        "F\(item.fan.index)\(item.fan.modeKey) did not read back as "
                            + "\(item.fan.modeRaw)."
                    )
                }
                if item.fan.modeRaw == 1 {
                    let targetBack = try readValue(item.targetKey, session: session)
                    guard targetBack.size == 4,
                          targetBack.type == item.fan.targetType,
                          let rpm = FanPolicy.float(fromBigEndian: targetBack.bytes) else {
                        throw FanControlError.verify(
                            "F\(item.fan.index)Tg could not be read back as 4-byte 'flt '."
                        )
                    }
                    guard abs(rpm - item.fan.targetRPM) <= 2.0 else {
                        throw FanControlError.verify(
                            "F\(item.fan.index)Tg read back \(rpm) rpm; expected "
                                + "\(item.fan.targetRPM) rpm ± 2."
                        )
                    }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }

    // MARK: - Support probe

    private struct SupportProbe {
        let supported: Bool
        let reason: String
        let fanCount: Int?
    }

    /// Read-only. Caller holds `operationLock`.
    private static func probeSupportLocked() -> SupportProbe {
        do {
            let session = try SMCSession()
            defer { session.close() }

            let fanCount = try readFanCount(session: session)
            if fanCount == 0 {
                return SupportProbe(
                    supported: false,
                    reason: "FNum reports 0 fans; no controllable fans are present.",
                    fanCount: 0
                )
            }
            guard fanCount <= 10 else {
                return SupportProbe(
                    supported: false,
                    reason: "FNum reports \(fanCount) fans; at most 10 are supported.",
                    fanCount: fanCount
                )
            }

            var missing: [String] = []
            for index in 0..<fanCount {
                guard let targetKey = fanKey(index, "Tg") else {
                    missing.append("F\(index)Tg: could not encode the key name.")
                    continue
                }
                do {
                    _ = try readMode(index, session: session)
                } catch {
                    missing.append(message(for: error))
                }

                do {
                    let target = try readValue(targetKey, session: session)
                    if target.size != 4 {
                        missing.append("F\(index)Tg: data size \(target.size), expected 4.")
                    } else if target.type != SMCType.flt {
                        missing.append(
                            "F\(index)Tg: data type \(typeString(target.type)), expected 'flt '."
                        )
                    } else if FanPolicy.float(fromBigEndian: target.bytes) == nil {
                        missing.append("F\(index)Tg: value is not a finite float.")
                    }
                } catch {
                    missing.append(message(for: error))
                }
            }

            guard missing.isEmpty else {
                return SupportProbe(
                    supported: false,
                    reason: missing.joined(separator: "; "),
                    fanCount: fanCount
                )
            }

            let noun = fanCount == 1 ? "fan" : "fans"
            return SupportProbe(
                supported: true,
                reason: "SMC fan control is available for \(fanCount) \(noun).",
                fanCount: fanCount
            )
        } catch {
            return SupportProbe(
                supported: false,
                reason: message(for: error),
                fanCount: nil
            )
        }
    }

    // MARK: - Key helpers

    private static func fanKey(_ index: Int, _ suffix: String) -> UInt32? {
        guard index >= 0, index <= 9, suffix.count == 2 else { return nil }
        return fourCC("F\(index)\(suffix)")
    }

    private static func fourCC(_ name: String) -> UInt32? {
        let characters = Array(name.utf8)
        guard characters.count == 4 else { return nil }
        return (UInt32(characters[0]) << 24)
            | (UInt32(characters[1]) << 16)
            | (UInt32(characters[2]) << 8)
            | UInt32(characters[3])
    }

    private static func keyString(_ key: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((key >> 24) & 0xFF),
            UInt8((key >> 16) & 0xFF),
            UInt8((key >> 8) & 0xFF),
            UInt8(key & 0xFF)
        ]
        let printable = bytes.map { byte -> UInt8 in
            (byte >= 0x20 && byte < 0x7F) ? byte : 0x3F
        }
        return String(bytes: printable, encoding: .utf8) ?? "????"
    }

    private static func typeString(_ type: UInt32) -> String {
        guard type != 0 else { return "none" }
        return "'\(keyString(type))'"
    }

    // MARK: - SMC operations

    private struct SMCValue {
        let size: UInt32
        let type: UInt32
        let bytes: [UInt8]
    }

    /// Resolve uppercase first, then lowercase; writes/readback use that same key.
    private static func readMode(_ index: Int, session: SMCSession) throws -> (UInt32, SMCValue) {
        var failures: [String] = []
        for suffix in ["Md", "md"] {
            guard let key = fanKey(index, suffix) else { continue }
            guard let value = try? readValue(key, session: session) else {
                failures.append("\(keyString(key)): read failed")
                continue
            }
            if value.size == 1, value.type == SMCType.ui8,
               let raw = value.bytes.first, FanSnapshotPolicy.isAutomaticMode(raw) || raw == 1 {
                return (key, value)
            }
            failures.append("\(keyString(key)): size \(value.size), type \(typeString(value.type)), raw \(value.bytes.first.map(String.init) ?? "none")")
        }
        throw FanControlError.io("F\(index)Md/F\(index)md: no readable one-byte mode key (\(failures.joined(separator: "; "))).")
    }

    private static func readMinimum(_ index: Int, session: SMCSession) -> Double? {
        guard let key = fanKey(index, "Mn"),
              let value = try? readValue(key, session: session),
              value.size == 4, value.type == SMCType.flt else { return nil }
        return FanPolicy.float(fromBigEndian: value.bytes)
    }

    /// Reads every fan into the exact snapshot form. Any fan that cannot be
    /// represented completely throws instead of returning a partial snapshot:
    /// a lossy snapshot must never reach the backup store.
    private static func snapshotLocked(session: SMCSession) throws -> FanSnapshotPolicy.Snapshot {
        let fanCount = try readFanCount(session: session)
        guard fanCount >= 1, fanCount <= 10 else {
            throw FanControlError.unsupported(
                "FNum reports \(fanCount) fans; expected 1...10."
            )
        }

        var fans: [FanSnapshotPolicy.Fan] = []
        fans.reserveCapacity(fanCount)

        for index in 0..<fanCount {
            guard let uppercaseModeKey = fanKey(index, "Md"),
                  let targetKey = fanKey(index, "Tg"),
                  let maximumKey = fanKey(index, "Mx") else {
                throw FanControlError.io("Fan \(index): could not encode its SMC keys.")
            }

            // Same resolution the rest of this file uses: F0Md, then F0md.
            let (modeKey, modeValue) = try readMode(index, session: session)
            guard modeValue.size == 1, let modeByte = modeValue.bytes.first else {
                throw FanControlError.io(
                    "F\(index)Md/F\(index)md: expected a one-byte mode value."
                )
            }
            guard FanSnapshotPolicy.isAutomaticMode(modeByte) || modeByte == 1 else {
                throw FanControlError.io(
                    "F\(index)Md/F\(index)md: raw mode \(modeByte) is neither automatic (0/3) "
                        + "nor forced (1); it cannot be restored exactly."
                )
            }

            let targetValue = try readValue(targetKey, session: session)
            guard targetValue.size == 4,
                  targetValue.type == SMCType.flt,
                  let targetRPM = FanPolicy.float(fromBigEndian: targetValue.bytes) else {
                throw FanControlError.io("F\(index)Tg: expected a 4-byte 'flt ' target.")
            }

            let maximumValue = try readValue(maximumKey, session: session)
            guard maximumValue.size == 4,
                  maximumValue.type == SMCType.flt,
                  let maximumRPM = FanPolicy.float(fromBigEndian: maximumValue.bytes),
                  maximumRPM > 0 else {
                throw FanControlError.io("F\(index)Mx: expected a positive 4-byte 'flt ' maximum.")
            }

            fans.append(FanSnapshotPolicy.Fan(
                index: index,
                modeKey: modeKey == uppercaseModeKey ? "Md" : "md",
                modeType: modeValue.type,
                modeRaw: modeByte,
                targetType: targetValue.type,
                targetBytes: targetValue.bytes,
                targetRPM: targetRPM,
                minimumRPM: readMinimum(index, session: session),
                maximumRPM: maximumRPM
            ))
        }

        let snapshot = FanSnapshotPolicy.Snapshot(fans: fans)
        if let reason = FanSnapshotPolicy.validate(snapshot) {
            throw FanControlError.verify("Fan snapshot is incomplete: \(reason)")
        }
        return snapshot
    }

    private static func readFanCount(session: SMCSession) throws -> Int {
        let value = try readValue(fnumKey, session: session)
        guard value.size == 1, value.type == SMCType.ui8, let raw = value.bytes.first else {
            throw FanControlError.io(
                "FNum: expected one ui8 byte, got size \(value.size) type \(typeString(value.type))."
            )
        }
        return Int(raw)
    }

    private static func readKeyInfo(
        _ key: UInt32,
        session: SMCSession
    ) throws -> (size: UInt32, type: UInt32) {
        var request = SMCBuffer()
        request.key = key
        let output = try session.call(.readKeyInfo, request: &request)
        try checkResult(output, key: key)

        let size = output.dataSize
        guard size >= 1, size <= 32 else {
            throw FanControlError.io(
                "\(keyString(key)): reported data size \(size), expected 1...32."
            )
        }
        return (size, output.dataType)
    }

    private static func readValue(_ key: UInt32, session: SMCSession) throws -> SMCValue {
        let info = try readKeyInfo(key, session: session)

        var request = SMCBuffer()
        request.key = key
        request.dataSize = info.size
        request.dataType = info.type

        let output = try session.call(.readKey, request: &request)
        try checkResult(output, key: key)

        let size = Int(info.size)
        let bytes = Array(output.payload.prefix(size))
        guard bytes.count == size else {
            throw FanControlError.io(
                "\(keyString(key)): short reply (\(bytes.count) of \(size) bytes)."
            )
        }
        return SMCValue(size: info.size, type: info.type, bytes: bytes)
    }

    private static func writeValue(
        _ key: UInt32,
        bytes: [UInt8],
        type: UInt32,
        session: SMCSession
    ) throws {
        guard !bytes.isEmpty, bytes.count <= 32 else {
            throw FanControlError.io(
                "\(keyString(key)): refusing to write \(bytes.count) bytes; expected 1...32."
            )
        }
        guard type != 0 else {
            throw FanControlError.io(
                "\(keyString(key)): no data type was reported; refusing to write it."
            )
        }

        var request = SMCBuffer()
        request.key = key
        request.dataSize = UInt32(bytes.count)
        request.dataType = type
        request.payload = bytes

        let output = try session.call(.writeKey, request: &request)
        try checkResult(output, key: key)
    }

    private static func checkResult(_ output: SMCBuffer, key: UInt32) throws {
        guard output.result == 0 else {
            let detail: String
            if output.result == 132 {
                detail = "SMC result 132 (key not found)"
            } else {
                detail = "SMC result \(output.result)"
            }
            throw FanControlError.io("\(keyString(key)): \(detail).")
        }
    }

    private static func restoreLocked(session: SMCSession, fanCount: Int) throws {
        var firstError: Error?
        for index in 0..<fanCount {
            do {
                let (modeKey, current) = try readMode(index, session: session)
                let modeType = current.type

                try writeValue(modeKey, bytes: [0], type: modeType, session: session)
                let readback = try readValue(modeKey, session: session)
                guard readback.size == 1, let raw = readback.bytes.first,
                      FanSnapshotPolicy.isAutomaticMode(raw) else {
                    throw FanControlError.verify(
                        "F\(index)Md did not read back as automatic (0/3)."
                    )
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError = firstError { throw firstError }
    }

    private static func message(for error: Error) -> String {
        if let fanError = error as? FanControlError,
           let description = fanError.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}

// The functions below are deliberately pure: no IOKit, Foundation, hardware,
// or mutable state. A test target can extract this block on its own.
// BEGIN TESTABLE FAN POLICY

enum FanPolicy {
    /// Fan curve endpoints are 30% and 100%; the mapping follows.
    static func targetRPM(
        percent: Int, minimumRPM: Double?, maximumRPM: Double,
        floorRPM: Double? = nil
    ) -> Double? {
        guard (30...100).contains(percent), maximumRPM.isFinite,
              maximumRPM > 0 else { return nil }
        guard let minimumRPM, minimumRPM.isFinite, minimumRPM >= 0,
              minimumRPM < maximumRPM else { return maximumRPM }
        let interpolated = minimumRPM + (maximumRPM - minimumRPM) * (Double(percent) / 100)
        let floor = floorRPM.flatMap { $0.isFinite ? $0 : nil }
        let target = floor.map { Swift.max($0, interpolated) } ?? interpolated
        return Swift.min(maximumRPM, target.rounded(.up))
    }

    /// Interval inverse kept for interval-mapping coverage. Fan backups no
    /// longer use it: the versioned snapshot below stores exact target bytes.
    /// Refuse unrepresentable manual targets rather than silently backing up a
    /// different setting. Ceil loses up to one RPM.
    /// No production floor source is selected without direct call-site evidence.
    static func percent(rpm: Double, minimumRPM: Double?, maximumRPM: Double) -> Int? {
        guard rpm.isFinite, maximumRPM.isFinite, maximumRPM > 0 else { return nil }
        guard let minimumRPM, minimumRPM.isFinite, minimumRPM >= 0,
              minimumRPM < maximumRPM else {
            return abs(rpm - maximumRPM) <= 1 ? 100 : nil
        }
        let raw = (rpm - minimumRPM) / (maximumRPM - minimumRPM) * 100
        guard raw.isFinite else { return nil }
        let candidate = Int(Swift.min(100, Swift.max(30, raw.rounded())))
        guard let target = targetRPM(percent: candidate, minimumRPM: minimumRPM,
                                     maximumRPM: maximumRPM), abs(target - rpm) <= 1 else { return nil }
        return candidate
    }

    /// F0Md: 0 or 3 automatic (Apple Silicon uses both), 1 forced. Anything
    /// else is reported as unknown, not silently treated as a valid mode.
    static func modeName(from raw: UInt8) -> String {
        switch raw {
        case 0, 3:
            return "auto"
        case 1:
            return "manual"
        default:
            return "unknown"
        }
    }

    /// AppleSMC `flt` values are four big-endian IEEE 754 bytes.
    /// Returns nil for a short buffer or a non-finite value.
    static func float(fromBigEndian bytes: [UInt8]) -> Double? {
        guard bytes.count >= 4 else { return nil }
        let bits = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        let value = Float(bitPattern: bits)
        guard value.isFinite else { return nil }
        return Double(value)
    }

    /// The inverse of `float(fromBigEndian:)`. Always returns exactly four
    /// bytes; callers are responsible for passing a finite, validated value.
    static func bigEndianBytes(from value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return [
            UInt8((bits >> 24) & 0xFF),
            UInt8((bits >> 16) & 0xFF),
            UInt8((bits >> 8) & 0xFF),
            UInt8(bits & 0xFF)
        ]
    }
}

// END TESTABLE FAN POLICY

// The functions below are deliberately pure: no IOKit, no hardware, no mutable
// state. A test target can extract this block on its own.
// BEGIN TESTABLE FAN SNAPSHOT

/// Versioned, exact per-fan backup token.
///
/// The legacy fan backup stored one percentage for the first fan and one
/// aggregate mode. That cannot represent fans in different modes or at
/// different targets, so this policy replaces it with a snapshot of every fan:
/// the resolved mode key suffix, its one-byte type and raw mode, the exact
/// four target bytes (plus the decoded RPM), and the interval bounds.
///
/// Restoration accepts only this version. Legacy manual tokens are refused
/// without a write because one percentage cannot reconstruct per-fan targets;
/// a legacy automatic token is accepted because it could only have been written
/// when every fan was automatic, and handing every fan back to automatic cannot
/// flatten anything.
enum FanSnapshotPolicy {
    static let version = "fanSnapshot.v1"
    static let tokenPrefix = version + ":"
    /// AppleSMC `flt ` four-character code.
    static let fltType: UInt32 = 0x666C7420
    /// Stored between the pre-change save and the post-change save. It is not a
    /// snapshot on purpose: if the helper dies in that window it cannot prove
    /// what it wrote, so restoration refuses rather than guessing ownership.
    static let unrecordedWrittenToken = version + ".unrecorded"
    static let maximumFans = 10
    static let targetToleranceRPM = 2.0

    struct Fan: Codable, Equatable {
        var index: Int
        /// Resolved key suffix, "Md" or "md".
        var modeKey: String
        /// The one-byte data type reported by that key.
        var modeType: UInt32
        /// 0 automatic, 1 forced.
        var modeRaw: UInt8
        var targetType: UInt32
        /// Exact SMC payload; restoration writes these bytes unchanged.
        var targetBytes: [UInt8]
        var targetRPM: Double
        /// Optional because the existing interval mapping already treats a
        /// missing or invalid minimum as "use the maximum". The target bytes
        /// above are still exact, so this cannot reduce restore fidelity.
        var minimumRPM: Double?
        var maximumRPM: Double

        init(
            index: Int,
            modeKey: String,
            modeType: UInt32,
            modeRaw: UInt8,
            targetType: UInt32,
            targetBytes: [UInt8],
            targetRPM: Double,
            minimumRPM: Double?,
            maximumRPM: Double
        ) {
            self.index = index
            self.modeKey = modeKey
            self.modeType = modeType
            self.modeRaw = modeRaw
            self.targetType = targetType
            self.targetBytes = targetBytes
            self.targetRPM = targetRPM
            self.minimumRPM = minimumRPM
            self.maximumRPM = maximumRPM
        }
    }

    struct Snapshot: Codable, Equatable {
        var version: String
        var fans: [Fan]

        init(fans: [Fan]) {
            self.version = FanSnapshotPolicy.version
            self.fans = fans
        }
    }

    /// Decoded meaning of a stored token.
    enum Token: Equatable {
        case snapshot(Snapshot)
        case legacyAutomatic(String)
        case legacyManual(String)
        case invalid(String)
    }

    /// What the caller may do with a backup entry; `.refuse` is always decided
    /// before any SMC write.
    enum RestoreDecision: Equatable {
        case restore(Snapshot)
        case restoreAutomatic(String)
        case refuse(String)
    }

    /// Apple Silicon uses 0 or 3 for the firmware-owned automatic mode.
    static func isAutomaticMode(_ raw: UInt8) -> Bool { raw == 0 || raw == 3 }

    static func modeName(_ raw: UInt8) -> String {
        switch raw {
        case 0, 3: return "automatic"
        case 1: return "manual"
        default: return "unknown (\(raw))"
        }
    }

    /// Returns the first thing that makes the snapshot unsafe to restore, or
    /// nil when it is complete. Any non-nil reason must block a write.
    static func validate(_ snapshot: Snapshot) -> String? {
        guard snapshot.version == version else {
            return "Unsupported fan snapshot version '\(snapshot.version)'."
        }
        guard !snapshot.fans.isEmpty else {
            return "The snapshot contains no fans."
        }
        guard snapshot.fans.count <= maximumFans else {
            return "The snapshot contains \(snapshot.fans.count) fans; at most \(maximumFans) are supported."
        }

        for (position, fan) in snapshot.fans.enumerated() {
            guard fan.index == position else {
                return "Fan positions are not contiguous at \(position) (found \(fan.index))."
            }
            guard fan.modeKey == "Md" || fan.modeKey == "md" else {
                return "F\(fan.index): mode key suffix '\(fan.modeKey)' is not Md or md."
            }
            guard fan.modeType != 0 else {
                return "F\(fan.index): the mode key has no data type."
            }
            guard FanSnapshotPolicy.isAutomaticMode(fan.modeRaw) || fan.modeRaw == 1 else {
                return "F\(fan.index): raw mode \(fan.modeRaw) is neither automatic (0/3) nor forced (1)."
            }
            guard fan.targetType == fltType else {
                return "F\(fan.index): target type is not 'flt '."
            }
            guard fan.targetBytes.count == 4 else {
                return "F\(fan.index): target has \(fan.targetBytes.count) bytes; expected 4."
            }
            guard let decoded = float(fromBigEndian: fan.targetBytes), decoded.isFinite else {
                return "F\(fan.index): target bytes are not a finite float."
            }
            guard fan.targetRPM.isFinite, fan.targetRPM >= 0 else {
                return "F\(fan.index): target RPM is not a finite non-negative value."
            }
            guard Float(fan.targetRPM).bitPattern == bits(fromBigEndian: fan.targetBytes) else {
                return "F\(fan.index): stored target bytes and RPM disagree."
            }
            guard fan.maximumRPM.isFinite, fan.maximumRPM > 0 else {
                return "F\(fan.index): maximum RPM is not a finite positive value."
            }
            if let minimum = fan.minimumRPM {
                guard minimum.isFinite, minimum >= 0 else {
                    return "F\(fan.index): minimum RPM is not a finite non-negative value."
                }
            }
        }
        return nil
    }

    /// JSON with sorted keys, behind a version prefix. Returns nil instead of
    /// emitting a token that `validate` would reject.
    static func encode(_ snapshot: Snapshot) -> String? {
        guard validate(snapshot) == nil else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return tokenPrefix + json
    }

    /// Classifies a stored `previous`/`written` value without touching hardware.
    static func decode(_ token: String) -> Token {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(tokenPrefix) {
            let json = String(trimmed.dropFirst(tokenPrefix.count))
            guard json.utf8.count <= 64 * 1024 else {
                return .invalid("The fan snapshot is larger than 64 KiB.")
            }
            guard let data = json.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
                return .invalid("The fan snapshot JSON could not be decoded.")
            }
            if let reason = validate(snapshot) {
                return .invalid(reason)
            }
            return .snapshot(snapshot)
        }
        if trimmed.lowercased().hasPrefix("fansnapshot.") {
            return .invalid("Unsupported fan snapshot version in '\(trimmed)'.")
        }

        let legacy = trimmed.lowercased()
        if legacy == "auto" || legacy == "automatic" {
            return .legacyAutomatic(trimmed)
        }
        if legacy.hasPrefix("percent:") || Int(legacy) != nil {
            return .legacyManual(trimmed)
        }
        return .invalid("'\(trimmed)' is not a fan snapshot token.")
    }

    /// Full pre-write decision for one backup entry. Reads only the values it
    /// is given; the caller performs the actual restore after `.restore` or
    /// `.restoreAutomatic`.
    static func restoreDecision(
        previousToken: String,
        writtenToken: String,
        current: Snapshot
    ) -> RestoreDecision {
        if let reason = validate(current) {
            return .refuse(
                "The current fan state is incomplete (\(reason)); nothing was written and the lease is retained."
            )
        }

        switch decode(previousToken) {
        case .legacyAutomatic(let token):
            // Old `fanToken` emitted "auto" only when the aggregate mode was
            // automatic, i.e. every fan was already automatic. Writing mode 0
            // to every current fan reproduces exactly that intent and cannot
            // flatten per-fan forced settings, because there were none.
            return .restoreAutomatic(
                "Legacy fan backup '\(token)' can only mean every fan was automatic; "
                    + "handing every current fan back to automatic is exact and cannot flatten per-fan settings."
            )

        case .legacyManual(let token):
            return .refuse(
                "Legacy fan backup '\(token)' predates per-fan snapshots: restoring it would apply "
                    + "one percentage to every fan and could flatten different per-fan settings. "
                    + "Nothing was written and the lease is retained; manual fan restoration is required."
            )

        case .invalid(let reason):
            return .refuse(
                "The saved fan snapshot cannot be used: \(reason) "
                    + "Nothing was written and the lease is retained."
            )

        case .snapshot(let previous):
            if previous.fans.count != current.fans.count {
                return .refuse(
                    "The saved fan snapshot covers \(previous.fans.count) fans but this Mac now "
                        + "reports \(current.fans.count); it cannot be restored exactly. "
                        + "Nothing was written and the lease is retained."
                )
            }

            let trimmedWritten = writtenToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedWritten == unrecordedWrittenToken {
                return .refuse(
                    "The fan lease did not record the per-fan state the helper wrote, so ownership "
                        + "cannot be verified. Nothing was written and the lease is retained; "
                        + "manual fan restoration is required."
                )
            }

            switch decode(writtenToken) {
            case .snapshot(let written):
                if let mismatch = ownershipMismatch(saved: written, current: current) {
                    return .refuse(
                        "The fan state changed outside Wakely: \(mismatch). "
                            + "Nothing was written and the lease is retained."
                    )
                }
                return .restore(previous)

            case .legacyAutomatic(let token), .legacyManual(let token):
                return .refuse(
                    "The fan lease's written value '\(token)' is a legacy token, so the state the "
                        + "helper wrote cannot be verified. Nothing was written and the lease is retained; "
                        + "manual fan restoration is required."
                )

            case .invalid(let reason):
                return .refuse(
                    "The fan lease's written value cannot be verified: \(reason) "
                        + "Nothing was written and the lease is retained."
                )
            }
        }
    }

    /// Ownership is per fan: the raw mode must match, and a manual fan's target
    /// must still be the one the helper wrote. An automatic fan's target is
    /// owned by the firmware and may drift; only its mode proves ownership.
    /// Returns a precise difference, or nil when the states match.
    static func ownershipMismatch(saved: Snapshot, current: Snapshot) -> String? {
        guard saved.fans.count == current.fans.count else {
            return "the saved fan state covers \(saved.fans.count) fans but this Mac reports \(current.fans.count)"
        }
        for (expected, observed) in zip(saved.fans, current.fans) {
            guard expected.index == observed.index else {
                return "fan positions no longer match (expected F\(expected.index), found F\(observed.index))"
            }
            guard expected.modeRaw == observed.modeRaw else {
                return "F\(expected.index) is now \(modeName(observed.modeRaw)) but the helper left it "
                    + "\(modeName(expected.modeRaw))"
            }
            if expected.modeRaw == 1 {
                guard abs(expected.targetRPM - observed.targetRPM) <= targetToleranceRPM else {
                    return "F\(expected.index) is now at \(Int(observed.targetRPM.rounded())) rpm but "
                        + "the helper left it at \(Int(expected.targetRPM.rounded())) rpm"
                }
            }
        }
        return nil
    }

    static func sameOwnedState(saved: Snapshot, current: Snapshot) -> Bool {
        ownershipMismatch(saved: saved, current: current) == nil
    }

    static func isAllAutomatic(_ snapshot: Snapshot) -> Bool {
        !snapshot.fans.isEmpty && snapshot.fans.allSatisfy { FanSnapshotPolicy.isAutomaticMode($0.modeRaw) }
    }

    /// Human-facing summary for reply details; never used for restoration.
    static func summary(_ snapshot: Snapshot) -> String {
        guard !snapshot.fans.isEmpty else { return "unknown" }
        if snapshot.fans.allSatisfy({ FanSnapshotPolicy.isAutomaticMode($0.modeRaw) }) { return "auto" }
        if snapshot.fans.allSatisfy({ $0.modeRaw == 1 }) { return "manual" }
        return "mixed"
    }

    private static func bits(fromBigEndian bytes: [UInt8]) -> UInt32 {
        (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }

    private static func float(fromBigEndian bytes: [UInt8]) -> Double? {
        guard bytes.count == 4 else { return nil }
        let value = Float(bitPattern: bits(fromBigEndian: bytes))
        guard value.isFinite else { return nil }
        return Double(value)
    }
}

/// Short name used by the SMC layer and Operations.
typealias FanSnapshot = FanSnapshotPolicy.Snapshot

// END TESTABLE FAN SNAPSHOT
