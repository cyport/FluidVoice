//
//  EditableSlider.swift
//  Fluid
//
//  A Slider whose value label is also a keyboard-editable field (click the
//  number to type an exact value), and whose drag doesn't write straight
//  through to `value` on every pixel of motion.
//
//  Every settings row so far bound its Slider directly to a SettingsStore
//  property — e.g. `Slider(value: self.$settings.liveCaptionsFontSize, ...)`.
//  SwiftUI calls that binding's setter continuously while dragging, and
//  SettingsStore's setters each do a synchronous UserDefaults write plus an
//  objectWillChange broadcast to every observer of the shared singleton —
//  fine for an occasional toggle, but on a fast-firing drag gesture across a
//  settings window with many rows all watching the same object, this is
//  what made dragging feel sluggish. Dragging now updates a local `liveValue`
//  directly (cheap, no store writes), commits through to the real binding
//  throttled while dragging (so live-preview-driven rows like font size
//  still update smoothly without saturating the main thread), and commits
//  immediately the moment the drag ends so the final value is never lost to
//  a pending throttle.
//

import SwiftUI

struct EditableSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var sliderWidth: CGFloat?
    var labelWidth: CGFloat = 54
    var format: (Double) -> String
    var parse: (String) -> Double? = { Double($0) }
    /// Seeds the text field when editing starts. Defaults to a plain number
    /// in `value`'s own scale — override this (together with `parse`) for
    /// rows like percentage sliders where the displayed unit (e.g. "60%")
    /// is on a different scale than the underlying value (0.6), so what you
    /// see and what you type match.
    var editSeed: ((Double) -> String)?

    @State private var liveValue: Double
    @State private var isEditingText = false
    @State private var textValue: String = ""
    @State private var commitWorkItem: DispatchWorkItem?
    @FocusState private var textFieldFocused: Bool

    init(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        sliderWidth: CGFloat? = nil,
        labelWidth: CGFloat = 54,
        format: @escaping (Double) -> String,
        parse: @escaping (String) -> Double? = { Double($0) },
        editSeed: ((Double) -> String)? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.sliderWidth = sliderWidth
        self.labelWidth = labelWidth
        self.format = format
        self.parse = parse
        self.editSeed = editSeed
        self._liveValue = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let step {
                    Slider(value: self.$liveValue, in: self.range, step: step, onEditingChanged: self.handleEditingChanged)
                } else {
                    Slider(value: self.$liveValue, in: self.range, onEditingChanged: self.handleEditingChanged)
                }
            }
            .controlSize(.small)
            .frame(width: self.sliderWidth)
            .onChange(of: self.liveValue) { _, newValue in
                self.scheduleThrottledCommit(newValue)
            }

            if self.isEditingText {
                TextField("", text: self.$textValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .frame(width: self.labelWidth + 12)
                    .focused(self.$textFieldFocused)
                    .onSubmit { self.commitTextEdit() }
                    .onChange(of: self.textFieldFocused) { _, focused in
                        if !focused { self.commitTextEdit() }
                    }
            } else {
                Text(self.format(self.value))
                    .font(.caption.monospaced())
                    .frame(width: self.labelWidth, alignment: .trailing)
                    .contentShape(Rectangle())
                    .onTapGesture { self.beginTextEdit() }
            }
        }
        .onChange(of: self.value) { _, newValue in
            // Keep local drag state in sync with external changes (e.g. a
            // settings reset), but not while the user's mid-edit — that
            // would yank the text field's content out from under them.
            if !self.isEditingText {
                self.liveValue = newValue
            }
        }
    }

    /// Throttles commits during a drag so a live-preview-driven row (font
    /// size, opacity, etc.) still updates smoothly without writing through
    /// on every pixel of motion.
    private func scheduleThrottledCommit(_ newValue: Double) {
        self.commitWorkItem?.cancel()
        let item = DispatchWorkItem { self.value = newValue }
        self.commitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func handleEditingChanged(_ editing: Bool) {
        guard !editing else { return }
        // Drag just ended — commit the final value immediately rather than
        // waiting out any still-pending throttled commit.
        self.commitWorkItem?.cancel()
        self.commitWorkItem = nil
        self.value = self.liveValue
    }

    private func beginTextEdit() {
        self.textValue = self.editSeed?(self.value) ?? self.plainNumericString(self.value)
        self.isEditingText = true
        DispatchQueue.main.async { self.textFieldFocused = true }
    }

    private func commitTextEdit() {
        defer {
            self.isEditingText = false
            self.textFieldFocused = false
        }
        guard let parsed = self.parse(self.textValue) else { return }
        let clamped = min(max(parsed, self.range.lowerBound), self.range.upperBound)
        self.liveValue = clamped
        self.value = clamped
    }

    private func plainNumericString(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.2f", value)
    }
}
