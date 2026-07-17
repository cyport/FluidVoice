//
//  LiveCaptionsView.swift
//  Fluid
//
//  SwiftUI content for the Live Captions overlay. Renders committed
//  (frozen, full-opacity) and pending (still-shifting, dimmed) caption
//  text as one flowed paragraph.
//
//  Two separate content view types share the same styling (LiveCaptionsStyle)
//  but are deliberately NOT the same View type or instance:
//  - LiveCaptionsTextContentView: the live, on-screen window. Its true
//    height is measured and animated so new lines push older ones up
//    smoothly instead of jumping.
//  - LiveCaptionsSyphonContentView: rendered off-screen via ImageRenderer
//    for the Syphon texture publisher. No @State/animation — it's a plain
//    per-frame snapshot. Keeping this fully separate from the live window's
//    view (rather than reusing the same struct/instance) avoids the two
//    concurrent SwiftUI render passes (one on-screen NSHostingView, one
//    offscreen ImageRenderer polling at 15fps) interfering with each
//    other's rendering/animation state.
//

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

/// Shared, non-View styling logic for both content view types — colors,
/// font, dimensions, and the committed/pending Text builders.
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
        if family == SettingsStore.liveCaptionsSystemFontSentinel {
            return .system(size: SettingsStore.shared.liveCaptionsFontSize, weight: .semibold)
        }
        return .custom(family, size: SettingsStore.shared.liveCaptionsFontSize)
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

/// Text-only caption content for the on-screen window: committed (frozen,
/// full-opacity) + pending (dimmed) words, with optional outline/drop-shadow,
/// clipped to a measured-and-animated scrolling window. No background —
/// fully transparent, so LiveCaptionsView can lay a background box behind it.
struct LiveCaptionsTextContentView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var textModel = LiveCaptionsTextModel.shared

    @State private var measuredTextHeight: CGFloat = 0

    private let scrollAnimationDuration: Double = 0.25

    /// Positive while there are fewer than a boxful of lines (keeps text
    /// glued to the bottom of the box); negative once content overflows the
    /// box (pushes the excess above the top edge, where it gets clipped).
    /// Animating this single value is what makes new lines push older ones
    /// up smoothly instead of the box's contents jumping.
    private var scrollOffset: CGFloat {
        LiveCaptionsStyle.contentHeight - self.measuredTextHeight
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
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
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: LiveCaptionsHeightPreferenceKey.self, value: proxy.size.height)
            }
        )
        .offset(y: self.scrollOffset)
        .animation(.easeOut(duration: self.scrollAnimationDuration), value: self.measuredTextHeight)
        .frame(width: LiveCaptionsStyle.textAreaWidth, height: LiveCaptionsStyle.contentHeight, alignment: .top)
        .clipped()
        .mask(LiveCaptionsStyle.topFadeMask)
        .onPreferenceChange(LiveCaptionsHeightPreferenceKey.self) { newHeight in
            self.measuredTextHeight = newHeight
        }
        .padding(.horizontal, LiveCaptionsStyle.horizontalPadding)
        .padding(.vertical, LiveCaptionsStyle.verticalPadding)
    }
}

/// Text-only caption content for the Syphon texture publisher. Deliberately
/// static (no @State, no GeometryReader/PreferenceKey, no .animation) since
/// it's re-instantiated and snapshotted fresh on every publish tick via
/// ImageRenderer — a plain bottom-anchored clip is enough for a still frame,
/// and avoids any live-window/animation-driver interaction.
struct LiveCaptionsSyphonContentView: View {
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

private struct LiveCaptionsHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
