// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Links a moment in the audio to places in the two texts, and back. The "As transcribed" text is whisper's
/// segments joined by spaces, so each word of it has a time, worked out from its segment's start and end.
/// The polished text is paragraphs, each covering a span of the original words (kept when the polish was
/// made, or estimated from the paragraph lengths for a session saved without them), and within a
/// paragraph the sentences share that span in proportion to their length. Positions are UTF-16 offsets,
/// as an NSTextView uses.
struct PlaybackMap {
    struct Paragraph {
        let range: NSRange        // in the polished pane's text
        let startWord: Int        // first original word it covers
        let endWord: Int          // one past the last
        let sentences: [NSRange]  // relative to the paragraph
        let fractions: [Double]   // where each sentence ends, as a share of the paragraph; the last is 1
    }

    let totalWords: Int
    let paragraphs: [Paragraph]
    private let wordStarts: [Int]
    private let segStart: [Double]
    private let segEnd: [Double]
    private let segFirstWord: [Int]
    private let segCount: [Int]
    private let sentences: [NSRange]
    private let sentenceFirstWord: [Int]

    /// `parts` are the polished paragraphs, with the original words each covers when they are known.
    init(text: String, segments: [SessionSegment], parts: [(text: String, startWord: Int?, endWord: Int?)]) {
        // The words of the original text, and where each begins.
        var starts: [Int] = []
        var offset = 0
        var inWord = false
        for ch in text {
            if ch.isWhitespace { inWord = false } else if !inWord { starts.append(offset); inWord = true }
            offset += ch.utf16.count
        }
        wordStarts = starts
        totalWords = starts.count

        // The first word of each segment.
        var firsts: [Int] = []
        var counts: [Int] = []
        var sum = 0
        for s in segments {
            let n = s.text.split(whereSeparator: \.isWhitespace).count
            firsts.append(sum)
            counts.append(n)
            sum += n
        }
        if sum != starts.count && sum > 0 {
            // The segments do not add up to the text (it should never happen): share the words in proportion.
            let scale = Double(starts.count) / Double(sum)
            firsts = firsts.map { Int(Double($0) * scale) }
            var scaled: [Int] = []
            for i in 0..<firsts.count { scaled.append((i + 1 < firsts.count ? firsts[i + 1] : starts.count) - firsts[i]) }
            counts = scaled
        }
        segFirstWord = firsts
        segCount = counts
        segStart = segments.map(\.start)
        segEnd = segments.map(\.end)

        // The sentences of the original text.
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .bySentences) { _, r, _, _ in
            var end = r.location + r.length
            while end > r.location, let u = UnicodeScalar(ns.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { end -= 1 }
            if end > r.location { ranges.append(NSRange(location: r.location, length: end - r.location)) }
        }
        sentences = ranges
        sentenceFirstWord = ranges.map { r in
            var lo = 0, hi = starts.count
            while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < r.location { lo = mid + 1 } else { hi = mid } }
            return min(lo, max(0, starts.count - 1))
        }

        // The polished paragraphs.
        let polishedWords = parts.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
        var paras: [Paragraph] = []
        var location = 0
        var cumulative = 0
        var previousEnd = 0
        for part in parts {
            let words = part.text.split(whereSeparator: \.isWhitespace).count
            cumulative += words
            let length = (part.text as NSString).length
            var start = part.startWord ?? previousEnd
            var end = part.endWord ?? (polishedWords > 0 ? Int((Double(cumulative) / Double(polishedWords) * Double(starts.count)).rounded()) : starts.count)
            start = max(0, min(start, starts.count))
            end = max(start, min(end, starts.count))
            let pns = part.text as NSString
            var sents: [NSRange] = []
            pns.enumerateSubstrings(in: NSRange(location: 0, length: pns.length), options: .bySentences) { _, r, _, _ in
                var e = r.location + r.length
                while e > r.location, let u = UnicodeScalar(pns.character(at: e - 1)), CharacterSet.whitespacesAndNewlines.contains(u) { e -= 1 }
                if e > r.location { sents.append(NSRange(location: r.location, length: e - r.location)) }
            }
            if sents.isEmpty { sents = [NSRange(location: 0, length: length)] }
            let sentenceWords = sents.map { max(1, pns.substring(with: $0).split(whereSeparator: \.isWhitespace).count) }
            let total = Double(sentenceWords.reduce(0, +))
            var run = 0.0
            let fractions = sentenceWords.map { w -> Double in run += Double(w); return run / total }
            paras.append(Paragraph(range: NSRange(location: location, length: length), startWord: start, endWord: end,
                                   sentences: sents, fractions: fractions))
            location += length + 2
            previousEnd = end
        }
        paragraphs = paras
    }

    // MARK: Time and words

    /// The original word being spoken at a time.
    func word(atTime t: Double) -> Int {
        guard !segStart.isEmpty, totalWords > 0 else { return 0 }
        var lo = 0, hi = segStart.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if segStart[mid] <= t { lo = mid } else { hi = mid - 1 } }
        let span = max(segEnd[lo] - segStart[lo], 0.001)
        let fraction = min(max((t - segStart[lo]) / span, 0), 0.999)
        return min(totalWords - 1, segFirstWord[lo] + Int(fraction * Double(max(segCount[lo], 1))))
    }

    /// The time at which an original word begins.
    func time(forWord w: Int) -> Double {
        guard !segStart.isEmpty else { return 0 }
        var lo = 0, hi = segFirstWord.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if segFirstWord[mid] <= w { lo = mid } else { hi = mid - 1 } }
        let fraction = Double(w - segFirstWord[lo]) / Double(max(segCount[lo], 1))
        return segStart[lo] + min(max(fraction, 0), 1) * (segEnd[lo] - segStart[lo])
    }

    /// The time in the middle of an original word. Seeking here, and not to the word's start, means that finding the
    /// word again from the time gives the same word.
    func time(atMiddleOfWord w: Int) -> Double {
        guard !segStart.isEmpty else { return 0 }
        var lo = 0, hi = segFirstWord.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if segFirstWord[mid] <= w { lo = mid } else { hi = mid - 1 } }
        let fraction = (Double(w - segFirstWord[lo]) + 0.5) / Double(max(segCount[lo], 1))
        return segStart[lo] + min(max(fraction, 0), 1) * (segEnd[lo] - segStart[lo])
    }

    // MARK: Search

    /// The matches of a query in a text, ignoring case and accents.
    static func matches(of query: String, in text: String) -> [NSRange] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let ns = text as NSString
        var found: [NSRange] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound || r.length == 0 { break }
            found.append(r)
            from = r.location + r.length
        }
        return found
    }

    /// Which match to go to: the one after (or before) the current match, or, when none is current, the first at or after
    /// the place being played (the last before it, going backwards). The search wraps round.
    func matchIndex(in matches: [NSRange], current: Int?, direction: Int, atTime t: Double) -> Int? {
        guard !matches.isEmpty else { return nil }
        let n = matches.count
        if let current { return (current + direction + n) % n }
        let here = leftOffset(ofWord: word(atTime: t))
        if direction >= 0 { return matches.firstIndex(where: { $0.location >= here }) ?? 0 }
        return matches.lastIndex(where: { $0.location < here }) ?? n - 1
    }

    // MARK: The original text

    /// The character position at which an original word begins.
    func leftOffset(ofWord w: Int) -> Int {
        guard !wordStarts.isEmpty else { return 0 }
        return wordStarts[min(max(w, 0), wordStarts.count - 1)]
    }

    /// The sentence of the original text that holds a word.
    func leftSentence(forWord w: Int) -> NSRange? {
        guard !sentences.isEmpty else { return nil }
        var lo = 0, hi = sentences.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if sentenceFirstWord[mid] <= w { lo = mid } else { hi = mid - 1 } }
        return sentences[lo]
    }

    /// The word at a character position of the original text.
    func word(forLeftCharacter i: Int) -> Int {
        guard !wordStarts.isEmpty else { return 0 }
        var lo = 0, hi = wordStarts.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if wordStarts[mid] <= i { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    // MARK: The polished text

    /// The sentence of the polished text that corresponds to an original word, in the polished pane's text.
    func rightSentence(forWord w: Int) -> NSRange? {
        guard !paragraphs.isEmpty else { return nil }
        var index = paragraphs.count - 1
        for (k, p) in paragraphs.enumerated() where w < p.endWord { index = k; break }
        let p = paragraphs[index]
        let fraction = (Double(w - p.startWord) + 0.5) / Double(max(1, p.endWord - p.startWord))
        let j = p.fractions.firstIndex(where: { $0 >= fraction }) ?? (p.sentences.count - 1)
        let s = p.sentences[min(j, p.sentences.count - 1)]
        return NSRange(location: p.range.location + s.location, length: s.length)
    }

    /// The original word at the start of the polished sentence at a character position of the polished text.
    func word(forRightCharacter i: Int) -> Int? {
        guard !paragraphs.isEmpty else { return nil }
        var index = paragraphs.count - 1
        for (k, p) in paragraphs.enumerated() where i < p.range.location + p.range.length + 2 { index = k; break }
        let p = paragraphs[index]
        let relative = max(0, min(i - p.range.location, p.range.length))
        var j = p.sentences.count - 1
        for (k, s) in p.sentences.enumerated() where relative < s.location + s.length + 1 { j = k; break }
        let startFraction = j == 0 ? 0 : p.fractions[j - 1]
        return min(max(p.startWord + Int((startFraction * Double(p.endWord - p.startWord)).rounded()), 0), max(totalWords - 1, 0))
    }
}
