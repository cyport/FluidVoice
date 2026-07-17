//
//  LiveCaptionsWindowController.swift
//  Fluid
//
//  Floating panel for the Live Captions overlay. Mirrors the NSPanel setup
//  used by BottomOverlayWindowController (Sources/Fluid/Views/BottomOverlayView.swift)
//  but is an independent window with its own lifecycle, geometry, and
//  positioning so it can coexist with the recording pill/notch overlay.
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

        LiveCaptionsPresentationState.shared.isVisible = true
    }

    func hide() {
        guard let window, window.isVisible else { return }

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
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        // Purely informational overlay — never steal clicks from whatever's underneath.
        panel.ignoresMouseEvents = true

        let hostingView = NSHostingView(rootView: LiveCaptionsView())
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        self.window = panel
    }

    private func applyGeometry() {
        guard let window else { return }

        let width = SettingsStore.shared.liveCaptionsWindowWidth
        let lineHeight = SettingsStore.shared.liveCaptionsFontSize * 1.35
        let height = lineHeight * CGFloat(SettingsStore.shared.liveCaptionsMaxLines) + 32

        window.setContentSize(NSSize(width: width, height: height))
        self.positionWindow()
    }

    private func positionWindow() {
        guard let window else { return }
        let screen = self.targetScreen ?? window.screen ?? OverlayScreenResolver.screenForCurrentPointer()
        guard let screen else { return }

        let fullFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        let windowSize = window.frame.size

        let x = fullFrame.midX - windowSize.width / 2

        // Sit above the existing recording pill/notch overlay so both can be
        // visible at once without overlapping.
        let baseOffset: CGFloat = SettingsStore.shared.overlayPosition == .bottom
            ? CGFloat(SettingsStore.shared.overlayBottomOffset) + 90
            : 120

        var y = visibleFrame.minY + baseOffset
        let minY = visibleFrame.minY + 10
        let maxY = visibleFrame.maxY - windowSize.height - 10
        y = max(min(y, maxY), minY)

        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Drives the Live Captions content-level fade. LiveCaptionsView observes
/// this and applies its own `.animation(value:)` to `isVisible`, which is
/// far more reliable than animating NSWindow.alphaValue for a borderless,
/// non-activating panel.
@MainActor
final class LiveCaptionsPresentationState: ObservableObject {
    static let shared = LiveCaptionsPresentationState()

    @Published var isVisible: Bool = false

    private init() {}
}
