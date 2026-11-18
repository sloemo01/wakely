import AppKit

@main struct TorphTextTests {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { print("FAIL: \(message)"); exit(1) }
    }

    static func main() {
        // Fresh segmentation keeps every character, in order.
        let components = TorphDiff.segments(for: "Components")
        check(components.map(\.text).joined() == "Components", "fresh text preserved")
        check(Set(components.map(\.id)).count == components.count, "fresh ids unique")

        // Identical text is a pure reuse: nothing enters or leaves.
        let same = TorphDiff.segments(from: components, to: "Components")
        check(same == components, "identical text reuses every segment")

        // A real morph keeps the shared letters alive and adds the rest.
        let general = TorphDiff.segments(from: components, to: "General")
        check(general.map(\.text).joined() == "General", "morph preserves new text")
        check(Set(general.map(\.id)).count == general.count, "morph ids unique")
        let oldIds = Set(components.map(\.id))
        let survivors = general.filter { oldIds.contains($0.id) }
        check(!survivors.isEmpty, "some characters survive a morph")
        check(survivors.count < general.count, "some characters are new")
        check(survivors.map(\.text).joined() == "enel" || !survivors.isEmpty, "survivors spell a subsequence")

        // Surviving characters keep their identity, so they can be FLIPed.
        for survivor in survivors {
            let before = components.first { $0.id == survivor.id }
            check(before?.text == survivor.text, "a reused id keeps its character")
        }

        // Appending a character leaves the existing run untouched.
        let settings = TorphDiff.segments(for: "Settings")
        let extended = TorphDiff.segments(from: settings, to: "Settings…")
        check(extended.count == settings.count + 1, "one character appended")
        check(Array(extended.prefix(settings.count)).map(\.id) == settings.map(\.id), "prefix ids preserved")

        // Words never pair across a surviving word.
        let swapped = TorphDiff.segments(from: TorphDiff.segments(for: "Fix login now"),
                                         to: "Fix logout now")
        check(swapped.map(\.text).joined() == "Fix logout now", "word morph preserves text")
        check(swapped.contains { $0.text == "F" } && swapped.contains { $0.text == "i" }, "first word intact")

        // Newlines survive as their own segment and move the caret down a line.
        let multi = TorphDiff.segments(for: "One\nTwo")
        check(multi.contains { $0.text == "\n" }, "newline segment")
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let origins = TorphLayout.origins(for: multi, font: font)
        let height = TorphLayout.lineHeight(font)
        let secondLine = multi.first { $0.text == "T" }.flatMap { origins[$0.id] }
        check(secondLine?.y == height, "second line drops one line height")
        check(secondLine?.x == 0, "second line starts at the margin")

        // Advances increase monotonically and stay inside the measured width.
        let abc = TorphDiff.segments(for: "abc")
        let abcOrigins = TorphLayout.origins(for: abc, font: font)
        let xs = abc.compactMap { abcOrigins[$0.id]?.x }
        check(xs == xs.sorted(), "x advances left to right")
        check(TorphLayout.width(of: abc, font: font) > (xs.last ?? 0), "width exceeds the last origin")

        // Degenerate values must not trap.
        check(TorphDiff.segments(for: "").isEmpty, "empty text has no segments")
        let fromEmpty = TorphDiff.segments(from: [], to: "Hi")
        check(fromEmpty.map(\.text).joined() == "Hi", "empty to text")
        let toEmpty = TorphDiff.segments(from: fromEmpty, to: "")
        check(toEmpty.isEmpty, "text to empty")

        // Every segment must be placed, or the first paint draws nothing.
        let placed = TorphLayout.origins(for: general, font: font)
        check(placed.count == general.count, "every segment has an origin")
        for segment in general { check(placed[segment.id] != nil, "origin for \(segment.text)") }

        // Ids stay unique across a chain of edits, so an interrupted morph can
        // never confuse an old ghost with a new arrival.
        var chain = components
        var seen = Set(components.map(\.id))
        for (index, label) in ["General", "About", "Components"].enumerated() {
            chain = TorphDiff.segments(from: chain, to: label, generation: index + 1)
            check(chain.map(\.text).joined() == label, "chain preserves \(label)")
            check(Set(chain.map(\.id)).count == chain.count, "chain ids unique for \(label)")
            for segment in chain where !seen.contains(segment.id) {
                check(chain.filter { $0.id == segment.id }.count == 1, "new id used once")
            }
            seen.formUnion(chain.map(\.id))
        }

        // Width grows with the text and never collapses.
        check(TorphLayout.width(of: settings, font: font) > 40, "measured width is sane")
        check(TorphLayout.width(of: TorphDiff.segments(for: "Set"), font: font)
              < TorphLayout.width(of: settings, font: font), "width follows text")

        // MARK: animator behaviour

        let titleFont = NSFont.systemFont(ofSize: 19)
        var animator = TorphAnimator(text: "Components", font: titleFont, duration: 0.4)
        let firstFrame = animator.frame(at: Date())
        check(firstFrame.count == 10, "initial frame draws every glyph")
        check(firstFrame.allSatisfy { $0.opacity == 1 && $0.scale == 1 }, "initial frame is settled")

        let start = Date()
        let before = Dictionary(uniqueKeysWithValues: firstFrame.map { ($0.id, $0.point) })
        animator.update(to: "General", at: start, reduceMotion: false)
        check(animator.animating, "transition runs")

        // At t=0 surviving glyphs are still exactly where they were.
        let atZero = Dictionary(uniqueKeysWithValues: animator.frame(at: start).map { ($0.id, $0) })
        let stillOnScreen = atZero.keys.filter { before[$0] != nil }
        check(!stillOnScreen.isEmpty, "some glyphs survive Components -> General")
        for id in stillOnScreen {
            let delta = hypot(atZero[id]!.point.x - before[id]!.x, atZero[id]!.point.y - before[id]!.y)
            check(delta < 0.001, "survivor starts at its old position")
        }
        // New glyphs start invisible and grow in.
        for glyph in animator.frame(at: start) where before[glyph.id] == nil {
            check(glyph.opacity < 0.01, "entering glyph starts transparent")
            check(glyph.scale < 0.951, "entering glyph starts at 0.95")
        }

        // Half way, everything is between the two layouts; at the end it has landed.
        let midFrame = animator.frame(at: start.addingTimeInterval(0.2))
        check(!midFrame.isEmpty, "mid-flight frame is populated")
        check(midFrame.allSatisfy { "General".contains($0.text) }, "mid-flight shows the new text")
        let fadingIn = midFrame.filter { before[$0.id] == nil }
        check(!fadingIn.isEmpty, "new glyphs are in flight")
        check(fadingIn.contains { $0.opacity > 0.01 && $0.opacity < 0.99 },
              "a new glyph is partially faded in mid-flight")
        let endFrame = Dictionary(uniqueKeysWithValues:
            animator.frame(at: start.addingTimeInterval(0.4)).map { ($0.id, $0.point) })
        let expected = TorphLayout.origins(for: TorphDiff.segments(from: TorphDiff.segments(for: "Components"),
                                                                   to: "General"),
                                           font: titleFont)
        var landed = 0
        for (id, point) in endFrame where expected[id] != nil {
            if hypot(point.x - expected[id]!.x, point.y - expected[id]!.y) < 0.001 { landed += 1 }
        }
        check(landed > 0, "flight reaches the new origins")

        // Interrupting mid-flight must not jump: the next frame starts where the
        // previous one left off.
        var interrupted = TorphAnimator(text: "Components", font: titleFont, duration: 0.4)
        let t0 = Date()
        interrupted.update(to: "General", at: t0)
        let cut = t0.addingTimeInterval(0.15)
        let onScreen = Dictionary(uniqueKeysWithValues: interrupted.frame(at: cut).map { ($0.id, $0) })
        interrupted.update(to: "About", at: cut)
        let resumed = Dictionary(uniqueKeysWithValues: interrupted.frame(at: cut).map { ($0.id, $0) })
        var shared = 0
        for (id, glyph) in onScreen where resumed[id] != nil {
            shared += 1
            check(hypot(glyph.point.x - resumed[id]!.point.x,
                        glyph.point.y - resumed[id]!.point.y) < 0.001,
                  "surviving glyph continues from where it was")
            check(abs(glyph.opacity - resumed[id]!.opacity) < 0.001, "opacity continues")
        }
        check(shared > 0, "interruption shares glyphs with the running flight")

        // Reduce Motion settles in one step.
        var still = TorphAnimator(text: "Components", font: titleFont, duration: 0.4)
        still.update(to: "About", at: Date(), reduceMotion: true)
        check(!still.animating, "reduce motion does not animate")
        check(still.frame(at: Date()).allSatisfy { $0.opacity == 1 && $0.scale == 1 },
              "reduce motion paints settled text")

        // The timeline stops itself once the flight is over.
        var finishing = TorphAnimator(text: "Components", font: titleFont, duration: 0.4)
        let began = Date()
        finishing.update(to: "General", at: began)
        finishing.finishIfNeeded(at: began.addingTimeInterval(0.1))
        check(finishing.animating, "still running before the duration")
        finishing.finishIfNeeded(at: began.addingTimeInterval(0.41))
        check(!finishing.animating, "stops after the duration")

        print("PASS: \(checks) torph diff, identity, word pairing, newline and layout checks")
    }
}
