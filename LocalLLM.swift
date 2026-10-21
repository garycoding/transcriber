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
    static let systemPrompt = """
    You edit machine-made transcripts of speech. Keep the speaker's words and meaning. \
    Add correct punctuation and capitalisation, correct words that are clearly misheard when the context makes the right word certain, \
    remove stutters and accidental repeats such as "the the", and divide the text into paragraphs where the topic or the thought changes. \
    Do not summarise, shorten, add, explain or comment. \
    Reply with the edited text only, with a blank line between paragraphs.
    """

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

    /// Splits the transcript, at line ends, into pieces of about `maxWords` words.
    static func chunks(of text: String, maxWords: Int = 450) -> [String] {
        var out: [String] = []
        var current: [String] = []
        var count = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let n = line.split(whereSeparator: \.isWhitespace).count
            if count + n > maxWords && !current.isEmpty {
                out.append(current.joined(separator: "\n"))
                current = []
                count = 0
            }
            current.append(String(line))
            count += n
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    private static func complete(_ model: LocalModel, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(model.port)/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model.name, "temperature": 0.2, "stream": false,
            "messages": [["role": "system", "content": systemPrompt], ["role": "user", "content": user]],
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

    /// Polishes the transcript piece by piece. A piece whose answer differs in length from
    /// the original by more than a fifth is not trusted and is kept as transcribed.
    static func polish(_ text: String, with model: LocalModel,
                       progress: @MainActor @escaping (Int, Int) -> Void) async throws -> (text: String, kept: Int) {
        let pieces = chunks(of: text)
        var result: [String] = []
        var kept = 0
        for (i, piece) in pieces.enumerated() {
            let original = piece.split(whereSeparator: \.isWhitespace).count
            let answer = clean(try await complete(model, user: piece))
            let words = answer.split(whereSeparator: \.isWhitespace).count
            if original > 0, Double(words) >= 0.8 * Double(original), Double(words) <= 1.25 * Double(original) {
                result.append(answer)
            } else {
                result.append(piece.replacingOccurrences(of: "\n", with: " "))
                kept += 1
            }
            await progress(i + 1, pieces.count)
        }
        return (result.joined(separator: "\n\n"), kept)
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
