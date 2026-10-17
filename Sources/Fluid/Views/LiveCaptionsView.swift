//
//  LiveCaptionsView.swift
//  Fluid
//
//  SwiftUI content for the Live Captions overlay. Renders committed
//  (frozen, full-opacity) and pending (still-shifting, dimmed) caption text
//  as one flowed paragraph, with a hard line break after each completed
//  sentence (so a finished sentence's line never reflows as later words are
//  appended — see LiveCaptionsTextModel.pendingStartsNewLine), trimmed to
//  the last N wrapped lines so nothing is ever cropped mid-glyph.
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
            // Only the text fades for the idle fade — the background box
            // stays visible. (Whole-window fades on show/hide are the
            // outer .opacity below.)
            .opacity(self.presentation.isTextVisible ? 1 : 0)
            .animation(.easeInOut(duration: self.presentation.fadeDuration), value: self.presentation.isTextVisible)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(self.backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.yellow, lineWidth: 1)
                    .opacity(self.settings.liveCaptionsDebugBorderEnabled ? 1 : 0)
            )
            .opacity(self.presentation.isVisible ? 1 : 0)
            .animation(
                self.settings.liveCaptionsFadeEnabled ? .easeInOut(duration: self.presentation.fadeDuration) : nil,
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
    /// resolve to an NSFont here (also reused directly for line-wrap
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

    static var maxLines: Int {
        max(min(SettingsStore.shared.liveCaptionsMaxLines, 6), 1)
    }

    /// A generous estimate for sizing the panel/clip box — not load-bearing
    /// for correctness anymore (see trailingLinesStartIndex below), just
    /// needs to comfortably fit maxLines lines of real SwiftUI-rendered
    /// text. Padded past the raw AppKit measurement: earlier attempts to
    /// make this pixel-exact against SwiftUI's own Text layout (matching
    /// paragraph style, line spacing, everything) still measurably
    /// disagreed with what actually rendered on screen — confirmed by
    /// rendering real captions to a PNG and seeing the top/bottom lines
    /// visibly cropped despite the two height formulas agreeing numerically.
    /// Since content is now trimmed to whole wrapped lines before it ever
    /// reaches the Text view (nothing left to clip in normal operation), a
    /// generous box only risks a little empty space at the bottom, never a
    /// cropped glyph.
    static var contentHeight: CGFloat {
        let probe = Array(repeating: "Wg", count: self.maxLines).joined(separator: "\n")
        return self.measuredHeight(for: probe) + 16
    }

    static var textAreaWidth: CGFloat {
        max(SettingsStore.shared.liveCaptionsWindowWidth - self.horizontalPadding * 2, 100)
    }

    static func combinedText(committed: String, pending: String, startsNewLine: Bool) -> Text {
        if committed.isEmpty {
            return Text(pending).foregroundColor(self.textColor.opacity(0.55))
        } else if pending.isEmpty {
            return Text(committed).foregroundColor(self.textColor)
        } else {
            let connector = Text(startsNewLine ? "\n" : " ")
            return Text(committed).foregroundColor(self.textColor)
                + connector
                + Text(pending).foregroundColor(self.textColor.opacity(0.55))
        }
    }

    /// Same content as combinedText but uniformly colored, for the outline
    /// layers — the stroke doesn't need the committed/pending distinction.
    static func outlineText(committed: String, pending: String, startsNewLine: Bool) -> Text {
        if committed.isEmpty {
            return Text(pending).foregroundColor(self.outlineColor)
        } else if pending.isEmpty {
            return Text(committed).foregroundColor(self.outlineColor)
        } else {
            let connector = startsNewLine ? "\n" : " "
            return Text(committed + connector + pending).foregroundColor(self.outlineColor)
        }
    }

    /// Synchronously measures the wrapped height of `text` at the current
    /// font/width, via NSAttributedString/NSString text layout. Used only
    /// for the generous panel-sizing estimate above — no longer load-bearing
    /// for what gets cropped (see trailingLinesStartIndex).
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

    /// Returns the index within `text` where the last `maxLines` *wrapped*
    /// lines begin, using AppKit's real line-breaking (NSLayoutManager) at
    /// the exact font/width captions render with. This is deliberately NOT
    /// a height calculation: matching pixel HEIGHTS between AppKit and
    /// SwiftUI turned out not to be reliable enough in practice (see
    /// contentHeight's comment) to safely clip against. Where text WRAPS is
    /// a much more robust thing for the two to agree on — both ultimately
    /// resolve to CoreText's line-breaking for the same font/width/text —
    /// so the caller trims the STRING itself to this slice and feeds only
    /// that to the Text view. With nothing left past what's meant to be
    /// shown, there's nothing for a height mismatch to crop.
    static func trailingLinesStartIndex(in text: String, maxLines: Int) -> String.Index {
        guard !text.isEmpty else { return text.startIndex }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        let textStorage = NSTextStorage(string: text, attributes: [
            .font: self.nsFont,
            .paragraphStyle: paragraphStyle,
        ])
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: self.textAreaWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)

        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return text.startIndex }

        var lineStartOffsets: [Int] = []
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: glyphCount)) { _, _, _, glyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            lineStartOffsets.append(charRange.location)
        }
        guard lineStartOffsets.count > maxLines else { return text.startIndex }

        let cutUTF16Offset = lineStartOffsets[lineStartOffsets.count - maxLines]
        guard let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: cutUTF16Offset, limitedBy: text.utf16.endIndex),
              let index = utf16Index.samePosition(in: text)
        else { return text.startIndex }
        return index
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
/// (dimmed) words, with optional outline/drop-shadow, trimmed to the last
/// maxLines *wrapped* lines before rendering — not clipped/offset after the
/// fact. No background — fully transparent, so LiveCaptionsView can lay a
/// background box behind it.
struct LiveCaptionsTextContentView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var textModel = LiveCaptionsTextModel.shared

    /// The committed/pending text actually fed to the Text view, trimmed to
    /// at most maxLines wrapped lines. Splitting is done on the full
    /// committed+connector+pending string so the trim can land inside
    /// either part; see LiveCaptionsStyle.trailingLinesStartIndex for how
    /// the cut point itself is found.
    private var visibleSlice: (committed: String, pending: String) {
        let committed = self.textModel.renderedCommittedText
        let pending = self.textModel.renderedPendingText
        let connector = self.textModel.pendingStartsNewLine ? "\n" : " "

        let full: String
        if committed.isEmpty {
            full = pending
        } else if pending.isEmpty {
            full = committed
        } else {
            full = committed + connector + pending
        }
        guard !full.isEmpty else { return ("", "") }

        let maxLines = LiveCaptionsStyle.maxLines
        let cutIndex = LiveCaptionsStyle.trailingLinesStartIndex(in: full, maxLines: maxLines)
        guard cutIndex > full.startIndex else { return (committed, pending) }

        let committedEndIndex = committed.isEmpty ? full.startIndex : full.index(full.startIndex, offsetBy: committed.count)
        if cutIndex >= committedEndIndex {
            return ("", String(full[cutIndex...]))
        } else {
            return (String(full[cutIndex..<committedEndIndex]), pending)
        }
    }

    var body: some View {
        let slice = self.visibleSlice

        ZStack(alignment: .topLeading) {
            if self.settings.liveCaptionsOutlineEnabled {
                ForEach(Array(LiveCaptionsStyle.outlineDirections.enumerated()), id: \.offset) { _, direction in
                    LiveCaptionsStyle.styledTextBlock(
                        LiveCaptionsStyle.outlineText(committed: slice.committed, pending: slice.pending, startsNewLine: self.textModel.pendingStartsNewLine)
                    )
                    .offset(x: direction.width * LiveCaptionsStyle.outlineWidth, y: direction.height * LiveCaptionsStyle.outlineWidth)
                }
            }

            LiveCaptionsStyle.styledTextBlock(
                LiveCaptionsStyle.combinedText(committed: slice.committed, pending: slice.pending, startsNewLine: self.textModel.pendingStartsNewLine)
            )
            .shadow(
                color: self.settings.liveCaptionsShadowEnabled ? .black.opacity(0.55) : .clear,
                radius: self.settings.liveCaptionsShadowEnabled ? 2.5 : 0,
                x: 0,
                y: self.settings.liveCaptionsShadowEnabled ? 1.5 : 0
            )
        }
        .animation(.easeOut(duration: 0.15), value: slice.committed + slice.pending)
        // Headroom so ascenders (t, l, f…) and the 1pt outline offsets aren't
        // clipped at the box's top edge.
        .padding(.top, 4)
        .frame(width: LiveCaptionsStyle.textAreaWidth, height: LiveCaptionsStyle.contentHeight, alignment: .top)
        .clipped()
        // Drawn after .clipped(), not inside it's content, so the true
        // crop boundary is always fully visible — for diagnosing whether
        // this box is ever actually the thing doing any clipping.
        .overlay(
            Rectangle()
                .stroke(Color.red, lineWidth: 1)
                .opacity(self.settings.liveCaptionsDebugBorderEnabled ? 1 : 0)
        )
        .padding(.horizontal, LiveCaptionsStyle.horizontalPadding)
        .padding(.vertical, LiveCaptionsStyle.verticalPadding)
    }
}
