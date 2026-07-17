//
//  LiveCaptionsView.swift
//  Fluid
//
//  SwiftUI content for the Live Captions overlay. Renders committed
//  (frozen, full-opacity) and pending (still-shifting, dimmed) caption
//  text as one flowed paragraph. The text block's true height is measured
//  and it's shifted upward with an animated offset as it grows past the
//  visible line count, so older lines scroll off the top smoothly instead
//  of the whole block jumping.
//
//  LiveCaptionsTextContentView holds just the text (no background, fully
//  transparent) so it can be reused both for the on-screen window
//  (LiveCaptionsView, which adds a background box) and for the Syphon
//  texture publisher (LiveCaptionsSyphonPublisher), which needs text-only
//  output with alpha.
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

/// Text-only caption content: committed (frozen, full-opacity) + pending
/// (dimmed) words, with optional outline/drop-shadow, clipped to a
/// measured-and-animated scrolling window. No background — fully
/// transparent, so it can be composited over anything.
struct LiveCaptionsTextContentView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var textModel = LiveCaptionsTextModel.shared

    @State private var measuredTextHeight: CGFloat = 0

    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 16
    private let scrollAnimationDuration: Double = 0.25
    private let outlineWidth: CGFloat = 1.2
    /// 8-direction offsets used to fake a text stroke, since SwiftUI has no
    /// native text-outline modifier.
    private static let outlineDirections: [CGSize] = [
        CGSize(width: -1, height: -1), CGSize(width: 0, height: -1), CGSize(width: 1, height: -1),
        CGSize(width: -1, height: 0), CGSize(width: 1, height: 0),
        CGSize(width: -1, height: 1), CGSize(width: 0, height: 1), CGSize(width: 1, height: 1),
    ]

    private var textColor: Color {
        Color(hex: self.settings.liveCaptionsTextColorHex) ?? .white
    }

    private var outlineColor: Color {
        Color(hex: self.settings.liveCaptionsOutlineColorHex) ?? .black
    }

    private var font: Font {
        let family = self.settings.liveCaptionsFontFamily
        if family == SettingsStore.liveCaptionsSystemFontSentinel {
            return .system(size: self.settings.liveCaptionsFontSize, weight: .semibold)
        }
        return .custom(family, size: self.settings.liveCaptionsFontSize)
    }

    private var lineHeight: CGFloat {
        self.settings.liveCaptionsFontSize * 1.35
    }

    private var contentHeight: CGFloat {
        self.lineHeight * CGFloat(self.settings.liveCaptionsMaxLines)
    }

    private var textAreaWidth: CGFloat {
        max(self.settings.liveCaptionsWindowWidth - self.horizontalPadding * 2, 100)
    }

    private var committedText: Text {
        Text(self.textModel.renderedCommittedText)
            .foregroundColor(self.textColor)
    }

    private var pendingText: Text {
        Text(self.textModel.renderedPendingText)
            .foregroundColor(self.textColor.opacity(0.55))
    }

    private var combinedText: Text {
        let committed = self.textModel.renderedCommittedText
        let pending = self.textModel.renderedPendingText
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
    private var outlineText: Text {
        let committed = self.textModel.renderedCommittedText
        let pending = self.textModel.renderedPendingText
        let combined = [committed, pending].filter { !$0.isEmpty }.joined(separator: " ")
        return Text(combined).foregroundColor(self.outlineColor)
    }

    /// Soft fade on the topmost (possibly partially-clipped) line, matching
    /// how macOS/Zoom-style live captions render the "more text above" edge.
    private var topFadeMask: LinearGradient {
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

    /// Positive while there are fewer than a boxful of lines (keeps text
    /// glued to the bottom of the box); negative once content overflows the
    /// box (pushes the excess above the top edge, where it gets clipped).
    /// Animating this single value is what makes new lines push older ones
    /// up smoothly instead of the box's contents jumping.
    private var scrollOffset: CGFloat {
        self.contentHeight - self.measuredTextHeight
    }

    private func styledTextBlock(_ text: Text) -> some View {
        text
            .font(self.font)
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if self.settings.liveCaptionsOutlineEnabled {
                ForEach(Array(Self.outlineDirections.enumerated()), id: \.offset) { _, direction in
                    self.styledTextBlock(self.outlineText)
                        .offset(x: direction.width * self.outlineWidth, y: direction.height * self.outlineWidth)
                }
            }

            self.styledTextBlock(self.combinedText)
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
        .frame(width: self.textAreaWidth, height: self.contentHeight, alignment: .top)
        .clipped()
        .mask(self.topFadeMask)
        .onPreferenceChange(LiveCaptionsHeightPreferenceKey.self) { newHeight in
            self.measuredTextHeight = newHeight
        }
        .padding(.horizontal, self.horizontalPadding)
        .padding(.vertical, self.verticalPadding)
    }
}

private struct LiveCaptionsHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
