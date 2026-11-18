import Foundation

/// A bounded, user-paced demo clock. No component or system state is involved.
/// Freezing records the current position, so hidden panels never accumulate time.
struct GuidePlayback: Equatable {
    static let beatDuration: TimeInterval = 1.6
    static let duration: TimeInterval = beatDuration * 3
    private(set) var elapsed: TimeInterval = 0
    private(set) var anchor: Date?
    private(set) var userPaused = false

    func position(at date: Date) -> TimeInterval {
        min(Self.duration, max(0, elapsed + (anchor.map { max(0, date.timeIntervalSince($0)) } ?? 0)))
    }
    func beat(at date: Date) -> Int { min(2, Int(position(at: date) / Self.beatDuration)) }
    func frame(at date: Date) -> Int { Int(position(at: date) * 5) }
    var isRunning: Bool { anchor != nil }
    var isFinished: Bool { elapsed >= Self.duration }

    mutating func freeze(at date: Date) {
        elapsed = position(at: date)
        anchor = nil
    }
    mutating func updateActivity(active: Bool, reduceMotion: Bool, at date: Date) {
        if !active || reduceMotion { freeze(at: date) }
        else if !userPaused && !isFinished && anchor == nil { anchor = date }
    }
    mutating func togglePause(at date: Date, canAnimate: Bool) {
        if anchor != nil {
            freeze(at: date)
            userPaused = true
        } else if canAnimate && !isFinished {
            userPaused = false
            anchor = date
        }
    }
    mutating func replay(at date: Date, canAnimate: Bool) {
        elapsed = 0
        userPaused = false
        anchor = canAnimate ? date : nil
    }
    mutating func selectBeat(_ index: Int) {
        elapsed = Double(min(2, max(0, index))) * Self.beatDuration
        anchor = nil
        userPaused = true
    }
    mutating func finish(at date: Date) {
        guard position(at: date) >= Self.duration else { return }
        elapsed = Self.duration
        anchor = nil
    }
}
