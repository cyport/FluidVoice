//
//  LiveCaptionsWindowController.swift
//  Fluid
//
//  Floating panel for the Live Captions overlay. Mirrors the NSPanel setup
//  used by BottomOverlayWindowController (Sources/Fluid/Views/BottomOverlayView.swift)
//  but is an independent window with its own lifecycle, geometry, and
//  positioning so it can coexist with the recording pill/notch overlay.
//
//  The window is user-draggable (click anywhere on its background, including
//  through the caption text, and drag). The dragged position is persisted
//  and reused on future shows instead of the default auto-positioning.
//
//  While shown, also tracks caption text activity: if no new word lands
//  within liveCaptionsInactivityTimeout seconds, the content fades out
//  (liveCaptionsInactivityFadeDuration) without hiding the window itself,
//  and clears once the fade has fully completed (not before — the buffer
//  reset itself should never be visible), so resuming speech starts blank
//  rather than continuing to grow the whole session's history. Fades back
//  in the moment new text arrives.
//

import AppKit
import Combine
import SwiftUI

@MainActor
final class LiveCaptionsWindowController {
    static let shared = LiveCaptionsWindowController()

    private var window: NSPanel?
    private var targetScreen: NSScreen?
    private var pendingOrderOutWorkItem: DispatchWorkItem?
    private var inactivityWorkItem: DispatchWorkItem?
    private var pendingClearWorkItem: DispatchWorkItem?
    private var textActivitySubscription: AnyCancellable?
    /// Set for the duration of clearDisplay() so the activity-tracking sink
    /// (see handleTextActivity) can tell our own clear apart from real new
    /// speech, without depending on reading text properties back mid-publish
    /// (see the comment in handleTextActivity for why that's unreliable).
    private var isSelfInflictedClear = false
    /// Suppresses the didMove-triggered position-save while we're
    /// repositioning the window ourselves (e.g. after a resize) — only
    /// user-initiated drags should overwrite the saved origin.
    private var isProgrammaticMove = false

    private init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LiveCaptionsGeometryChanged"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyGeometry()
            }
        }
        NotificationCenter.default.addObserver(forName: NSNotification.Name("LiveCaptionsAppearanceChanged"), object: nil, queue: .main) { _ in
            // SwiftUI content repaints on its own via @ObservedObject SettingsStore.shared;
            // nothing to do at the window-controller level.
        }
    }

    func show() {
        guard SettingsStore.shared.liveCaptionsEnabled else { return }

        self.pendingOrderOutWorkItem?.cancel()
        self.pendingOrderOutWorkItem = nil

        if self.window == nil {
            self.createWindow()
        }
        guard let window else { return }

        self.targetScreen = OverlayScreenResolver.screenForCurrentPointer()
        self.applyGeometry()

        // The window itself is always fully opaque once ordered front — the
        // fade is driven at the SwiftUI content level (LiveCaptionsPresentationState),
        // since animating NSWindow.alphaValue directly isn't reliably smooth
        // for a borderless, non-activating panel with a transparent backing.
        window.alphaValue = 1
        if !window.isVisible {
            window.orderFrontRegardless()
        }

        LiveCaptionsPresentationState.shared.fadeDuration = SettingsStore.shared.liveCaptionsFadeDuration
        LiveCaptionsPresentationState.shared.isVisible = true

        self.startTrackingActivity()
    }

    func hide() {
        self.stopTrackingActivity()

        guard let window, window.isVisible else { return }

        LiveCaptionsPresentationState.shared.fadeDuration = SettingsStore.shared.liveCaptionsFadeDuration
        LiveCaptionsPresentationState.shared.isVisible = false

        let fadeEnabled = SettingsStore.shared.liveCaptionsFadeEnabled
        let delay = fadeEnabled ? SettingsStore.shared.liveCaptionsFadeDuration : 0

        self.pendingOrderOutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.window?.orderOut(nil)
        }
        self.pendingOrderOutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    // MARK: - Inactivity auto-fade

    private func startTrackingActivity() {
        self.resetInactivityTimer()

        let textModel = LiveCaptionsTextModel.shared
        self.textActivitySubscription = Publishers.Merge(
            textModel.$renderedCommittedText.map { _ in () },
            textModel.$renderedPendingText.map { _ in () }
        )
        .sink { [weak self] in
            self?.handleTextActivity()
        }
    }

    private func stopTrackingActivity() {
        self.inactivityWorkItem?.cancel()
        self.inactivityWorkItem = nil
        self.pendingClearWorkItem?.cancel()
        self.pendingClearWorkItem = nil
        self.textActivitySubscription?.cancel()
        self.textActivitySubscription = nil
    }

    private func handleTextActivity() {
        // clearDisplay() (fired once a silence fade-out completes) also
        // publishes through renderedCommittedText/renderedPendingText, which
        // is what this method listens to. Without this guard, our own clear
        // would be mistaken for new speech: it would immediately fade a
        // blank box back in and re-arm a fresh inactivity timer, producing a
        // phantom fade cycle that runs indefinitely with no real speech
        // behind it, and fights with genuinely new activity once it does
        // arrive (the "timing goes wrong the longer it runs" symptom).
        //
        // This can't be a guard on the current text being non-empty: @Published
        // sends through its subject in willSet, so a sink reading the
        // property back — even synchronously, as this one does — sees the
        // OLD value, not the one just being set. That made the equivalent
        // "is text empty" check here reliably wrong. isSelfInflictedClear is
        // a plain flag with no dependency on Combine's publish timing.
        guard !self.isSelfInflictedClear else { return }

        // Speech resuming after a silence-triggered fade cancels any
        // still-pending clear from that fade — the buffer we're now adding
        // to is the one that should stay.
        self.pendingClearWorkItem?.cancel()
        self.pendingClearWorkItem = nil

        // New words arriving after a silence-triggered fade should bring
        // captions back, using the same (typically snappier) inactivity
        // fade duration rather than the general show/hide one.
        if !LiveCaptionsPresentationState.shared.isVisible {
            LiveCaptionsPresentationState.shared.fadeDuration = SettingsStore.shared.liveCaptionsInactivityFadeDuration
            LiveCaptionsPresentationState.shared.isVisible = true
        }
        self.resetInactivityTimer()
    }

    private func resetInactivityTimer() {
        self.inactivityWorkItem?.cancel()
        self.inactivityWorkItem = nil

        guard SettingsStore.shared.liveCaptionsInactivityFadeEnabled else { return }

        let timeout = SettingsStore.shared.liveCaptionsInactivityTimeout
        let workItem = DispatchWorkItem { [weak self] in
            // liveCaptionsInactivityFadeEnabled (checked in the guard above)
            // is what actually governs this fade — liveCaptionsFadeEnabled is
            // the unrelated general show/hide toggle. Using the latter here
            // previously meant the clear could fire before the fade-out
            // animation it was supposed to wait for had actually finished.
            let fadeDuration = SettingsStore.shared.liveCaptionsInactivityFadeDuration
            LiveCaptionsPresentationState.shared.fadeDuration = fadeDuration
            LiveCaptionsPresentationState.shared.isVisible = false
            self?.inactivityWorkItem = nil

            // Clear only once the fade-out has fully finished, so the reset
            // itself is never visible — otherwise the words would blink to
            // blank while the box is still partway through fading.
            self?.pendingClearWorkItem?.cancel()
            let clearWorkItem = DispatchWorkItem {
                self?.isSelfInflictedClear = true
                LiveCaptionsTextModel.shared.clearDisplay()
                self?.isSelfInflictedClear = false
            }
            self?.pendingClearWorkItem = clearWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeDuration, execute: clearWorkItem)
        }
        self.inactivityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func createWindow() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Click-and-drag anywhere on the panel (including through the text,
        // since SwiftUI Text doesn't itself consume mouse-down) moves it.
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: LiveCaptionsView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        self.window = panel

        // Deliberately not deferred via Task { @MainActor in } like the other
        // observers in this file — isProgrammaticMove must be checked
        // synchronously (it's flipped back to false immediately after the
        // triggering setFrameOrigin call), so an async hop here would always
        // see it as false and defeat the programmatic/user-drag distinction.
        // queue: .main guarantees this already runs on the main actor at
        // runtime; assumeIsolated asserts that to the compiler.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isProgrammaticMove, let window = self.window else { return }
                SettingsStore.shared.liveCaptionsWindowOrigin = window.frame.origin
            }
        }
    }

    private func applyGeometry() {
        guard let window else { return }

        let width = SettingsStore.shared.liveCaptionsWindowWidth
        // Must match LiveCaptionsStyle.contentHeight exactly (same measured
        // value, not a separately-computed approximation) — a previous,
        // independent `fontSize * 1.35 * maxLines` formula here disagreed
        // with the content view's own measured clip-box height by a few
        // points, which is what made the top line look cropped/drifting.
        let height = LiveCaptionsStyle.contentHeight + LiveCaptionsStyle.verticalPadding * 2

        window.setContentSize(NSSize(width: width, height: height))
        self.positionWindow()
    }

    private func positionWindow() {
        guard let window else { return }
        let screen = self.targetScreen ?? window.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size

        let origin: NSPoint
        if let saved = SettingsStore.shared.liveCaptionsWindowOrigin {
            // Clamp in case the saved position came from a since-disconnected
            // screen, or the window has since been resized.
            let x = max(min(saved.x, visibleFrame.maxX - windowSize.width), visibleFrame.minX)
            let y = max(min(saved.y, visibleFrame.maxY - windowSize.height), visibleFrame.minY)
            origin = NSPoint(x: x, y: y)
        } else {
            let fullFrame = screen.frame
            let x = fullFrame.midX - windowSize.width / 2

            // Sit above the existing recording pill/notch overlay so both can
            // be visible at once without overlapping.
            let baseOffset: CGFloat = SettingsStore.shared.overlayPosition == .bottom
                ? CGFloat(SettingsStore.shared.overlayBottomOffset) + 90
                : 120

            let minY = visibleFrame.minY + 10
            let maxY = visibleFrame.maxY - windowSize.height - 10
            let y = max(min(visibleFrame.minY + baseOffset, maxY), minY)
            origin = NSPoint(x: x, y: y)
        }

        self.isProgrammaticMove = true
        window.setFrameOrigin(origin)
        self.isProgrammaticMove = false
    }
}

/// Drives the Live Captions content-level fade. LiveCaptionsView observes
/// this and applies its own `.animation(value:)` to `isVisible`, which is
/// far more reliable than animating NSWindow.alphaValue for a borderless,
/// non-activating panel. fadeDuration is set by the controller immediately
/// before each isVisible change, so different triggers (recording
/// start/stop vs. inactivity) can use different durations.
@MainActor
final class LiveCaptionsPresentationState: ObservableObject {
    static let shared = LiveCaptionsPresentationState()

    @Published var isVisible: Bool = false
    @Published var fadeDuration: Double = 0.25

    private init() {}
}
