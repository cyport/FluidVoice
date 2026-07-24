//
//  LiveCaptionsView.swift
//  Fluid
//
//  SwiftUI content for the Live Captions overlay. Renders committed
//  (frozen, full-opacity) and pending (still-shifting, dimmed) caption text
//  as one flowed paragraph, with a hard line break after each completed
//  sentence (so a finished sentence's line never reflows as later words are
//  appended — see LiveCaptionsTextModel.pendingStartsNewLine), clipped to a
//  fixed-height box that animates upward as text grows past the visible
//  line count. Used both by the on-screen window (LiveCaptionsView) and by
//  the Syphon texture publisher (ImageRenderer-rendered snapshots of
//  LiveCaptionsTextContentView).
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

    /// Font.custom(_:size:) expects a font's PostScript name, not its family
    /// name, and those differ for most third-party fonts (e.g. family
    /// "Hitmarker Text" -> PostScript name "HitmarkerText-Regular").
    /// NSFontManager resolves by family correctly regardless of naming, so
    /// resolve to an NSFont here (also reused directly for text-height
    /// measurement below) and bridge to SwiftUI, with a safe fallback if the
    /// family can't be resolved (e.g. no longer installed).
    static var nsFont: NSFont {
        let family = SettingsStore.shared.liveCaptionsFontFamily
        let size = SettingsStore.shared.liveCaptionsFontSize
        guard family != SettingsStore.liveCaptionsSystemFontSentinel else {
            return .systemFont(ofSize: size, weight: .semibold)
        }
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? .systemFont(ofSize: size, weight: .semibold)
    }

    static var font: Font {
        Font(self.nsFont)
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

    /// " " or "\n" between the committed and pending text — a hard line
    /// break when the last committed word ended a sentence, so a freshly
    /// started sentence begins on its own line instead of continuing the
    /// previous (already-frozen) one.
    private static var pendingConnector: Text {
        Text(LiveCaptionsTextModel.shared.pendingStartsNewLine ? "\n" : " ")
    }

    static var combinedText: Text {
        let committed = LiveCaptionsTextModel.shared.renderedCommittedText
        let pending = LiveCaptionsTextModel.shared.renderedPendingText
        if committed.isEmpty {
            return self.pendingText
        } else if pending.isEmpty {
            return self.committedText
        } else {
            return self.committedText + self.pendingConnector + self.pendingText
        }
    }

    /// Same content as combinedText but uniformly colored, for the outline
    /// layers — the stroke doesn't need the committed/pending distinction.
    static var outlineText: Text {
        let committed = LiveCaptionsTextModel.shared.renderedCommittedText
        let pending = LiveCaptionsTextModel.shared.renderedPendingText
        if committed.isEmpty {
            return Text(pending).foregroundColor(self.outlineColor)
        } else if pending.isEmpty {
            return Text(committed).foregroundColor(self.outlineColor)
        } else {
            let connector = LiveCaptionsTextModel.shared.pendingStartsNewLine ? "\n" : " "
            return Text(committed + connector + pending).foregroundColor(self.outlineColor)
        }
    }

    /// Plain (unstyled) concatenation of committed + connector + pending,
    /// for text-height measurement — not for display.
    static var combinedPlainString: String {
        let committed = LiveCaptionsTextModel.shared.renderedCommittedText
        let pending = LiveCaptionsTextModel.shared.renderedPendingText
        if committed.isEmpty { return pending }
        if pending.isEmpty { return committed }
        let connector = LiveCaptionsTextModel.shared.pendingStartsNewLine ? "\n" : " "
        return committed + connector + pending
    }

    /// Synchronously measures the wrapped height of `text` at the current
    /// font/width, via NSAttributedString/NSString text layout rather than
    /// a SwiftUI GeometryReader — computed fresh on every call from the
    /// current text content, so (unlike the GeometryReader + PreferenceKey
    /// approach tried previously) there's no asynchronous feedback loop
    /// that can get stuck: the result is always correct as of this call.
    static func measuredHeight(for text: String) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: self.nsFont,
            .paragraphStyle: paragraphStyle,
        ]
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: self.textAreaWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        return ceil(bounds.height)
    }

    /// Soft fade on the topmost (possibly partially-clipped) line, matching
    /// how macOS/Zoom-style live captions render the "more text above" edge.
    /// A fixed point height, not a fraction of contentHeight — at 0.16 of
    /// contentHeight (the old approach) this covered roughly half of the
    /// topmost visible line for typical settings, making fully-visible text
    /// look cut off. A small fixed edge softens the clip boundary above the
    /// top line without eating into it.
    private static let topFadeHeight: CGFloat = 6

    static var topFadeMask: LinearGradient {
        let fraction = self.contentHeight > 0 ? min(self.topFadeHeight / self.contentHeight, 0.2) : 0
        return LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: fraction),
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
/// fixed-height box — as text grows past the visible line count, the block
/// is offset upward (animated) so older lines scroll off the top smoothly.
/// No background — fully transparent, so LiveCaptionsView can lay a
/// background box behind it, and the Syphon publisher can export it with
/// alpha intact.
///
/// The offset is driven by LiveCaptionsStyle.measuredHeight(for:), a
/// synchronous NSAttributedString-based text measurement — NOT a SwiftUI
/// GeometryReader + PreferenceKey feedback loop (an earlier version used
/// that and the measured height reliably got stuck at 0, confirmed by
/// direct instrumentation, permanently pushing all text below the visible
/// clip bounds). Since the measurement here is computed synchronously from
/// the current text on every body evaluation, there's no async step that
/// can get stuck.
struct LiveCaptionsTextContentView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var textModel = LiveCaptionsTextModel.shared

    private let scrollAnimationDuration: Double = 0.25

    private var measuredHeight: CGFloat {
        LiveCaptionsStyle.measuredHeight(for: LiveCaptionsStyle.combinedPlainString)
    }

    /// Positive while there's less than a boxful of text (keeps it glued to
    /// the bottom of the box); negative once content overflows the box
    /// (pushes the excess above the top edge, where it gets clipped).
    private var scrollOffset: CGFloat {
        LiveCaptionsStyle.contentHeight - self.measuredHeight
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
        .offset(y: self.scrollOffset)
        .animation(.easeOut(duration: self.scrollAnimationDuration), value: self.measuredHeight)
        .frame(width: LiveCaptionsStyle.textAreaWidth, height: LiveCaptionsStyle.contentHeight, alignment: .top)
        .clipped()
        .mask(LiveCaptionsStyle.topFadeMask)
        .padding(.horizontal, LiveCaptionsStyle.horizontalPadding)
        .padding(.vertical, LiveCaptionsStyle.verticalPadding)
    }
}
