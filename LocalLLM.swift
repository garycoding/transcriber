// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// A model offered by a server running on this Mac. Only 127.0.0.1 is ever contacted.
struct LocalModel: Identifiable, Hashable {
    enum Server: String { case lmStudio = "LM Studio", ollama = "Ollama", llamaCpp = "llama.cpp" }
    let server: Server
    let port: Int
    let name: String
    var id: String { "\(server.rawValue)|\(name)" }
    var label: String { "\(server.rawValue): \(name)" }
}

/// One paragraph of the polished text. `fallback` marks words kept as transcribed.
struct PolishPart: Equatable {
    let text: String
    let fallback: Bool
}

enum LocalLLM {
    /// The instruction for one call. Every call is a fresh conversation about one window of the transcript.
    static func systemPrompt(unpunctuated: Bool) -> String {
        let edges = unpunctuated
            ? "The text has little or no punctuation, so find its sentences yourself. It ends in the middle of a sentence: leave that unfinished last sentence out of your answer."
            : "The text begins at the start of a sentence and ends at the end of a sentence."
        return """
        You edit machine-made transcripts of speech. Keep the speaker's words and meaning. \
        Add correct punctuation and capitalisation. Correct a word only when it is not a real word, or when the sentence makes no sense without the change; \
        if you are unsure, keep the original word. \
        Remove stutters and accidental repeats such as "the the", and divide the text into paragraphs where the topic or the thought changes; \
        let the text itself decide how long each paragraph is. \
        Keep any notes about sounds that are already in the text, in brackets or parentheses, such as [LAUGHTER], (audience laughing) or [INAUDIBLE], exactly as they are and where they are. \
        Never write a note of your own, and never replace the speaker's words with one: if the speaker says "inaudible", write the word. \
        Do not summarise, shorten, add, explain or comment. \
        Write plain text only: no LaTeX, no Markdown, no symbols or special formatting. Where a formula is spoken, write it out as the words that were said. \
        Write a blank line between paragraphs. \(edges)
        """
    }

    static let windowWords = 500
    static let maxWindowWords = 900

    /// The servers that are looked for, on their default ports.
    static func discover() async -> [LocalModel] {
        await withTaskGroup(of: [LocalModel].self) { group in
            group.addTask { await probe(.lmStudio, 1234, "/v1/models", "data", "id") }
            group.addTask { await probe(.ollama, 11434, "/api/tags", "models", "name") }
            group.addTask { await probe(.llamaCpp, 8080, "/v1/models", "data", "id") }
            var all: [LocalModel] = []
            for await found in group { all += found }
            return all.sorted { $0.id < $1.id }
        }
    }

    private static func probe(_ server: LocalModel.Server, _ port: Int, _ path: String,
                              _ listKey: String, _ nameKey: String) async -> [LocalModel] {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json[listKey] as? [[String: Any]] else { return [] }
        return list.compactMap { $0[nameKey] as? String }
            .filter { !$0.lowercased().contains("embed") }
            .map { LocalModel(server: server, port: port, name: $0) }
    }

    private static func complete(_ model: LocalModel, system: String, user: String, temperature: Double,
                                maxTokens: Int? = nil) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(model.port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": model.name, "temperature": temperature, "stream": false, "reasoning_effort": "none",
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw TranscribeError.failed("\(model.server.rawValue) answered with an error.")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranscribeError.failed("\(model.server.rawValue) sent an answer the app could not read.")
        }
        return content
    }

    /// Removes a reasoning model's <think> block and any code fence around the answer.
    static func clean(_ answer: String) -> String {
        var s = answer
        if let r = s.range(of: #"<think>[\s\S]*?</think>"#, options: .regularExpression) { s.removeSubrange(r) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.drop(while: { $0 != "\n" }).dropFirst().description
            if let r = s.range(of: "```", options: .backwards) { s.removeSubrange(r.lowerBound...) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Sentences and windows

    private static let notSentenceEnds: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "st.", "vs.", "prof.", "no.", "etc."]

    /// Whether a word ends a sentence: it ends in . ? or !, perhaps followed by a closing quote or bracket.
    static func sentenceEnd(_ word: String) -> Bool {
        if notSentenceEnds.contains(word.lowercased()) { return false }
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')]”’"))
        guard let last = trimmed.last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// The next window: it starts at `pos`, which is the start of a sentence, and ends at a sentence
    /// end near `windowWords` words on, looking back no further than 40% of the window and forward no
    /// further than `maxWindowWords`. Only when there is no sentence end in all that is the window cut
    /// at the target, and `unpunctuated` is set. `end` is exclusive.
    static func window(_ words: [String], from pos: Int) -> (end: Int, unpunctuated: Bool) {
        let total = words.count
        if total - pos <= windowWords + 100 { return (total, false) }
        let target = pos + windowWords
        var e = target
        while e > pos + windowWords * 2 / 5 {
            if sentenceEnd(words[e - 1]) { return (e, false) }
            e -= 1
        }
        e = target + 1
        while e <= min(pos + maxWindowWords, total) {
            if sentenceEnd(words[e - 1]) { return (e, false) }
            e += 1
        }
        return (target, true)
    }

    // MARK: Matching the answer to the text

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
        "sixteen": "16", "seventeen": "17", "eighteen": "18", "nineteen": "19", "twenty": "20",
    ]

    /// Words reduced for comparison: lower case, no accents or punctuation, hyphens and dashes as spaces,
    /// and spoken numbers (one to twenty) as digits, so that "Poincaré" matches "Poincare" and "two" matches "2".
    static func tokens(_ text: String) -> [String] {
        text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[-–—_]", with: " ", options: .regularExpression)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .map { String($0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }) }
            .filter { !$0.isEmpty }
            .map { numberWords[$0] ?? $0 }
    }

    /// The paragraphs of an answer: runs of lines between blank lines.
    static func paragraphs(of answer: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for raw in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: " ")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: " ")) }
        return out
    }

    /// Finds where each paragraph of the answer ends in the window, so that the next window can start
    /// at the next word. A paragraph's end is a place where its last three words are the window's
    /// words at that place, and where most of its last ten words are found just before it, so that a
    /// word the model dropped or changed earlier in the paragraph does not matter. Failing that, the
    /// last two words must match and most of the last ten be found. Reading stops at the first
    /// paragraph that does not begin where the last one ended, whose end cannot be found, or whose
    /// length differs from the text it covers by more than 30%. `owner` maps each token to its word.
    static func align(_ paragraphs: [String], wtoks: [String], owner: [Int], final: Bool = false) -> [(text: String, endWord: Int)] {
        var result: [(text: String, endWord: Int)] = []
        var prev = 0
        for text in paragraphs {
            let p = tokens(text)
            guard p.count >= 1, prev < wtoks.count else { break }
            let head = p.prefix(4)
            let near = Set(wtoks[prev..<min(prev + 10, wtoks.count)])
            guard head.filter({ near.contains($0) }).count >= min(2, head.count) else { break }
            let lo = max(prev + min(p.count, 3) - 1, prev + Int(0.7 * Double(p.count)) - 1)
            let hi = min(wtoks.count - 1, prev + Int(1.35 * Double(p.count)) + 2)
            guard lo <= hi else { break }
            let tail = Array(p.suffix(min(10, p.count)))
            var best = -1
            var bestScore = -1.0
            var bestDistance = Int.max
            for exact in Array(Set([min(p.count, 3), min(p.count, 2)])).sorted(by: >) {
                for j in lo...hi where j - exact + 1 >= prev {
                    var matches = true
                    for t in 0..<exact where wtoks[j - t] != p[p.count - 1 - t] { matches = false; break }
                    guard matches else { continue }
                    let before = Set(wtoks[max(prev, j - 11)...j])
                    let found = Double(tail.filter { before.contains($0) }.count) / Double(tail.count)
                    guard found >= (exact == 3 ? 0.6 : 0.7) else { continue }
                    let distance = abs((j - prev + 1) - p.count)
                    if found > bestScore + 0.001 || (abs(found - bestScore) <= 0.001 && distance < bestDistance) {
                        best = j; bestScore = found; bestDistance = distance
                    }
                }
                if best >= 0 { break }
            }
            guard best >= 0 else { break }
            let ratio = Double(p.count) / Double(best - prev + 1)
            guard ratio >= 0.7, ratio <= 1.3 else { break }
            result.append((text, owner[best]))
            prev = best + 1
        }
        // The last window of the text: an answer whose paragraphs, from where matching stopped, are about as long
        // as all the text that is left is taken to cover it, even if the model reworded its last words.
        if final, result.count < paragraphs.count, prev < wtoks.count {
            let rest = Array(paragraphs[result.count...])
            let n = rest.reduce(0) { $0 + tokens($1).count }
            let remaining = wtoks.count - prev
            let head = tokens(rest[0]).prefix(4)
            let near = Set(wtoks[prev..<min(prev + 10, wtoks.count)])
            if Double(n) >= 0.75 * Double(remaining), Double(n) <= 1.25 * Double(remaining),
               head.filter({ near.contains($0) }).count >= min(2, head.count) {
                result.append((rest.joined(separator: " "), owner[wtoks.count - 1]))
            }
        }
        return result
    }

    // MARK: The log of rejected answers

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Transcriber/polish-rejected.log")

    /// Records an answer that could not be used, on this Mac only, so that it can be looked at.
    static func logRejected(_ model: LocalModel, attempt: Int, sent: [String], answer: String) {
        let entry = """
        == \(ISO8601DateFormatter().string(from: Date())) \(model.label), attempt \(attempt): no paragraph of the answer matched the text
        -- sent (\(sent.count) words), the first 60:
        \(sent.prefix(60).joined(separator: " "))
        -- answer:
        \(answer.prefix(6000))


        """
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        } else {
            try? entry.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: The polish

    /// Polishes the transcript by repeated, independent calls. Each call is given a window that begins
    /// and ends at sentence ends and returns the window as paragraphs of the model's own choosing.
    /// Each paragraph is matched to the original words; the last one is left for the next call, since
    /// the thought may continue, and the next window starts at the word after the last one kept. An
    /// answer with no usable paragraph is asked for once more. If that fails too, whole sentences of
    /// the original are kept as transcribed and marked as such. Returns how many times that happened.
    static func polish(_ text: String, with model: LocalModel,
                       onProgress: @MainActor @escaping (_ parts: [PolishPart], _ consumedWords: Int, _ totalWords: Int) -> Void) async throws -> Int {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var pos = 0
        var fallbacks = 0
        while pos < words.count {
            try Task.checkCancellation()
            let (end, unpunctuated) = window(words, from: pos)
            let slice = Array(words[pos..<end])
            var wtoks: [String] = []
            var owner: [Int] = []
            for (i, word) in slice.enumerated() {
                for token in tokens(word) { wtoks.append(token); owner.append(i) }
            }
            let final = end >= words.count
            var accepted: [(text: String, endWord: Int)] = []
            for attempt in 1...2 {
                let answer = clean(try await complete(model, system: systemPrompt(unpunctuated: unpunctuated),
                                                      user: slice.joined(separator: " "), temperature: attempt == 1 ? 0.2 : 0.6))
                accepted = align(paragraphs(of: answer), wtoks: wtoks, owner: owner, final: final)
                if !accepted.isEmpty { break }
                logRejected(model, attempt: attempt, sent: slice, answer: answer)
            }
            var parts: [PolishPart]
            var used: Int
            if accepted.isEmpty {
                var n = min(slice.count, 120)
                if slice.count > 100, let e = (100...min(slice.count, 250)).first(where: { sentenceEnd(slice[$0 - 1]) }) { n = e }
                parts = [PolishPart(text: slice[0..<n].joined(separator: " "), fallback: true)]
                used = n
                fallbacks += 1
            } else {
                var kept = accepted
                if !final, kept.count > 1 { kept.removeLast() }
                parts = kept.map { PolishPart(text: $0.text, fallback: false) }
                used = kept.last!.endWord + 1
                if final, slice.count - used > 0, slice.count - used < 40 {
                    // Too small to be a window of its own: keep these last words, as transcribed, with the last paragraph.
                    parts[parts.count - 1] = PolishPart(text: parts[parts.count - 1].text + " " + slice[used...].joined(separator: " "),
                                                        fallback: false)
                    used = slice.count
                }
            }
            pos += used
            await onProgress(parts, pos, words.count)
        }
        return fallbacks
    }

    // MARK: The summary

    private static let summaryBase = "You summarise a spoken recording. Write plain text only, no Markdown. State only what the text says; do not add facts, names or figures that are not in it. "
    private static let partPrompt = summaryBase + "You are given notes on the earlier parts of the recording, then a new part. Use the notes only to understand the new part. Summarise only the new part, in three or four sentences, and do not repeat the notes."
    private static let finalPrompt = summaryBase + "You are given summaries of consecutive parts of one recording, in order. Write one summary of the whole recording in two or three short paragraphs, keeping its order and saying how it ends."
    private static let condensePrompt = summaryBase + "Condense these notes on a recording to about 300 words, keeping their order."
    private static let descriptionPrompt = "You label recordings. Given a summary of a recording, write one very short description of what it is, in the form of these examples: \"A presentation about quarterly profits\", \"A physics lecture on dark matter\", \"A sales pitch for toothpaste\". Write only the description, as one line, without a full stop and without quotation marks. Say only what the text supports."

    private static func wordCount(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// The text in blocks of about `target` words, cut between paragraphs. A text with no paragraph
    /// breaks is cut at sentence ends instead.
    static func blocks(of text: String, target: Int = 1000) -> [String] {
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if paragraphs.count == 1, wordCount(paragraphs[0]) > target * 3 / 2 {
            let words = paragraphs[0].split(whereSeparator: \.isWhitespace).map(String.init)
            var out: [String] = []
            var pos = 0
            while pos < words.count {
                var end = words.count
                if words.count - pos > target * 3 / 2 {
                    end = pos + target
                    var e = end
                    while e > pos + target / 2, !sentenceEnd(words[e - 1]) { e -= 1 }
                    if sentenceEnd(words[e - 1]) { end = e }
                }
                out.append(words[pos..<end].joined(separator: " "))
                pos = end
            }
            return out
        }
        var out: [String] = []
        var current: [String] = []
        var n = 0
        for p in paragraphs {
            current.append(p)
            n += wordCount(p)
            if n >= target { out.append(current.joined(separator: "\n\n")); current = []; n = 0 }
        }
        if !current.isEmpty {
            if n < target * 2 / 5, !out.isEmpty { out[out.count - 1] += "\n\n" + current.joined(separator: "\n\n") }
            else { out.append(current.joined(separator: "\n\n")) }
        }
        return out
    }

    /// Summarises the text in independent calls: each block of about 1,000 words is summarised with the
    /// summaries of the blocks before it as notes, then the block summaries are summarised as a whole,
    /// and a one-line description is written from that. `onProgress` is given steps done of steps in all.
    static func summarise(_ text: String, with model: LocalModel,
                          onProgress: @MainActor @escaping (_ done: Int, _ total: Int) -> Void) async throws
        -> (description: String, summary: String, summarySeconds: Double, descriptionSeconds: Double) {
        let started = Date()
        let parts = blocks(of: text)
        let total = parts.count + 2
        var sums: [String] = []
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            var notes = sums.joined(separator: " ")
            if wordCount(notes) > 700 {
                notes = try await complete(model, system: condensePrompt, user: notes, temperature: 0.2, maxTokens: 600)
                sums = [notes]
            }
            let user = (notes.isEmpty ? "New part (the first):\n" : "Notes on the earlier parts:\n\(notes)\n\nNew part:\n") + part
            sums.append(try await complete(model, system: partPrompt, user: user, temperature: 0.2, maxTokens: 700))
            await onProgress(i + 1, total)
        }
        try Task.checkCancellation()
        let summary = parts.count == 1 ? sums[0]
            : try await complete(model, system: finalPrompt,
                                 user: sums.enumerated().map { "Part \($0.offset + 1): \($0.element)" }.joined(separator: "\n\n"),
                                 temperature: 0.2, maxTokens: 900)
        await onProgress(parts.count + 1, total)
        try Task.checkCancellation()
        let summarySeconds = Date().timeIntervalSince(started)
        let descriptionStarted = Date()
        var description = try await complete(model, system: descriptionPrompt, user: summary, temperature: 0.2, maxTokens: 60)
        description = description.split(separator: "\n").first.map(String.init) ?? description
        description = description.trimmingCharacters(in: CharacterSet(charactersIn: " \"'.")).trimmingCharacters(in: .whitespaces)
        await onProgress(total, total)
        return (description, summary, summarySeconds, Date().timeIntervalSince(descriptionStarted))
    }
}

/// The local models found on this Mac, and the user's choice among them.
@MainActor final class LocalModels: ObservableObject {
    @Published var found: [LocalModel] = []
    @Published var searching = false
    @Published var selectedID: String {
        didSet { UserDefaults.standard.set(selectedID, forKey: "polishModel") }
    }

    init() {
        selectedID = UserDefaults.standard.string(forKey: "polishModel") ?? ""
        refresh()
    }

    func refresh() {
        searching = true
        Task {
            found = await LocalLLM.discover()
            searching = false
        }
    }
}
