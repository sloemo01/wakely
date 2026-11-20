import SwiftUI
import AppKit

/// The value control that lives inside a sentence. It has four states:
/// resting, hovered (chevrons appear), scrubbing (accent fill while the pointer
/// moves) and editing (a small numeric field). A double-click edits; a drag
/// scrubs; the chevrons step one value. The committed setting is written as the
/// gesture moves, so no delayed queue can keep changing it after release.
struct InlineValueChip: View {
    @Binding var value: Int
    let domain: InlineValueDomain
    let format: InlineValueFormat
    var accessibilityName: String = "Value"
    /// Optional presentation seam for the tour's isolated practice control.
    var requestEditing = false
    var onEditingChanged: ((Bool) -> Void)? = nil

    private var font: NSFont { WakelyType.bodyFont(12.5, .semibold) }
    private var arrowFont: NSFont { WakelyType.bodyFont(14, .bold) }

    @State private var hover = false
    @State private var revision = 0
    @State private var session: InlineValueScrubSession?
    @State private var lastTranslation: CGFloat = 0
    @State private var scrubbing = false
    @State private var editing = false
    @State private var editText = ""
    @State private var editError = false
    @GestureState private var scrubActive = false
    @State private var focusTask: Task<Void, Never>?
    @State private var errorTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var editorFocused: Bool

    private var feedback: Animation? { AppMotion.animation(.feedback, reduceMotion: reduceMotion) }

    private var clamped: Int { domain.clamp(value) }
    private var canDecrement: Bool { clamped > domain.min }
    private var canIncrement: Bool { clamped < domain.max }

    private var foreground: Color { scrubbing || editing ? Theme.accentInk : Theme.ink }
    private var background: Color {
        if scrubbing || editing { return Theme.gold }
        return Theme.chip
    }
    private var border: Color {
        if scrubbing || editing { return Theme.goldSoft }
        if editError { return Color.red.opacity(0.8) }
        return hover ? Theme.gold.opacity(0.55) : Theme.strokeHover
    }

    var body: some View {
        let box = ChipLineBox(valueFont: font, arrowFont: arrowFont)
        let _ = revision
        // The chevrons keep their space whether or not they are visible. Adding
        // and removing them on hover changed the chip's width under the pointer,
        // which reflowed the sentence and made the control flicker.
        let showsArrows = (hover || scrubbing) && !editing
        HStack(spacing: 3) {
            arrowButton("‹", enabled: canDecrement, direction: -1, box: box)
                .opacity(showsArrows ? 1 : 0)
                .allowsHitTesting(showsArrows)

            if editing {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(WakelyType.mono(12.5, .semibold))
                    .foregroundStyle(Theme.accentInk)
                    .tint(Theme.accentInk)
                    .multilineTextAlignment(.center)
                    .frame(width: labelWidth, height: box.height)
                    .focused($editorFocused)
                    .onSubmit(commitEdit)
                    .onExitCommand(perform: cancelEdit)
                    .onChange(of: editorFocused) { _, focused in
                        if !focused, editing { commitEdit() }
                    }
                    .onChange(of: editText) { _, _ in editError = false }
                    .accessibilityLabel(accessibilityName)
            } else {
                // Native text updates atomically; no outgoing glyphs or
                // intermediate width animation while the pointer is dragging.
                valueLabel(box: box)
            }

            arrowButton("›", enabled: canIncrement, direction: 1, box: box)
                .opacity(showsArrows ? 1 : 0)
                .allowsHitTesting(showsArrows)
        }
        // Only the value/arrow content is transaction-free. The bezel below
        // sits outside this boundary and keeps its own feedback springs.
        .transaction { $0.animation = nil }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(background)
                .animation(feedback, value: scrubbing)
                .animation(feedback, value: editing)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
                .animation(feedback, value: hover)
                .animation(feedback, value: scrubbing)
                .animation(feedback, value: editing)
                .animation(feedback, value: editError)
        )
        .alignmentGuide(.firstTextBaseline) { _ in 2 + box.valueBaseline }
        .contentShape(Rectangle())
        .onHover { inside in
            hover = inside
        }
        .onAppear { if requestEditing { beginEdit() } }
        .onChange(of: requestEditing) { _, requested in
            if requested { beginEdit() }
        }
        .onChange(of: editing) { _, value in onEditingChanged?(value) }
        .onChange(of: scrubActive) { _, active in
            if !active { resetScrub() }
        }
        .onDisappear {
            resetScrub()
            focusTask?.cancel()
            errorTask?.cancel()
            editing = false
            editorFocused = false
            hover = false
            editError = false
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(format.label(clamped))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    /// The number is the drag target. Keeping the gesture off the chevron
    /// buttons means a press on ‹ or › still steps exactly once; attaching it
    /// to the whole chip let the parent gesture compete with those buttons.
    private func valueLabel(box: ChipLineBox) -> some View {
        Text(format.label(clamped))
            .font(Font(font))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(foreground)
            .frame(width: labelWidth, height: box.height)
            .contentShape(Rectangle())
            .highPriorityGesture(scrubGesture)
            .onTapGesture(count: 2) { beginEdit() }
    }

    private func arrowButton(_ glyph: String, enabled: Bool, direction: Int,
                             box: ChipLineBox) -> some View {
        Button {
            step(direction)
        } label: {
            Canvas { context, size in
                context.draw(
                    Text(glyph).font(.custom(box.arrowFont.fontName, size: box.arrowFont.pointSize)),
                    at: CGPoint(x: box.arrowLeft(for: glyph, width: size.width),
                                y: box.arrowTop(for: glyph)),
                    anchor: .topLeading)
            }
            .foregroundStyle(enabled ? (scrubbing ? Theme.accentInk : Theme.gold)
                                     : foreground.opacity(0.35))
            .frame(width: 9, height: box.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled || editing)
        .accessibilityLabel(direction < 0 ? "Decrease" : "Increase")
    }

    // Reserve the domain's longest label, not the current animated width. The
    // sentence and drag target must not move when 59 minutes becomes 1 hour.
    private var labelWidth: CGFloat {
        ceil((domain.values + [clamped]).map {
            (format.label($0) as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 44) + 4
    }

    private func step(_ direction: Int) {
        guard !editing else { return }
        let next = domain.stepped(from: clamped, by: direction)
        guard next != clamped else { return }
        value = next
        revision &+= 1
    }

    /// Cumulative gesture translation is converted to deltas: the session owns
    /// the anchor and the accumulated travel, so reversing the hand reverses
    /// the value from the same point instead of drifting.
    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .updating($scrubActive) { _, active, _ in active = true }
            .onChanged { drag in
                guard !editing else { return }
                if session == nil {
                    session = InlineValueScrubSession(domain: domain, anchorValue: clamped)
                    lastTranslation = 0
                    scrubbing = true
                }
                guard var current = session else { return }
                let dx = drag.translation.width - lastTranslation
                lastTranslation = drag.translation.width
                let next = current.update(translation: Double(dx))
                session = current
                if next != value { value = next; revision &+= 1 }
            }
            .onEnded { drag in
                if var current = session {
                    let next = current.update(translation: Double(drag.translation.width - lastTranslation))
                    if next != value { value = next; revision &+= 1 }
                }
                resetScrub()
            }
    }

    private func resetScrub() {
        session = nil
        lastTranslation = 0
        scrubbing = false
    }

    private func beginEdit() {
        guard !editing else { return }
        resetScrub()
        focusTask?.cancel()
        errorTask?.cancel()
        editText = String(clamped)
        editError = false
        editing = true
        focusTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, editing else { return }
            editorFocused = true
            await Task.yield()
            guard !Task.isCancelled, editing, editorFocused else { return }
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
    }

    private func commitEdit() {
        guard editing else { return }
        focusTask?.cancel()
        errorTask?.cancel()
        editing = false
        if let parsed = InlineEditCommitPolicy.parse(editText, in: domain) {
            value = parsed
            revision &+= 1
        } else if !editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Keep the committed value: an unreadable entry never guesses.
            editError = true
            errorTask = Task { @MainActor in
                do { try await Task.sleep(nanoseconds: 600_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                editError = false
            }
        }
    }

    private func cancelEdit() {
        guard editing else { return }
        focusTask?.cancel()
        errorTask?.cancel()
        editing = false
        editError = false
    }
}

/// A two-state phrase inside the sentence. Clicking cycles to the next option
/// without a menu, matching the direct alternation the reference shows for
/// phrases such as the muting scope or the lock timing.
struct InlineCycleChip<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(label: String, value: Value)]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var hover = false
    @State private var revision = 0

    private var currentIndex: Int {
        options.firstIndex { $0.value == selection } ?? 0
    }

    private var current: String {
        options.indices.contains(currentIndex) ? options[currentIndex].label : ""
    }

    var body: some View {
        let _ = revision
        return Button {
            guard !options.isEmpty else { return }
            selection = options[(currentIndex + 1) % options.count].value
            revision &+= 1
        } label: {
            HStack(spacing: 5) {
                Text(current)
                    .font(WakelyType.body(12.5, .semibold))
                    .fixedSize()
                    .foregroundStyle(Theme.ink)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.gold.opacity(hover ? 1 : 0.65))
            }
            .transaction { $0.animation = nil }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hover ? Theme.chipHover : Theme.chip)
                    .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(hover ? Theme.gold.opacity(0.55) : Theme.strokeHover, lineWidth: 1)
                    .animation(AppMotion.animation(.feedback, reduceMotion: reduceMotion), value: hover)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hover = inside
        }
        .accessibilityLabel(current)
        .accessibilityHint("Cycles choices")
    }
}

extension ValueChip.Style {
    var inlineFormat: InlineValueFormat {
        switch self {
        case .minutes: return .minutes
        case .seconds: return .seconds
        case .percent: return .percent
        case .hours: return .hours
        }
    }

    var accessibilityQuantity: String {
        switch self {
        case .minutes, .hours, .seconds: return "Duration"
        case .percent: return "Percentage"
        }
    }
}
