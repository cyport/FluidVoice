//
//  LiveCaptionsTextModel.swift
//  Fluid
//
//  Word-commit stabilizer for the Live Captions overlay. Sits between
//  ASRService.$partialTranscription (which republishes the whole utterance
//  on every streaming tick, with no real stability guarantee) and the
//  captions display, so that once a word has been shown it is never
//  rewritten or repositioned.
//

import Combine
import Foundation

@MainActor
final class LiveCaptionsTextModel: ObservableObject {
    static let shared = LiveCaptionsTextModel()

    /// Consecutive matching ticks required before a pending word freezes.
    private let stabilityTickThreshold = 2
    /// A pending word freezes once it's this many words behind the live edge,
    /// regardless of match count, so it can never get stuck dimmed forever.
    private let maxPendingDistanceFromEdge = 4
    /// How long a committed word is kept in memory after it's scrolled off
    /// screen. Only ever applied to words already outside the rendered
    /// window, so this never affects what's currently visible.
    private let offScreenRetentionInterval: TimeInterval = 10

    /// Full-session committed words, trimmed by purgeExpiredWords() for
    /// memory once they're off screen. NOTE: this is NOT the same as "how
    /// many words of the ASR stream have been committed" — see
    /// totalCommittedCount — purging must never be allowed to shrink that.
    private var committedWords: [String] = []
    /// Parallel to committedWords — systemUptime at the moment each word was committed.
    private var committedWordTimestamps: [TimeInterval] = []
    /// Monotonically increasing count of words committed so far, used to
    /// slice the ASR stream's new tail. Deliberately separate from
    /// committedWords.count, which purgeExpiredWords() can shrink — using
    /// the array's count directly here would make purging (a memory
    /// optimization) desync the stabilizer's position in the ASR stream,
    /// causing already-shown, already-purged words to be mistaken for new
    /// speech and re-inserted out of order.
    private var totalCommittedCount = 0

    private var pendingWords: [String] = []
    private var stableTicks: [Int] = []

    @Published private(set) var renderedCommittedText: String = ""
    @Published private(set) var renderedPendingText: String = ""
    /// Whether the pending (in-progress) text should start on a new line —
    /// true when the last committed word ended a sentence.
    @Published private(set) var pendingStartsNewLine: Bool = false

    private init() {}

    func ingest(_ partialText: String) {
        let newWords = Self.tokenize(partialText)

        let newTail: [String]
        if newWords.count > self.totalCommittedCount {
            newTail = Array(newWords[self.totalCommittedCount...])
        } else {
            // Already-committed words are never re-validated against fresh
            // transcriptions, so a shorter/disagreeing result simply means
            // there's no new tail this tick.
            newTail = []
        }

        let oldPending = self.pendingWords
        let oldStableTicks = self.stableTicks
        var newStableTicks = [Int](repeating: 1, count: newTail.count)
        for i in 0..<newTail.count {
            if i < oldPending.count, Self.normalize(oldPending[i]) == Self.normalize(newTail[i]) {
                newStableTicks[i] = oldStableTicks[i] + 1
            } else {
                newStableTicks[i] = 1
            }
        }

        var promoteCount = 0
        let lastIndex = newTail.count - 1
        for i in 0..<newTail.count {
            let distanceFromEdge = lastIndex - i
            if newStableTicks[i] >= self.stabilityTickThreshold || distanceFromEdge >= self.maxPendingDistanceFromEdge {
                promoteCount += 1
            } else {
                break
            }
        }

        var remainingTail = newTail
        var remainingTicks = newStableTicks
        if promoteCount > 0 {
            let now = ProcessInfo.processInfo.systemUptime
            self.committedWords.append(contentsOf: remainingTail[0..<promoteCount])
            self.committedWordTimestamps.append(contentsOf: repeatElement(now, count: promoteCount))
            self.totalCommittedCount += promoteCount
            remainingTail.removeFirst(promoteCount)
            remainingTicks.removeFirst(promoteCount)
        }

        self.pendingWords = remainingTail
        self.stableTicks = remainingTicks

        self.purgeExpiredWords()
        self.updateRenderedText()
    }

    /// Promotes all pending words immediately, e.g. when recording stops so
    /// the final line isn't left half-dimmed.
    func flushAll() {
        guard !self.pendingWords.isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        self.committedWords.append(contentsOf: self.pendingWords)
        self.committedWordTimestamps.append(contentsOf: repeatElement(now, count: self.pendingWords.count))
        self.totalCommittedCount += self.pendingWords.count
        self.pendingWords = []
        self.stableTicks = []
        self.updateRenderedText()
    }

    /// Clears all captions state. Called at recording start only — captions
    /// accumulate for a whole session, not per-utterance.
    func reset() {
        self.committedWords = []
        self.committedWordTimestamps = []
        self.totalCommittedCount = 0
        self.pendingWords = []
        self.stableTicks = []
        self.renderedCommittedText = ""
        self.renderedPendingText = ""
        self.pendingStartsNewLine = false
    }

    /// Drops committed words that are both already scrolled off screen
    /// (beyond the rendered window) and older than the retention interval,
    /// so a long dictation session doesn't accumulate memory forever. Only
    /// touches committedWords/committedWordTimestamps (used for rendering) —
    /// never totalCommittedCount, which must stay in lockstep with the ASR
    /// stream regardless of what's been purged from the display buffer.
    private func purgeExpiredWords() {
        let visibleWordWindow = self.currentVisibleWordWindow()
        let purgeableCount = max(0, self.committedWords.count - visibleWordWindow)
        guard purgeableCount > 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime
        var removeCount = 0
        while removeCount < purgeableCount,
              now - self.committedWordTimestamps[removeCount] > self.offScreenRetentionInterval
        {
            removeCount += 1
        }
        guard removeCount > 0 else { return }

        self.committedWords.removeFirst(removeCount)
        self.committedWordTimestamps.removeFirst(removeCount)
    }

    private func currentVisibleWordWindow() -> Int {
        let maxLines = max(min(SettingsStore.shared.liveCaptionsMaxLines, 6), 1)
        return max(60, maxLines * 12)
    }

    /// Renders the full (purge-trimmed) committed buffer rather than a
    /// tight suffix window recalculated every tick — the previous
    /// suffix(committedNeeded) approach shifted the string's starting word
    /// on nearly every tick (as pendingCount fluctuated), which reflowed
    /// SwiftUI's word-wrap for the entire visible block, not just the new
    /// word. Purging is comparatively rare (only once ~10s-old words have
    /// also scrolled off screen), so this is far more stable in practice.
    private func updateRenderedText() {
        let newCommittedText = Self.joinWithSentenceBreaks(self.committedWords)
        let newPendingText = Self.joinWithSentenceBreaks(self.pendingWords)
        let newPendingStartsNewLine = self.committedWords.last.map(Self.endsSentence) ?? false

        if newCommittedText != self.renderedCommittedText {
            self.renderedCommittedText = newCommittedText
        }
        if newPendingText != self.renderedPendingText {
            self.renderedPendingText = newPendingText
        }
        if newPendingStartsNewLine != self.pendingStartsNewLine {
            self.pendingStartsNewLine = newPendingStartsNewLine
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }

    /// Joins words with a space, except a hard line break after a word that
    /// ends a sentence — so completed sentences occupy their own frozen
    /// line and only the currently-forming sentence can still wrap/move.
    private static func joinWithSentenceBreaks(_ words: [String]) -> String {
        var result = ""
        for (index, word) in words.enumerated() {
            if index > 0 {
                result += Self.endsSentence(words[index - 1]) ? "\n" : " "
            }
            result += word
        }
        return result
    }

    /// True if a word ends a sentence (., !, or ?), tolerating trailing
    /// closing quotes/brackets. Doesn't attempt to handle abbreviations
    /// ("Mr.", "e.g.") — an occasional false-positive line break there is
    /// an acceptable trade-off for not reflowing already-shown lines.
    private static func endsSentence(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]}\u{201D}\u{2019}\u{00BB}"))
        guard let last = trimmed.last else { return false }
        return last == "." || last == "!" || last == "?"
    }
}
