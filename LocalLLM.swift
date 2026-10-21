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
        Add correct punctuation and capitalisation, correct words that are clearly misheard when the context makes the right word certain, \
        remove stutters and accidental repeats such as "the the", and divide the text into paragraphs where the topic or the thought changes; \
        let the text itself decide how long each paragraph is. \
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

    private static func complete(_ model: LocalModel, system: String, user: String, temperature: Double) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(model.port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model.name, "temperature": temperature, "stream": false, "reasoning_effort": "none",
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
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

    /// Words reduced for comparison: lower case, no punctuation, hyphens and dashes as spaces.
    static func tokens(_ text: String) -> [String] {
        text.replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "[-–—_]", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .map { String($0.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }) }
            .filter { !$0.isEmpty }
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

    /// Finds where each paragraph of the answer ends in the window, by matching the paragraph's last
    /// words, so that the next window can start at the next word. Reading stops at the first paragraph
    /// that does not begin where the last one ended, or whose last words cannot be found, or whose
    /// length differs from the text it covers by more than 30%. `owner` maps each token to its word.
    static func align(_ paragraphs: [String], wtoks: [String], owner: [Int]) -> [(text: String, endWord: Int)] {
        var result: [(text: String, endWord: Int)] = []
        var prev = 0
        for text in paragraphs {
            let p = tokens(text)
            guard p.count >= 3, prev < wtoks.count else { break }
            let head = p.prefix(4)
            let near = Set(wtoks[prev..<min(prev + 10, wtoks.count)])
            guard head.filter({ near.contains($0) }).count >= min(2, head.count) else { break }
            let k = min(6, p.count)
            let tail = Array(p.suffix(k))
            let lo = max(prev + k - 1, prev + Int(0.7 * Double(p.count)) - 1)
            let hi = min(wtoks.count - 1, prev + Int(1.35 * Double(p.count)) + 2)
            guard lo <= hi else { break }
            var best = -1
            var bestScore = -1
            var bestDistance = Int.max
            for j in lo...hi {
                var score = 0
                for t in 0..<k where wtoks[j - k + 1 + t] == tail[t] { score += 1 }
                let distance = abs((j - prev + 1) - p.count)
                if score > bestScore || (score == bestScore && distance < bestDistance) {
                    best = j; bestScore = score; bestDistance = distance
                }
            }
            guard best >= 0, bestScore >= max(3, k - 2) else { break }
            let ratio = Double(p.count) / Double(best - prev + 1)
            guard ratio >= 0.7, ratio <= 1.3 else { break }
            result.append((text, owner[best]))
            prev = best + 1
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
                accepted = align(paragraphs(of: answer), wtoks: wtoks, owner: owner)
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
            }
            pos += used
            await onProgress(parts, pos, words.count)
        }
        return fallbacks
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
