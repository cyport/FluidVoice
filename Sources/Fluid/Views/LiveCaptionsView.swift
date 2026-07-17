//
//  LiveCaptionsView.swift
//  Fluid
//
//  SwiftUI content for the Live Captions overlay. Renders committed
//  (frozen, full-opacity) and pending (still-shifting, dimmed) caption
//  text as one flowed paragraph, clipped to a fixed-height box anchored to
//  the bottom edge — as text grows past the visible line count, older
//  lines are clipped off the top rather than the box reflowing. Used both
//  by the on-screen window (LiveCaptionsView) and by the Syphon texture
//  publisher (ImageRenderer-rendered snapshots of LiveCaptionsTextContentView).
//

import AppKit
import SwiftUI

struct LiveCaptionsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var presentation = LiveCaptionsPresentationState.shared

    private var backgroundColor: Color {
        (Color(hex: self.settings.liveCaptionsBackgroundColorHex) ?? .black)
            .opacity(self.settings.liveCaptionsBackgroundOpacity)
    }

    var body: some View {
        LiveCaptionsTextContentView()
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(self.backgroundColor)
            )
            .opacity(self.presentation.isVisible ? 1 : 0)
            .animation(
                self.settings.liveCaptionsFadeEnabled ? .easeInOut(duration: self.settings.liveCaptionsFadeDuration) : nil,
                value: self.presentation.isVisible
            )
    }
}

/// Shared, non-View styling logic — colors, font, dimensions, and the
/// committed/pending Text builders.
enum LiveCaptionsStyle {
    static let horizontalPadding: CGFloat = 16
    static let verticalPadding: CGFloat = 16
    static let outlineWidth: CGFloat = 1.2
    /// 8-direction offsets used to fake a text stroke, since SwiftUI has no
    /// native text-outline modifier.
    static let outlineDirections: [CGSize] = [
        CGSize(width: -1, height: -1), CGSize(width: 0, height: -1), CGSize(width: 1, height: -1),
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
        CGSize(width: -1, height: 1), CGSize(width: 0, height: 1), CGSize(width: 1, height: 1),
    ]

    static var textColor: Color {
        Color(hex: SettingsStore.shared.liveCaptionsTextColorHex) ?? .white
    }

    static var outlineColor: Color {
        Color(hex: SettingsStore.shared.liveCaptionsOutlineColorHex) ?? .black
    }

    static var font: Font {
        let family = SettingsStore.shared.liveCaptionsFontFamily
        let size = SettingsStore.shared.liveCaptionsFontSize
        guard family != SettingsStore.liveCaptionsSystemFontSentinel else {
            return .system(size: size, weight: .semibold)
        }
        // Font.custom(_:size:) expects a font's PostScript name, not its
        // family name, and those differ for most third-party fonts (e.g.
        // family "Hitmarker Text" -> PostScript name "HitmarkerText-Regular").
        // NSFontManager resolves by family correctly regardless of naming,
        // so go through NSFont and bridge to SwiftUI, with a safe fallback
        // if the family can't be resolved (e.g. no longer installed).
        if let nsFont = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) {
            return Font(nsFont)
        }
        return .system(size: size, weight: .semibold)
    }

    static var lineHeight: CGFloat {
        SettingsStore.shared.liveCaptionsFontSize * 1.35
    }

    static var contentHeight: CGFloat {
        self.lineHeight * CGFloat(SettingsStore.shared.liveCaptionsMaxLines)
    }

    static var textAreaWidth: CGFloat {
        max(SettingsStore.shared.liveCaptionsWindowWidth - self.horizontalPadding * 2, 100)
    }

    static var committedText: Text {
        Text(LiveCaptionsTextModel.shared.renderedCommittedText)
            .foregroundColor(self.textColor)
    }

    static var pendingText: Text {
        Text(LiveCaptionsTextModel.shared.renderedPendingText)
            .foregroundColor(self.textColor.opacity(0.55))
    }

    static var combinedText: Text {
        let committed = LiveCaptionsTextModel.shared.renderedCommittedText
        let pending = LiveCaptionsTextModel.shared.renderedPendingText
        if committed.isEmpty {
            return self.pendingText
        } else if pending.isEmpty {
            return self.committedText
        } else {
            return self.committedText + Text(" ") + self.pendingText
        }
    }

    /// Same content as combinedText but uniformly colored, for the outline
    /// layers — the stroke doesn't need the committed/pending distinction.
    static var outlineText: Text {
        let committed = LiveCaptionsTextModel.shared.renderedCommittedText
        let pending = LiveCaptionsTextModel.shared.renderedPendingText
        let combined = [committed, pending].filter { !$0.isEmpty }.joined(separator: " ")
        return Text(combined).foregroundColor(self.outlineColor)
    }

    /// Soft fade on the topmost (possibly partially-clipped) line, matching
    /// how macOS/Zoom-style live captions render the "more text above" edge.
    static var topFadeMask: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.16),
                .init(color: .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    static func styledTextBlock(_ text: Text) -> some View {
        text
            .font(self.font)
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Text-only caption content: committed (frozen, full-opacity) + pending
/// (dimmed) words, with optional outline/drop-shadow, clipped to a
/// fixed-height box bottom-anchored so older lines clip off the top as new
/// ones arrive. No background — fully transparent, so LiveCaptionsView can
/// lay a background box behind it, and the Syphon publisher can export it
/// with alpha intact.
///
/// Deliberately static (no @State/GeometryReader/PreferenceKey-driven
/// animation): an earlier version measured content height via a
/// GeometryReader + PreferenceKey feedback loop and animated an offset for
/// a smooth "push up" scroll effect, but the measured height reliably got
/// stuck at 0 (confirmed by direct instrumentation of onPreferenceChange),
/// permanently pushing all text below the visible clip bounds. A plain
/// `.frame(alignment: .bottom).clipped()` achieves the same "last N lines,
/// bottom-anchored" result with no measurement step required.
struct LiveCaptionsTextContentView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var textModel = LiveCaptionsTextModel.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if self.settings.liveCaptionsOutlineEnabled {
                ForEach(Array(LiveCaptionsStyle.outlineDirections.enumerated()), id: \.offset) { _, direction in
                    LiveCaptionsStyle.styledTextBlock(LiveCaptionsStyle.outlineText)
                        .offset(x: direction.width * LiveCaptionsStyle.outlineWidth, y: direction.height * LiveCaptionsStyle.outlineWidth)
                }
            }

            LiveCaptionsStyle.styledTextBlock(LiveCaptionsStyle.combinedText)
                .shadow(
                    color: self.settings.liveCaptionsShadowEnabled ? .black.opacity(0.55) : .clear,
                    radius: self.settings.liveCaptionsShadowEnabled ? 2.5 : 0,
                    x: 0,
                    y: self.settings.liveCaptionsShadowEnabled ? 1.5 : 0
                )
        }
        .frame(width: LiveCaptionsStyle.textAreaWidth, height: LiveCaptionsStyle.contentHeight, alignment: .bottom)
        .clipped()
        .mask(LiveCaptionsStyle.topFadeMask)
        .padding(.horizontal, LiveCaptionsStyle.horizontalPadding)
        .padding(.vertical, LiveCaptionsStyle.verticalPadding)
    }
}
