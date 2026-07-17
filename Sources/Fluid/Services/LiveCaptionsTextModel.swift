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

    /// Full-session committed text, never mutated once written.
    private(set) var committedWords: [String] = []
    private var pendingWords: [String] = []
    private var stableTicks: [Int] = []

    /// Capped, most-recent-window projections actually consumed by the view.
    @Published private(set) var renderedCommittedText: String = ""
    @Published private(set) var renderedPendingText: String = ""

    private init() {}

    func ingest(_ partialText: String) {
        let newWords = Self.tokenize(partialText)

        let newTail: [String]
        if newWords.count > self.committedWords.count {
            newTail = Array(newWords[self.committedWords.count...])
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
            self.committedWords.append(contentsOf: remainingTail[0..<promoteCount])
            remainingTail.removeFirst(promoteCount)
            remainingTicks.removeFirst(promoteCount)
        }

        self.pendingWords = remainingTail
        self.stableTicks = remainingTicks

        self.updateRenderedText()
    }

    /// Promotes all pending words immediately, e.g. when recording stops so
    /// the final line isn't left half-dimmed.
    func flushAll() {
        guard !self.pendingWords.isEmpty else { return }
        self.committedWords.append(contentsOf: self.pendingWords)
        self.pendingWords = []
        self.stableTicks = []
        self.updateRenderedText()
    }

    /// Clears all captions state. Called at recording start only — captions
    /// accumulate for a whole session, not per-utterance.
    func reset() {
        self.committedWords = []
        self.pendingWords = []
        self.stableTicks = []
        self.renderedCommittedText = ""
        self.renderedPendingText = ""
    }

    private func updateRenderedText() {
        let maxLines = max(min(SettingsStore.shared.liveCaptionsMaxLines, 6), 1)
        let visibleWordWindow = max(60, maxLines * 12)

        let pendingCount = self.pendingWords.count
        let committedNeeded = max(0, visibleWordWindow - pendingCount)
        let committedSlice = self.committedWords.suffix(committedNeeded)

        let newCommittedText = committedSlice.joined(separator: " ")
        let newPendingText = self.pendingWords.joined(separator: " ")

        if newCommittedText != self.renderedCommittedText {
            self.renderedCommittedText = newCommittedText
        }
        if newPendingText != self.renderedPendingText {
            self.renderedPendingText = newPendingText
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func normalize(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters)
    }
}
