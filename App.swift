// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation
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

/// Runs whisper-cli and reports the fraction of the audio transcribed so far,
/// read from the end time of each segment it prints.
func runWhisper(_ whisper: String, wav: URL, duration: Double, progress: @escaping (Double) -> Void) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: whisper)
    p.arguments = ["-m", modelURL.path, "-f", wav.path, "-l", "auto"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let pattern = try NSRegularExpression(pattern: #"^\[[\d:.]+ --> (\d+):(\d+):(\d+\.\d+)\]\s*(.*)$"#)
    var segments: [String] = []
    var pending = Data()
    func take(_ line: String) {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = pattern.firstMatch(in: line, range: range),
              let h = Double(line[Range(m.range(at: 1), in: line)!]),
              let min = Double(line[Range(m.range(at: 2), in: line)!]),
              let sec = Double(line[Range(m.range(at: 3), in: line)!]) else { return }
        let text = String(line[Range(m.range(at: 4), in: line)!]).trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { segments.append(text) }
        progress(Swift.min(1, (h * 3600 + min * 60 + sec) / Swift.max(duration, 0.001)))
    }
    while true {
        let chunk = out.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        pending.append(chunk)
        while let nl = pending.firstIndex(of: 10) {
            take(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
    }
    if !pending.isEmpty { take(String(decoding: pending, as: UTF8.self)) }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw TranscribeError.failed("whisper-cli exited with status \(p.terminationStatus).") }
    progress(1)
    return segments.joined(separator: "\n")
}

func transcribe(_ input: URL, progress: @escaping (Double) -> Void) throws -> String {
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
    let audio = try AVAudioFile(forReading: wav)
    let duration = Double(audio.length) / audio.processingFormat.sampleRate
    return try runWhisper(whisper, wav: wav, duration: duration, progress: progress)
}

struct ContentView: View {
    @State private var original = ""
    @State private var polished = ""
    @State private var polishVisible = false
    @State private var status = "Drop an .m4a or .mp3 file here"
    @State private var transcribing = false
    @State private var fraction = 0.0
    @State private var polishing = false
    @State private var polishFraction = 0.0
    @State private var etaSeconds: Double?
    @State private var etaStamp = Date()
    @State private var polishTask: Task<Void, Never>?
    @State private var targeted = false
    @State private var sourceName = "transcript"
    @StateObject private var model = ModelStore()
    @StateObject private var local = LocalModels()

    var busy: Bool { transcribing || polishing }

    /// A file may be dropped only when no transcription is held.
    var hasTranscription: Bool { transcribing || !original.isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            modelBanner
            polishPicker
            dropZone
            HStack(spacing: 12) {
                pane("As transcribed", text: $original, isEditable: true, counted: !transcribing,
                     fileName: sourceName + ".txt")
                if polishVisible {
                    pane("Polished", text: $polished, isEditable: !polishing, counted: !polishing,
                         fileName: sourceName + " (polished).txt")
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard !hasTranscription, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { start(url) } }
            }
            return true
        }
    }

    var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundColor(targeted && !hasTranscription ? .accentColor : .secondary.opacity(hasTranscription ? 0.4 : 1))
            VStack(spacing: 6) {
                HStack {
                    Text(status).foregroundColor(.secondary)
                    if hasTranscription {
                        Button("Discard Transcription") { discard() }
                            .disabled(transcribing)
                            .help(transcribing ? "Available when transcribing has finished" : "Clear everything so that another file can be dropped")
                    }
                }
                if transcribing || polishing {
                    progressRow("Transcribing", fraction)
                }
                if polishing {
                    progressRow("Polishing", polishFraction)
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        Text(etaText).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: polishing ? 130 : 80)
    }

    func progressRow(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.secondary).frame(width: 90, alignment: .trailing)
            ProgressView(value: value)
            Text("\(Int(value * 100))%").monospacedDigit().foregroundColor(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    var etaText: String {
        guard let eta = etaSeconds else { return "Estimating the time left…" }
        let left = max(0, eta - Date().timeIntervalSince(etaStamp))
        if left < 60 { return "Less than a minute left" }
        let minutes = Int((left / 60).rounded())
        if minutes < 60 { return "About \(minutes) min left" }
        return "About \(minutes / 60) h \(String(format: "%02d", minutes % 60)) min left"
    }

    func pane(_ title: String, text: Binding<String>, isEditable: Bool, counted: Bool, fileName: String) -> some View {
        let count = text.wrappedValue.split(whereSeparator: \.isWhitespace).count
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            TextEditor(text: text)
                .font(.body)
                .border(Color.secondary.opacity(0.3))
                .disabled(!isEditable)
            HStack {
                if !text.wrappedValue.isEmpty && counted {
                    Text("\(count) \(count == 1 ? "word" : "words")")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text.wrappedValue, forType: .string)
                }.disabled(text.wrappedValue.isEmpty)
                Button("Save as .txt…") { save(text.wrappedValue, as: fileName) }.disabled(text.wrappedValue.isEmpty)
            }
        }
    }

    struct PickerOption: Identifiable { let id: String; let label: String }

    var pickerOptions: [PickerOption] {
        var options = local.found.map { PickerOption(id: $0.id, label: $0.label) }
        if !local.selectedID.isEmpty && !options.contains(where: { $0.id == local.selectedID }) {
            let name = local.selectedID.replacingOccurrences(of: "|", with: ": ")
            options.append(PickerOption(id: local.selectedID, label: name + " (not running)"))
        }
        return options
    }

    @ViewBuilder var polishPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Polish with:").foregroundColor(.secondary)
                Picker("", selection: $local.selectedID) {
                    Text("None").tag("")
                    ForEach(pickerOptions) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(maxWidth: 340)
                Button { local.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Look for local model servers again")
                if local.searching { ProgressView().controlSize(.small) }
                Spacer()
            }
            .disabled(busy)
            if local.found.isEmpty && !local.searching {
                Text("No local model found (LM Studio, Ollama or llama.cpp). Start one and press refresh to have transcripts polished and divided into paragraphs. Everything stays on this Mac.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
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
        guard !hasTranscription else { return }
        guard ["m4a", "mp3"].contains(ext) else { status = "Unsupported file type: .\(ext)"; return }
        guard model.state == .ready else { status = "The speech model is not ready yet; drop the file again when it is."; return }
        transcribing = true
        original = ""
        polished = ""
        polishVisible = false
        sourceName = url.deletingPathExtension().lastPathComponent
        fraction = 0
        status = "Transcribing \(url.lastPathComponent)"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try transcribe(url) { f in DispatchQueue.main.async { fraction = f } }
            }
            DispatchQueue.main.async {
                transcribing = false
                switch result {
                case .success(let text):
                    original = text
                    polishTask = Task { await polishIfChosen(url, text: text) }
                case .failure(let e):
                    status = "Error: \(e.localizedDescription)"
                }
            }
        }
    }

    /// The second pass: runs only when a local model has been chosen. The transcript stays
    /// on show, and can be saved, while it runs.
    func polishIfChosen(_ url: URL, text: String) async {
        let done = "Done: \(url.lastPathComponent)."
        guard !text.isEmpty else {
            status = done + " No speech was found."
            return
        }
        guard !local.selectedID.isEmpty else {
            status = done + " Discard the transcription to transcribe another file."
            return
        }
        let models = await LocalLLM.discover()
        local.found = models
        guard let chosen = models.first(where: { $0.id == local.selectedID }) else {
            status = done + " The chosen local model is not running, so there is no polished version."
            return
        }
        polished = ""
        polishVisible = true
        polishFraction = 0
        etaSeconds = nil
        polishing = true
        status = "Polishing with \(chosen.label)"
        let started = Date()
        do {
            let kept = try await LocalLLM.polish(text, with: chosen) { newText, consumed, total in
                polished += (polished.isEmpty ? "" : "\n\n") + newText
                polishFraction = Double(consumed) / Double(total)
                let elapsed = Date().timeIntervalSince(started)
                etaSeconds = elapsed / Double(max(consumed, 1)) * Double(total - consumed)
                etaStamp = Date()
            }
            status = done + " Polished with \(chosen.label)."
            if kept > 0 {
                status += " \(kept) passage\(kept == 1 ? "" : "s") left as transcribed, because the model's answer did not fit the text."
            }
        } catch {
            if Task.isCancelled { return }
            status = done + " Polishing stopped (\(error.localizedDescription)); the polished text is incomplete."
        }
        polishing = false
    }

    /// Clears everything, so that another file can be dropped.
    func discard() {
        polishTask?.cancel()
        polishTask = nil
        original = ""
        polished = ""
        polishVisible = false
        polishing = false
        transcribing = false
        fraction = 0
        polishFraction = 0
        etaSeconds = nil
        sourceName = "transcript"
        status = "Drop an .m4a or .mp3 file here"
    }

    func save(_ text: String, as name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = name
        if panel.runModal() == .OK, let url = panel.url {
            do { try text.write(to: url, atomically: true, encoding: .utf8) }
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
