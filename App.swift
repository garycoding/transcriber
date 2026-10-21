// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import CryptoKit

let modelFileName = "ggml-small.bin"
let modelBytes: Int64 = 487_601_967
let modelSHA256 = "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"
let modelSource = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!
let modelDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Transcriber")
let modelURL = modelDirectory.appendingPathComponent(modelFileName)

enum TranscribeError: LocalizedError {
    case missing(String), failed(String)
    var errorDescription: String? {
        switch self { case .missing(let s), .failed(let s): return s }
    }
}

func byteString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Fetches the speech model on first launch and reports progress to the UI.
final class ModelStore: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case ready
        case downloading(received: Int64, total: Int64)
        case verifying
        case failed(String)
    }

    @Published var state: State = .verifying
    private var session: URLSession?

    override init() {
        super.init()
        if let size = (try? FileManager.default.attributesOfItem(atPath: modelURL.path)[.size]) as? Int64, size == modelBytes {
            state = .ready
        } else {
            download()
        }
    }

    func download() {
        try? FileManager.default.removeItem(at: modelURL)
        state = .downloading(received: 0, total: modelBytes)
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: modelSource).resume()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.state = .failed(message) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData written: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite expected: Int64) {
        let total = expected > 0 ? expected : modelBytes
        DispatchQueue.main.async { self.state = .downloading(received: totalBytesWritten, total: total) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            return fail("The download failed (HTTP \(http.statusCode)).")
        }
        let part = modelDirectory.appendingPathComponent(modelFileName + ".part")
        do {
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: part)
            try FileManager.default.moveItem(at: location, to: part)
        } catch {
            return fail("Could not save the model: \(error.localizedDescription)")
        }
        DispatchQueue.main.async { self.state = .verifying }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard try sha256Hex(of: part) == modelSHA256 else {
                    try? FileManager.default.removeItem(at: part)
                    return self.fail("The downloaded model failed its integrity check.")
                }
                try FileManager.default.moveItem(at: part, to: modelURL)
                DispatchQueue.main.async { self.state = .ready }
            } catch {
                self.fail("Could not finish the model download: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { fail("The download failed: \(error.localizedDescription)") }
    }
}

func run(_ exe: String, _ args: [String]) throws -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

func transcribe(_ input: URL) throws -> String {
    guard let whisper = Bundle.main.url(forResource: "whisper-cli", withExtension: nil)?.path else {
        throw TranscribeError.missing("The app is incomplete: whisper-cli is missing from its bundle.")
    }
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        throw TranscribeError.missing("The speech model is not installed yet.")
    }
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let (cs, _) = try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, wav.path])
    guard cs == 0 else { throw TranscribeError.failed("Could not decode the audio file.") }
    let (ws, text) = try run(whisper, ["-m", modelURL.path, "-f", wav.path, "-nt", "-l", "auto"])
    guard ws == 0 else { throw TranscribeError.failed("whisper-cli exited with status \(ws).") }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ContentView: View {
    @State private var transcript = ""
    @State private var status = "Drop an .m4a or .mp3 file here"
    @State private var busy = false
    @State private var targeted = false
    @State private var sourceName = "transcript"
    @StateObject private var model = ModelStore()

    var body: some View {
        VStack(spacing: 12) {
            modelBanner
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundColor(targeted ? .accentColor : .secondary)
                HStack(spacing: 8) {
                    if busy { ProgressView().controlSize(.small) }
                    Text(status).foregroundColor(.secondary)
                }
            }
            .frame(height: 70)
            TextEditor(text: $transcript)
                .font(.body)
                .border(Color.secondary.opacity(0.3))
            HStack {
                if !transcript.isEmpty && !busy {
                    Text("\(wordCount) \(wordCount == 1 ? "word" : "words")")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(transcript, forType: .string)
                }.disabled(transcript.isEmpty)
                Button("Save as .txt…") { save() }.disabled(transcript.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 420)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { start(url) } }
            }
            return true
        }
    }

    var wordCount: Int {
        transcript.split(whereSeparator: \.isWhitespace).count
    }

    @ViewBuilder var modelBanner: some View {
        switch model.state {
        case .ready:
            EmptyView()
        case .downloading(let received, let total):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading the speech model (first launch only): \(byteString(received)) of \(byteString(total))")
                ProgressView(value: Double(received), total: Double(max(total, 1)))
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the speech model…")
            }
        case .failed(let message):
            HStack {
                Text(message).foregroundColor(.red)
                Spacer()
                Button("Try again") { model.download() }
            }
        }
    }

    func start(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "mp3"].contains(ext) else { status = "Unsupported file type: .\(ext)"; return }
        guard model.state == .ready else { status = "The speech model is not ready yet; drop the file again when it is."; return }
        guard !busy else { return }
        busy = true
        transcript = ""
        sourceName = url.deletingPathExtension().lastPathComponent
        status = "Transcribing \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try transcribe(url) }
            DispatchQueue.main.async {
                busy = false
                switch result {
                case .success(let t): transcript = t; status = "Done: \(url.lastPathComponent). Drop another file to continue."
                case .failure(let e): status = "Error: \(e.localizedDescription)"
                }
            }
        }
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = sourceName + ".txt"
        if panel.runModal() == .OK, let url = panel.url {
            do { try transcript.write(to: url, atomically: true, encoding: .utf8) }
            catch { status = "Save failed: \(error.localizedDescription)" }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        Window("Transcriber", id: "main") { ContentView() }
    }
}
