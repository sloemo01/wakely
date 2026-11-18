import SwiftUI
import AppKit

/// A native port of the torph text-morph model — MIT, (c) 2025 Lochie Axon,
/// https://github.com/lochie/torph.
///
/// Torph keeps the characters that survive an edit mounted, measures where they
/// were and where they land, then FLIPs each one into place. Arriving characters
/// grow from 0.95 and fade in; leaving ones travel toward the nearest survivor
/// while shrinking and fading out. Nothing is animated as a whole block, which is
/// what makes the text read as continuous rather than cross-faded.
struct TorphSegment: Equatable {
    let id: String
    let text: String
}

enum TorphDiff {
    private struct Word {
        let text: String
        let segments: [TorphSegment]
        let gap: Int
    }

    /// Characters grouped into whitespace-delimited words, each remembering how
    /// many separators preceded it so a pairing can never cross a surviving word.
    private static func words(_ segments: [TorphSegment]) -> [Word] {
        var result: [Word] = []
        var current: [TorphSegment] = []
        var gap = 0
        func flush() {
            guard !current.isEmpty else { return }
            result.append(Word(text: current.map(\.text).joined(), segments: current, gap: gap))
            current = []
        }
        for segment in segments {
            if segment.text == " " || segment.text == "\n" {
                flush()
                gap += 1
            } else {
                current.append(segment)
            }
        }
        flush()
        return result
    }

    private struct Token {
        let text: String
        let gap: Int
        let offset: Int
        let isSeparator: Bool
    }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var gap = 0
        var offset = 0
        var current = ""
        var currentStart = 0
        func flush() {
            guard !current.isEmpty else { return }
            result.append(Token(text: current, gap: gap, offset: currentStart, isSeparator: false))
            current = ""
        }
        for character in text {
            if character == " " || character == "\n" {
                flush()
                result.append(Token(text: String(character), gap: gap, offset: offset, isSeparator: true))
                gap += 1
            } else {
                if current.isEmpty { currentStart = offset }
                current.append(character)
            }
            offset += 1
        }
        flush()
        return result
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { pairs.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return pairs
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let matches = longestCommonSubsequence(a.map(String.init), b.map(String.init)).count
        return Double(matches) / Double(max(a.count, b.count))
    }

    /// Fresh segmentation: one segment per character, spaces and newlines kept.
    static func segments(for text: String) -> [TorphSegment] {
        tokens(text).flatMap { token -> [TorphSegment] in
            if token.isSeparator {
                return [TorphSegment(id: "sep-\(token.gap)", text: token.text)]
            }
            return token.text.enumerated().map { index, character in
                TorphSegment(id: "c-\(token.offset + index)", text: String(character))
            }
        }
    }

    /// New segments that reuse old ids wherever the same character survives.
    ///
    /// Fresh ids carry `generation`, so a character introduced by one edit can
    /// never collide with a different character introduced by an earlier edit —
    /// which matters when a transition is interrupted and the old ghosts and the
    /// new arrivals are on screen at the same time.
    static func segments(from old: [TorphSegment], to text: String,
                         generation: Int = 0) -> [TorphSegment] {
        func fresh(_ offset: Int, _ character: String) -> TorphSegment {
            TorphSegment(id: "g\(generation)-\(offset)", text: character)
        }
        guard !old.isEmpty else { return segments(for: text) }
        let oldWords = words(old)
        let newTokens = tokens(text)
        let newWords = newTokens.filter { !$0.isSeparator }
        guard !newWords.isEmpty else {
            return newTokens.map { TorphSegment(id: "sep-\($0.gap)", text: $0.text) }
        }

        // 1. Surviving words keep their characters untouched.
        var oldToNew = [Int: Int]()
        for (oldIndex, newIndex) in longestCommonSubsequence(oldWords.map(\.text), newWords.map(\.text)) {
            oldToNew[oldIndex] = newIndex
        }
        // 2. Remaining words in the same gap may morph into one another.
        var usedOld = Set(oldToNew.keys)
        var morphed = [Int: Int]()
        for (newIndex, newWord) in newWords.enumerated() where oldToNew.values.contains(newIndex) == false {
            var best: (index: Int, score: Double)?
            for (oldIndex, oldWord) in oldWords.enumerated()
            where !usedOld.contains(oldIndex) && oldWord.gap == newWord.gap {
                let score = similarity(oldWord.text, newWord.text)
                // torph uses 0.4 for long web copy. Short UI labels such as
                // "Components" → "General" share only two letters, so the bar is
                // lower here or nothing would ever fly between them.
                if score >= (best?.score ?? 0.15) { best = (oldIndex, score) }
            }
            if let best {
                usedOld.insert(best.index)
                morphed[newIndex] = best.index
            }
        }

        var newIndexToOldIndex = [Int: Int]()
        for (oldIndex, newIndex) in oldToNew { newIndexToOldIndex[newIndex] = oldIndex }
        for (newIndex, oldIndex) in morphed { newIndexToOldIndex[newIndex] = oldIndex }

        var result: [TorphSegment] = []
        var wordIndex = 0
        for token in newTokens {
            if token.isSeparator {
                result.append(TorphSegment(id: "sep-\(token.gap)", text: token.text))
                continue
            }
            let index = wordIndex
            wordIndex += 1
            guard let oldIndex = newIndexToOldIndex[index] else {
                result.append(contentsOf: token.text.enumerated().map { offset, character in
                    fresh(token.offset + offset, String(character))
                })
                continue
            }
            let oldWord = oldWords[oldIndex]
            if oldToNew[oldIndex] == index {
                result.append(contentsOf: oldWord.segments)
                continue
            }
            // 3. Inside a morphing pair, surviving characters carry their id across.
            let newCharacters = token.text.map(String.init)
            var carried = [Int: TorphSegment]()
            for (oldChar, newChar) in longestCommonSubsequence(oldWord.segments.map(\.text), newCharacters)
            where oldChar < oldWord.segments.count {
                carried[newChar] = oldWord.segments[oldChar]
            }
            for (offset, character) in newCharacters.enumerated() {
                if let existing = carried[offset] {
                    result.append(TorphSegment(id: existing.id, text: character))
                } else {
                    result.append(fresh(token.offset + offset, character))
                }
            }
        }
        return result
    }
}

/// Where each segment sits in the laid-out line, in view coordinates.
enum TorphLayout {
    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    static func origins(for segments: [TorphSegment], font: NSFont) -> [String: CGPoint] {
        var result: [String: CGPoint] = [:]
        var x: CGFloat = 0
        var y: CGFloat = 0
        let height = lineHeight(font)
        // Only the current line is measured; carrying the previous lines in the
        // prefix would offset every character after a newline.
        var line = ""
        for segment in segments {
            if segment.text == "\n" {
                result[segment.id] = CGPoint(x: x, y: y)
                line = ""
                x = 0
                y += height
                continue
            }
            result[segment.id] = CGPoint(x: x, y: y)
            line += segment.text
            x = (line as NSString).size(withAttributes: [.font: font]).width
        }
        return result
    }

    static func width(of segments: [TorphSegment], font: NSFont) -> CGFloat {
        let lines = segments.map(\.text).joined().components(separatedBy: "\n")
        return lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    }
}

/// One glyph travelling from where it was to where it belongs.
struct TorphGlyphFrame: Equatable {
    let id: String
    let text: String
    let point: CGPoint
    let scale: CGFloat
    let opacity: CGFloat
}

private struct TorphFlight {
    let id: String
    let text: String
    let from: CGPoint
    let to: CGPoint
    let scaleFrom: CGFloat
    let scaleTo: CGFloat
    let opacityFrom: CGFloat
    let opacityTo: CGFloat
    let fadeStart: Double
    let fadeEnd: Double
}

/// Pure state machine for the morph. Kept out of the view so the whole
/// transition — including interruption at an arbitrary time — can be tested
/// without a window.
struct TorphAnimator {
    let font: NSFont
    let duration: Double
    private(set) var settled: [TorphSegment]
    private(set) var origins: [String: CGPoint]
    private(set) var width: CGFloat
    private(set) var generation = 0
    private(set) var animating = false
    private var flights: [TorphFlight] = []
    private var startedAt = Date.distantPast

    init(text: String, font: NSFont, duration: Double = 0.4) {
        self.font = font
        self.duration = duration
        settled = TorphDiff.segments(for: text)
        origins = TorphLayout.origins(for: settled, font: font)
        width = max(TorphLayout.width(of: settled, font: font), 1)
    }

    static func canMorph(_ text: String) -> Bool {
        // Per-character drawing reproduces a line's advance exactly for plain
        // text. Scripts that join or reorder need whole-run shaping, so they fall
        // back to a static draw rather than a wrong one.
        text.unicodeScalars.allSatisfy { scalar in
            scalar == "\n" || (scalar.value >= 32 && scalar.value < 127)
        }
    }

    private func easing() -> UnitCurve {
        UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.19, y: 1),
                         endControlPoint: UnitPoint(x: 0.22, y: 1))
    }

    /// What is on screen right now, per glyph.
    func frame(at date: Date) -> [TorphGlyphFrame] {
        guard animating, !flights.isEmpty else {
            return settled.compactMap { segment in
                origins[segment.id].map {
                    TorphGlyphFrame(id: segment.id, text: segment.text, point: $0,
                                    scale: 1, opacity: 1)
                }
            }
        }
        let raw = min(1, max(0, date.timeIntervalSince(startedAt) / duration))
        let eased = CGFloat(easing().value(at: raw))
        return flights.compactMap { flight in
            let fade = flight.fadeEnd > flight.fadeStart
                ? min(1, max(0, (raw - flight.fadeStart) / (flight.fadeEnd - flight.fadeStart)))
                : 1
            let opacity = flight.opacityFrom + (flight.opacityTo - flight.opacityFrom) * CGFloat(fade)
            guard opacity > 0.002 else { return nil }
            return TorphGlyphFrame(
                id: flight.id, text: flight.text,
                point: CGPoint(x: flight.from.x + (flight.to.x - flight.from.x) * eased,
                               y: flight.from.y + (flight.to.y - flight.from.y) * eased),
                scale: flight.scaleFrom + (flight.scaleTo - flight.scaleFrom) * eased,
                opacity: opacity)
        }
    }

    mutating func update(to value: String, at now: Date, reduceMotion: Bool = false) {
        let previous = settled
        let samples = Dictionary(uniqueKeysWithValues: frame(at: now).map { ($0.id, $0) })
        let nextGeneration = generation + 1
        let next = TorphDiff.segments(from: previous, to: value, generation: nextGeneration)
        let nextOrigins = TorphLayout.origins(for: next, font: font)
        let previousWidth = TorphLayout.width(of: previous, font: font)
        let nextWidth = TorphLayout.width(of: next, font: font)

        func settle() {
            settled = next
            origins = nextOrigins
            flights = []
            animating = false
            generation = nextGeneration
            width = max(nextWidth, 1)
        }

        guard !reduceMotion, Self.canMorph(value),
              Self.canMorph(previous.map(\.text).joined()) else {
            settle()
            return
        }

        let nextIDs = Set(next.map(\.id))
        let survivors = nextIDs.intersection(Set(previous.map(\.id)))
        var nextFlights: [TorphFlight] = []

        for segment in next {
            guard let target = nextOrigins[segment.id] else { continue }
            if let carried = samples[segment.id] {
                // Still on screen from the previous change: keep going from where
                // it actually is, with the opacity and scale it actually has.
                nextFlights.append(TorphFlight(
                    id: segment.id, text: segment.text,
                    from: carried.point, to: target,
                    scaleFrom: carried.scale, scaleTo: 1,
                    opacityFrom: carried.opacity, opacityTo: 1,
                    fadeStart: 0, fadeEnd: 1))
            } else {
                var start = target
                if let reference = Self.nearestSurvivor(for: segment.id, in: next, survivors: survivors),
                   let carried = samples[reference], let referenceTarget = nextOrigins[reference] {
                    start = CGPoint(x: target.x + carried.point.x - referenceTarget.x,
                                    y: target.y + carried.point.y - referenceTarget.y)
                }
                nextFlights.append(TorphFlight(
                    id: segment.id, text: segment.text,
                    from: start, to: target,
                    scaleFrom: 0.95, scaleTo: 1,
                    opacityFrom: 0, opacityTo: 1,
                    fadeStart: 0.25, fadeEnd: 0.75))
            }
        }

        for segment in previous where !nextIDs.contains(segment.id) {
            let from = samples[segment.id]?.point ?? origins[segment.id] ?? .zero
            let scale = samples[segment.id]?.scale ?? 1
            let opacity = samples[segment.id]?.opacity ?? 1
            var travel = CGPoint.zero
            if let reference = Self.nearestSurvivor(for: segment.id, in: previous, survivors: survivors),
               let carried = samples[reference], let referenceTarget = nextOrigins[reference] {
                travel = CGPoint(x: carried.point.x - referenceTarget.x,
                                 y: carried.point.y - referenceTarget.y)
            }
            nextFlights.append(TorphFlight(
                id: segment.id, text: segment.text,
                from: from, to: CGPoint(x: from.x + travel.x, y: from.y + travel.y),
                scaleFrom: scale, scaleTo: scale * 0.95,
                opacityFrom: opacity, opacityTo: 0,
                fadeStart: 0, fadeEnd: 0.25))
        }

        flights = nextFlights
        settled = next
        origins = nextOrigins
        width = max(previousWidth, nextWidth, 1)
        generation = nextGeneration
        startedAt = now
        animating = true
    }

    /// Stops the timeline once the current transition has run out.
    mutating func finishIfNeeded(at now: Date) {
        guard animating, now.timeIntervalSince(startedAt) >= duration else { return }
        settle()
    }

    mutating func settle() {
        animating = false
        flights = []
        width = max(TorphLayout.width(of: settled, font: font), 1)
    }

    private static func nearestSurvivor(for id: String, in list: [TorphSegment],
                                        survivors: Set<String>) -> String? {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return nil }
        for distance in 1...max(1, list.count) {
            let before = index - distance
            if before >= 0, survivors.contains(list[before].id) { return list[before].id }
            let after = index + distance
            if after < list.count, survivors.contains(list[after].id) { return list[after].id }
        }
        return nil
    }
}

/// A label that morphs between values instead of cross-fading.
struct TorphText: View {
    private let text: String
    private let font: NSFont
    private let duration: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animator: TorphAnimator
    @State private var shownText: String
    @State private var completionTask: Task<Void, Never>?

    init(_ text: String, font: NSFont, duration: Double = 0.4) {
        self.text = text
        self.font = font
        self.duration = duration
        _animator = State(initialValue: TorphAnimator(text: text, font: font, duration: duration))
        _shownText = State(initialValue: text)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120, paused: !animator.animating)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
                for glyph in animator.frame(at: timeline.date) {
                    draw(glyph, in: context)
                }
            }
        }
        .frame(width: animator.width, height: TorphLayout.lineHeight(font), alignment: .topLeading)
        .accessibilityElement()
        .accessibilityLabel(shownText)
        .onChange(of: text) { _, value in
            completionTask?.cancel()
            animator.update(to: value, at: Date(), reduceMotion: reduceMotion)
            shownText = value
            if animator.animating {
                let generation = animator.generation
                let seconds = max(0, animator.duration)
                completionTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
                    catch { return }
                    guard !Task.isCancelled, animator.generation == generation else { return }
                    animator.settle()
                }
            }
        }
        .onChange(of: reduceMotion) { _, reduced in
            if reduced { completionTask?.cancel(); animator.settle() }
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
            animator.settle()
        }
    }

    private func draw(_ glyph: TorphGlyphFrame, in context: GraphicsContext) {
        context.drawLayer { layer in
            layer.translateBy(x: glyph.point.x, y: glyph.point.y)
            layer.scaleBy(x: glyph.scale, y: glyph.scale)
            layer.opacity = glyph.opacity
            layer.draw(Text(glyph.text).font(.custom(font.fontName, size: font.pointSize)),
                       at: .zero, anchor: .topLeading)
        }
    }
}
