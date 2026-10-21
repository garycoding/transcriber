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

enum LocalLLM {
    /// The instruction for one call. Every call is a fresh conversation about a window of the transcript.
    static func systemPrompt(final: Bool) -> String {
        """
        You edit machine-made transcripts of speech. Keep the speaker's words and meaning. \
        Add correct punctuation and capitalisation, correct words that are clearly misheard when the context makes the right word certain, \
        remove stutters and accidental repeats such as "the the", and divide the text into paragraphs where the topic or the thought changes. \
        Do not summarise, shorten, add, explain or comment. \
        The input lines are numbered; do not copy the numbers into the text. \
        \(final ? "Write all the paragraphs." : "The input is only the start of a longer transcript. Write only its first three paragraphs, and stop at the end of the third.") \
        Write a blank line between paragraphs. After each paragraph, on a line of its own, write [through N], where N is the number of the last input line that the paragraph covers.
        """
    }

    static let windowWords = 500

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

    private static func complete(_ model: LocalModel, system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(model.port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model.name, "temperature": 0.2, "stream": false, "reasoning_effort": "none",
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

    private static func words(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Reads the model's answer: paragraphs, each followed by a [through N] line. A paragraph is
    /// accepted only when N advances, stays inside the window, and the paragraph's length is within
    /// a quarter of the length of the lines it covers. Reading stops at the first paragraph that fails.
    static func parse(_ answer: String, window: [String], final: Bool) -> [(text: String, through: Int)] {
        let marker = try! NSRegularExpression(pattern: #"^\W*through\s+(\d+)\W*$"#, options: .caseInsensitive)
        var result: [(text: String, through: Int)] = []
        var buffer: [String] = []
        var previous = 0
        func accept(_ text: String, _ through: Int) -> Bool {
            guard through > previous, through <= window.count, !text.isEmpty else { return false }
            let source = words(window[previous..<through].joined(separator: " "))
            let n = words(text)
            guard Double(n) >= 0.75 * Double(source), Double(n) <= 1.25 * Double(source) else { return false }
            result.append((text, through))
            previous = through
            return true
        }
        for raw in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let m = marker.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let r = Range(m.range(at: 1), in: line), let n = Int(line[r]) {
                let text = buffer.joined(separator: " ")
                buffer = []
                if !accept(text, n) { return result }
            } else if !line.isEmpty {
                buffer.append(line)
            }
        }
        if final, previous < window.count, !buffer.isEmpty { _ = accept(buffer.joined(separator: " "), window.count) }
        return result
    }

    /// The transcript as numbered units for the model: its sentences, and any very long sentence
    /// cut into pieces of about forty words.
    static func lines(of text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            let w = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
            if w.count <= 80 { out.append(trimmed); return }
            for start in stride(from: 0, to: w.count, by: 40) {
                out.append(w[start..<min(start + 40, w.count)].joined(separator: " "))
            }
        }
        return out
    }

    /// Polishes the transcript by repeated, independent calls. Each call is given the next window
    /// of about `windowWords` words and returns its first paragraphs; those are kept, the lines
    /// they cover are stripped from the front, and the rest goes into the next call. A paragraph
    /// that reaches the end of the window may be cut off, so it is left for the next call unless it
    /// is the only one. When no paragraph of an answer can be trusted, the first lines of the window
    /// are kept as transcribed. Returns how many times that happened.
    static func polish(_ text: String, with model: LocalModel,
                       onProgress: @MainActor @escaping (_ newText: String, _ consumedWords: Int, _ totalWords: Int) -> Void) async throws -> Int {
        let lines = lines(of: text)
        let totalWords = max(1, lines.reduce(0) { $0 + words($1) })
        var index = 0
        var consumed = 0
        var kept = 0
        while index < lines.count {
            try Task.checkCancellation()
            var window: [String] = []
            var count = 0
            while index + window.count < lines.count, count < windowWords || window.isEmpty {
                let line = lines[index + window.count]
                window.append(line)
                count += words(line)
            }
            let final = index + window.count >= lines.count
            let numbered = window.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            let answer = clean(try await complete(model, system: systemPrompt(final: final), user: numbered))
            var taken = parse(answer, window: window, final: final)
            if !final, taken.count > 1, taken.last!.through == window.count { taken.removeLast() }
            if taken.isEmpty {
                var n = 0
                var w = 0
                while n < window.count, w < 150 || n == 0 { w += words(window[n]); n += 1 }
                taken = [(window[0..<n].joined(separator: " "), n)]
                kept += 1
            }
            let through = taken.last!.through
            consumed += words(window[0..<through].joined(separator: " "))
            index += through
            await onProgress(taken.map(\.text).joined(separator: "\n\n"), consumed, totalWords)
        }
        return kept
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
