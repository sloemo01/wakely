// App-free tests. The runner extracts the injectable controller, not PowerEngine
// or DisplayServices; every hardware function below is a memory-only closure.
import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

// Normal capture / restore; no hard-coded fallback brightness.
do {
    var level: Float = 0.37
    var writes: [Float] = []
    let controller = SerializedBrightnessController(display: { 1 }, read: { _ in level },
        write: { _, value in level = value; writes.append(value); return true }, log: { _ in })
    expect(controller.isRestored, "new controller has no restoration obligation")
    controller.setDimmed(true); controller.waitUntilIdle()
    expect(!controller.isRestored, "dimmed display is not restored")
    controller.setDimmed(false); controller.waitUntilIdle()
    expect(controller.isRestored, "restoration completion is observable without blocking")
    expect(writes == [0, 0.37], "must restore exact captured brightness")
    expect(level == 0.37, "normal restore")
}

// Close then reopen while capture is blocked: obsolete dim must never execute.
do {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var writes: [Float] = []
    let controller = SerializedBrightnessController(display: { 1 }, read: { _ in
        entered.signal(); release.wait(); return 0.61
    }, write: { _, value in writes.append(value); return true }, log: { _ in })
    controller.setDimmed(true)
    expect(entered.wait(timeout: .now() + 2) == .success, "capture must start")
    controller.setDimmed(false)
    release.signal(); controller.waitUntilIdle()
    expect(writes.isEmpty, "cancelled capture must not darken after reopen")
}

// A hardware write already in flight cannot be cancelled, but restore must run
// behind it and finish last, never on an independent concurrent queue.
do {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var writes: [Float] = []
    let controller = SerializedBrightnessController(display: { 1 }, read: { _ in 0.82 },
        write: { _, value in
            if value == 0 { entered.signal(); release.wait() }
            writes.append(value); return true
        }, log: { _ in })
    controller.setDimmed(true)
    expect(entered.wait(timeout: .now() + 2) == .success, "dim must start")
    controller.setDimmed(false)
    expect(!controller.isRestored, "queued restore cannot report completion while dim is blocked")
    release.signal(); controller.waitUntilIdle()
    expect(controller.isRestored, "queue finished with the original brightness restored")
    expect(writes == [0, 0.82], "in-flight dim must be followed by restore")
}

// A failed capture must not change the display if restoration is impossible.
do {
    var writes = 0
    let controller = SerializedBrightnessController(display: { 1 }, read: { _ in nil },
        write: { _, _ in writes += 1; return true }, log: { _ in })
    controller.setDimmed(true); controller.waitUntilIdle()
    controller.setDimmed(false); controller.waitUntilIdle()
    expect(writes == 0, "do not dim without an original brightness")
}

// Failed restoration retains its baseline for a later retry.
do {
    var failRestore = true
    var writes: [Float] = []
    let controller = SerializedBrightnessController(display: { 1 }, read: { _ in 0.45 },
        write: { _, value in
            writes.append(value)
            if value != 0 && failRestore { failRestore = false; return false }
            return true
        }, log: { _ in })
    controller.setDimmed(true); controller.waitUntilIdle()
    controller.setDimmed(false); controller.waitUntilIdle()
    expect(!controller.isRestored, "failed restore must remain pending")
    controller.setDimmed(false); controller.waitUntilIdle()
    expect(controller.isRestored, "successful retry clears restore obligation")
    expect(writes == [0, 0.45, 0.45], "retry original value after restoration failure")
}
print("PASS: 5 shared-engine brightness tests (in-memory backends only)")
