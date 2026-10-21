// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// One segment of whisper's output, with its times in the audio.
struct SessionSegment: Codable, Equatable {
    var start: Double
    var end: Double
    var text: String
}

/// One paragraph of the polished text. `fallback` marks words kept as transcribed.
struct SessionPart: Codable, Equatable {
    var text: String
    var fallback: Bool
    var startWord: Int?   // the original words this paragraph covers, when known
    var endWord: Int?
}

/// Everything about one transcription that is saved in `session.json`. Reading a saved session
/// back uses this, so the text is shown as it was saved.
struct SessionInfo: Codable {
    static let marker = "Transcriber"
    static let currentFormat = 1

    struct Source: Codable {
        var file: String
        var bytes: Int64
        var audioSeconds: Double?
    }
    struct Whisper: Codable {
        var model: String
        var engine: String
        var carriesContext: Bool
    }
    struct Timings: Codable {
        var transcribeSeconds: Double?
        var polishSeconds: Double?
        var summarySeconds: Double?
        var descriptionSeconds: Double?
    }
    struct Polish: Codable {
        var model: String
        var paragraphs: [SessionPart]
    }
    struct Summary: Codable {
        var model: String
        var description: String
        var body: String
    }

    var app = SessionInfo.marker
    var format = SessionInfo.currentFormat
    var appVersion: String
    var created: String
    var source: Source
    var whisper: Whisper
    var timings: Timings
    var transcript: String
    var segments: [SessionSegment]
    var polish: Polish?
    var summary: Summary?
}

/// Saving a session as a zip, and reading one back. The zip holds `session.json`, the text as plain
/// files (`transcript.txt`, `polished.txt`, `summary.txt`) for other editors, and the whole original
/// file under `original/`. It is made with the system's `zip`, `unzip` and `ditto`.
enum SessionArchive {
    enum Failure: LocalizedError {
        case notASession(String), failed(String)
        var errorDescription: String? {
            switch self { case .notASession(let s), .failed(let s): return s }
        }
    }

    static let jsonName = "session.json"
    static let textNames = ["transcript.txt", "polished.txt", "summary.txt"]
    static let originalFolder = "original/"

    @discardableResult
    private static func run(_ exe: String, _ args: [String], in directory: URL? = nil) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = directory
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw Failure.failed("\(URL(fileURLWithPath: exe).lastPathComponent) exited with status \(p.terminationStatus).")
        }
        return data
    }

    /// Writes the zip. The original file is stored as it is, not recompressed (video is already compressed),
    /// and is read through a link, so no second copy of it is made.
    static func save(_ info: SessionInfo, original: URL, to destination: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("transcriber-session-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(info).write(to: work.appendingPathComponent(jsonName))
        var files = [jsonName]
        func text(_ name: String, _ body: String) throws {
            try body.write(to: work.appendingPathComponent(name), atomically: true, encoding: .utf8)
            files.append(name)
        }
        try text("transcript.txt", info.transcript)
        if let polish = info.polish { try text("polished.txt", polish.paragraphs.map(\.text).joined(separator: "\n\n")) }
        if let summary = info.summary { try text("summary.txt", summary.description + "\n\n" + summary.body) }

        let folder = work.appendingPathComponent("original")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = original.lastPathComponent
        try fm.createSymbolicLink(at: folder.appendingPathComponent(name), withDestinationURL: original)

        try? fm.removeItem(at: destination)
        try run("/usr/bin/zip", ["-q", "-9", "-X", destination.path] + files, in: work)
        try run("/usr/bin/zip", ["-q", "-0", "-X", destination.path, originalFolder + name], in: work)
    }

    /// Reads `session.json` from a zip, after checking that the zip has the shape of a saved session:
    /// the JSON file, only the files this app writes, and one original file.
    static func open(_ zip: URL) throws -> SessionInfo {
        let listing = String(decoding: try run("/usr/bin/unzip", ["-Z1", zip.path]), as: UTF8.self)
        let names = listing.split(separator: "\n").map(String.init)
        guard names.contains(jsonName) else { throw Failure.notASession("This zip file was not made by Transcriber.") }
        let allowed = Set([jsonName] + textNames)
        let originals = names.filter { $0.hasPrefix(originalFolder) && !$0.hasSuffix("/") }
        let unexpected = names.filter { !allowed.contains($0) && !$0.hasPrefix(originalFolder) }
        guard unexpected.isEmpty, originals.count == 1 else {
            throw Failure.notASession("This zip file was not made by Transcriber.")
        }
        let data = try run("/usr/bin/unzip", ["-p", zip.path, jsonName])
        let info: SessionInfo
        do { info = try JSONDecoder().decode(SessionInfo.self, from: data) }
        catch { throw Failure.notASession("This zip file was not made by Transcriber.") }
        guard info.app == SessionInfo.marker else { throw Failure.notASession("This zip file was not made by Transcriber.") }
        guard info.format <= SessionInfo.currentFormat else {
            throw Failure.notASession("This session was saved by a newer version of Transcriber. Update the app to open it.")
        }
        return info
    }

    /// Extracts the whole zip into `directory` and returns the original file inside it. Used when a session
    /// that was opened from a zip is saved again.
    static func extractOriginal(from zip: URL, into directory: URL) throws -> URL {
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        let folder = directory.appendingPathComponent("original")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        guard let file = files.first else { throw Failure.failed("The saved session has no original file.") }
        return file
    }
}
