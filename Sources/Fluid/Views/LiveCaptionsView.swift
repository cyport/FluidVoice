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

import SwiftUI

struct LiveCaptionsView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var textModel = LiveCaptionsTextModel.shared
    @ObservedObject private var presentation = LiveCaptionsPresentationState.shared

    @State private var measuredTextHeight: CGFloat = 0

    private let horizontalPadding: CGFloat = 16
    private let verticalPadding: CGFloat = 16
    private let scrollAnimationDuration: Double = 0.25

    private var textColor: Color {
        Color(hex: self.settings.liveCaptionsTextColorHex) ?? .white
    }

    private var backgroundColor: Color {
        (Color(hex: self.settings.liveCaptionsBackgroundColorHex) ?? .black)
            .opacity(self.settings.liveCaptionsBackgroundOpacity)
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

    var body: some View {
        self.combinedText
            .font(self.font)
            .lineSpacing(4)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct LiveCaptionsHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
