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
func runWhisper(_ whisper: String, wav: URL, duration: Double, progress: @escaping (Double) -> Void,
                onSegment: @escaping (SessionSegment) -> Void) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: whisper)
    p.arguments = ["-m", modelURL.path, "-f", wav.path, "-l", "auto", "-mc", "0"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let pattern = try NSRegularExpression(pattern: #"^\[(\d+):(\d+):(\d+\.\d+) --> (\d+):(\d+):(\d+\.\d+)\]\s*(.*)$"#)
    var segments: [String] = []
    var pending = Data()
    func take(_ line: String) {
        let range = NSRange(line.startIndex..., in: line)
        guard let m = pattern.firstMatch(in: line, range: range) else { return }
        func number(_ i: Int) -> Double? { Double(line[Range(m.range(at: i), in: line)!]) }
        guard let h0 = number(1), let m0 = number(2), let s0 = number(3), let h1 = number(4), let m1 = number(5), let s1 = number(6) else { return }
        let start = h0 * 3600 + m0 * 60 + s0
        let end = h1 * 3600 + m1 * 60 + s1
        let text = String(line[Range(m.range(at: 7), in: line)!]).trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { segments.append(text); onSegment(SessionSegment(start: start, end: end, text: text)) }
        progress(Swift.min(1, end / Swift.max(duration, 0.001)))
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
    return segments.joined(separator: " ")
}

func transcribe(_ input: URL, progress: @escaping (Double) -> Void, onSegment: @escaping (SessionSegment) -> Void,
                onDuration: @escaping (Double) -> Void) throws -> String {
    guard let whisper = Bundle.main.url(forResource: "whisper-cli", withExtension: nil)?.path else {
        throw TranscribeError.missing("The app is incomplete: whisper-cli is missing from its bundle.")
    }
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        throw TranscribeError.missing("The speech model is not installed yet.")
    }
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let (cs, _) = try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input.path, wav.path])
    guard cs == 0 else {
        throw TranscribeError.failed("Could not read audio from this file. It may have no audio track, or use a format macOS cannot decode.")
    }
    let audio = try AVAudioFile(forReading: wav)
    let duration = Double(audio.length) / audio.processingFormat.sampleRate
    onDuration(duration)
    return try runWhisper(whisper, wav: wav, duration: duration, progress: progress, onSegment: onSegment)
}

/// A native, scrollable, selectable text view that cannot be edited. New text is appended
/// in place, so a reader who is scrolling is not moved and the whole text is not laid out again.
struct ReadOnlyText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.textColor = .textColor
        view.textContainerInset = NSSize(width: 4, height: 8)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        let current = view.string
        guard current != text else { return }
        if text.hasPrefix(current), let storage = view.textStorage {
            storage.append(NSAttributedString(string: String(text.dropFirst(current.count)),
                                              attributes: [.font: view.font as Any, .foregroundColor: NSColor.textColor]))
        } else {
            view.string = text
        }
    }
}

/// The polished text: scrollable and selectable, but not editable. New paragraphs are appended in
/// place, and those kept as transcribed are shown in orange.
struct PolishedText: NSViewRepresentable {
    let parts: [PolishPart]

    final class Coordinator { var applied = 0 }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.textColor = .textColor
        view.textContainerInset = NSSize(width: 4, height: 8)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        let coordinator = context.coordinator
        if parts.count < coordinator.applied {
            view.string = ""
            coordinator.applied = 0
        }
        guard let storage = view.textStorage else { return }
        while coordinator.applied < parts.count {
            let part = parts[coordinator.applied]
            storage.append(NSAttributedString(
                string: (coordinator.applied > 0 ? "\n\n" : "") + part.text,
                attributes: [.font: view.font as Any, .foregroundColor: part.fallback ? NSColor.systemOrange : NSColor.textColor]))
            coordinator.applied += 1
        }
    }
}

/// The file types whose audio macOS can decode without help: audio files, and the audio track of video files.
let supportedExtensions = ["zip", "m4a", "mp3", "wav", "aif", "aiff", "aifc", "caf", "flac", "aac", "ac3", "mp2",
                           "mp4", "m4v", "mov", "3gp"]
let dropHint = "Drop an audio or video file, or a saved session, here"

struct ContentView: View {
    @State private var original = ""
    @State private var polished = ""
    @State private var polishedParts: [PolishPart] = []
    @State private var polishVisible = false
    @State private var status = dropHint
    @State private var transcribing = false
    @State private var fraction = 0.0
    @State private var stage = "Transcribing"
    @State private var polishing = false
    @State private var polishFraction = 0.0
    @State private var polishEta: Double?
    @State private var polishEtaStamp = Date()
    @State private var polishTask: Task<Void, Never>?
    @State private var summaryDescription = ""
    @State private var summaryBody = ""
    @State private var showSummaryTab = false
    @State private var summaryVisible = false
    @State private var summarising = false
    @State private var summaryFraction = 0.0
    @State private var summaryEta: Double?
    @State private var summaryEtaStamp = Date()
    @State private var summaryTask: Task<Void, Never>?
    @State private var targeted = false
    @State private var sourceName = "transcript"
    @State private var sourceFile = ""
    @State private var audioSeconds: Double?
    @State private var segments: [SessionSegment] = []
    @State private var sourceURL: URL?
    @State private var sourceBytes: Int64 = 0
    @State private var loadedZip: URL?
    @State private var savingSession = false
    @State private var polishModelLabel = ""
    @State private var summaryModelLabel = ""
    @State private var transcribeSeconds: Double?
    @State private var polishSeconds: Double?
    @State private var summarySeconds: Double?
    @State private var descriptionSeconds: Double?
    @StateObject private var model = ModelStore()
    @StateObject private var local = LocalModels()

    var busy: Bool { transcribing || polishing || summarising }

    /// A file may be dropped only when no transcription is held.
    var hasTranscription: Bool { transcribing || !original.isEmpty }

    var body: some View {
        VStack(spacing: 12) {
            modelBanner
            polishPicker
            dropZone
            if summaryVisible {
                Picker("", selection: $showSummaryTab) {
                    Text("Transcript").tag(false)
                    Text("Summary").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
            }
            if summaryVisible && showSummaryTab {
                summaryView
            } else {
                HStack(spacing: 12) {
                    pane("As transcribed", text: original, complete: !transcribing, fileName: sourceName + ".txt") {
                        ReadOnlyText(text: original)
                    }
                    if polishVisible {
                        pane("Polished", text: polished, complete: !polishing, fileName: sourceName + " (polished).txt",
                             note: polishedParts.contains(where: \.fallback) ? "Orange text was left as transcribed." : nil) {
                            PolishedText(parts: polishedParts)
                        }
                    }
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
                    if savingSession { ProgressView().controlSize(.small) }
                    if hasTranscription {
                        Button("Save Session…") { saveSession() }
                            .disabled(busy || savingSession)
                            .help("Save the transcript, the polished text, the summary and the original file in one zip file, to open again later")
                        Button("Discard Transcription") { discard() }
                            .disabled(transcribing)
                            .help(transcribing ? "Available when transcribing has finished" : "Clear everything so that another file can be dropped")
                    }
                }
                if let seconds = audioSeconds {
                    Text("Audio length \(hms(seconds))").font(.caption).foregroundColor(.secondary)
                }
                if let line = timingsText {
                    Text(line).font(.caption).foregroundColor(.secondary)
                }
                if transcribing || polishing {
                    progressRow(stage, fraction)
                }
                if polishing {
                    progressRow("Polishing", polishFraction)
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        Text(etaText(polishEta, since: polishEtaStamp)).font(.caption).foregroundColor(.secondary)
                    }
                }
                if summarising {
                    progressRow("Summarising", summaryFraction)
                    TimelineView(.periodic(from: .now, by: 5)) { _ in
                        Text(etaText(summaryEta, since: summaryEtaStamp)).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: zoneHeight)
    }

    /// How long each step took, as far as each has finished.
    var timingsText: String? {
        var parts: [String] = []
        if let t = transcribeSeconds { parts.append("Transcribed in \(elapsed(t))") }
        if let t = polishSeconds { parts.append("polished in \(elapsed(t))") }
        if let t = summarySeconds { parts.append("summary in \(elapsed(t))") }
        if let t = descriptionSeconds { parts.append("description in \(elapsed(t))") }
        guard !parts.isEmpty else { return nil }
        let line = parts.joined(separator: ", ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// A time taken as m:ss, or h:mm:ss from an hour on.
    func elapsed(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// A length of time as h:mm:ss.
    func hms(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60)
    }

    var zoneHeight: CGFloat {
        80 + (audioSeconds != nil ? 18 : 0) + (timingsText != nil ? 16 : 0) + (transcribing || polishing || summarising ? 28 : 0)
            + (polishing ? 46 : 0) + (summarising ? 46 : 0)
    }

    func progressRow(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.secondary).frame(width: 90, alignment: .trailing)
            ProgressView(value: value)
            Text("\(Int(value * 100))%").monospacedDigit().foregroundColor(.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    func etaText(_ eta: Double?, since stamp: Date) -> String {
        guard let eta else { return "Estimating the time left…" }
        let left = max(0, eta - Date().timeIntervalSince(stamp))
        if left < 60 { return "Less than a minute left" }
        let minutes = Int((left / 60).rounded())
        if minutes < 60 { return "About \(minutes) min left" }
        return "About \(minutes / 60) h \(String(format: "%02d", minutes % 60)) min left"
    }

    func pane<Content: View>(_ title: String, text: String, complete: Bool, fileName: String, note: String? = nil,
                             @ViewBuilder content: () -> Content) -> some View {
        let count = text.split(whereSeparator: \.isWhitespace).count
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if let note { Text(note).font(.caption).foregroundColor(.orange) }
            }
            content().border(Color.secondary.opacity(0.3))
            HStack {
                if !text.isEmpty && complete {
                    Text("\(count) \(count == 1 ? "word" : "words")")
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.disabled(text.isEmpty || !complete)
                Button("Save as .txt…") { save(text, as: fileName) }.disabled(text.isEmpty || !complete)
            }
        }
    }

    /// The description line, with the scrollable summary below it.
    var summaryView: some View {
        let text = summaryDescription.isEmpty ? summaryBody : summaryDescription + "\n\n" + summaryBody
        let count = text.split(whereSeparator: \.isWhitespace).count
        return VStack(alignment: .leading, spacing: 8) {
            Text(summaryDescription)
                .font(.title2.bold())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            ReadOnlyText(text: summaryBody)
                .overlay {
                    if summarising && summaryBody.isEmpty {
                        Text("Writing the summary…").foregroundColor(.secondary)
                    }
                }
                .border(Color.secondary.opacity(0.3))
            HStack {
                if !text.isEmpty && !summarising {
                    Text("\(count) \(count == 1 ? "word" : "words")").foregroundColor(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.disabled(text.isEmpty || summarising)
                Button("Save as .txt…") { save(text, as: sourceName + " (summary).txt") }.disabled(text.isEmpty || summarising)
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
                .onChange(of: local.selectedID) { id in
                    // A model chosen after the transcription was made polishes it now.
                    if !id.isEmpty, !original.isEmpty, !busy, !polishVisible {
                        polishTask = Task { await polishIfChosen(sourceFile, text: original) }
                    }
                }
                Button { local.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Look for local model servers again")
                if local.searching { ProgressView().controlSize(.small) }
                Spacer()
                if hasTranscription && local.selectedID.isEmpty && !summaryVisible {
                    Text("Choose a model to enable Summarise").font(.caption).foregroundColor(.secondary)
                }
                Button("Summarise") { startSummary() }
                    .disabled(original.isEmpty || local.selectedID.isEmpty || busy || summaryVisible)
                    .help(summaryVisible
                          ? "This transcription has been summarised. Discard it to start again."
                          : local.selectedID.isEmpty
                              ? "Choose a local model first"
                              : "Write a one-line description and a summary of the transcription, using the chosen model")
            }
            .disabled(busy)
            if local.found.isEmpty && !local.searching {
                Text("No local model found. If LM Studio, Ollama or llama.cpp is running on this Mac with a model, this app will use it to polish your transcripts, divide them into paragraphs, and write a summary and a one-line description of each recording. Start one and press the refresh arrow. Everything stays on this Mac.")
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
        guard supportedExtensions.contains(ext) else {
            status = "Unsupported file type: .\(ext). Audio: mp3, m4a, aac, wav, aiff, caf, flac, ac3, mp2. Video: mp4, mov, m4v, 3gp. Or a saved session (.zip)."
            return
        }
        if ext == "zip" { openSession(url); return }
        guard model.state == .ready else { status = "The speech model is not ready yet; drop the file again when it is."; return }
        transcribing = true
        transcribeSeconds = nil
        polishSeconds = nil
        summarySeconds = nil
        descriptionSeconds = nil
        let began = Date()
        segments = []
        sourceURL = url
        sourceBytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        loadedZip = nil
        polishModelLabel = ""
        summaryModelLabel = ""
        original = ""
        polished = ""
        polishVisible = false
        summaryDescription = ""
        summaryBody = ""
        showSummaryTab = false
        summaryVisible = false
        sourceName = url.deletingPathExtension().lastPathComponent
        sourceFile = url.lastPathComponent
        audioSeconds = nil
        fraction = 0
        stage = "Extracting audio"
        status = "Extracting the audio of \(url.lastPathComponent)"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try transcribe(url, progress: { f in DispatchQueue.main.async { fraction = f } },
                               onSegment: { seg in
                                DispatchQueue.main.async {
                                    segments.append(seg)
                                    original += (original.isEmpty ? "" : " ") + seg.text
                                }
                            },
                               onDuration: { d in
                                DispatchQueue.main.async {
                                    audioSeconds = d
                                    stage = "Transcribing"
                                    status = "Transcribing \(url.lastPathComponent)"
                                }
                            })
            }
            DispatchQueue.main.async {
                transcribing = false
                switch result {
                case .success(let text):
                    transcribeSeconds = Date().timeIntervalSince(began)
                    original = text
                    polishTask = Task { await polishIfChosen(url.lastPathComponent, text: text) }
                case .failure(let e):
                    status = "Error: \(e.localizedDescription)"
                }
            }
        }
    }

    /// The second pass: runs only when a local model has been chosen. The transcript stays
    /// on show, and can be saved, while it runs.
    func polishIfChosen(_ fileName: String, text: String) async {
        let done = "Done: \(fileName)."
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
        polishedParts = []
        polishVisible = true
        polishFraction = 0
        polishEta = nil
        polishing = true
        status = "Polishing with \(chosen.label)"
        let started = Date()
        do {
            let kept = try await LocalLLM.polish(text, with: chosen) { parts, consumed, total in
                polishedParts += parts
                polished = polishedParts.map(\.text).joined(separator: "\n\n")
                polishFraction = Double(consumed) / Double(total)
                let elapsed = Date().timeIntervalSince(started)
                polishEta = elapsed / Double(max(consumed, 1)) * Double(total - consumed)
                polishEtaStamp = Date()
            }
            polishSeconds = Date().timeIntervalSince(started)
            polishModelLabel = chosen.label
            status = done + " Polished with \(chosen.label)."
            if kept > 0 {
                status += " \(kept) stretch\(kept == 1 ? "" : "es") could not be polished and \(kept == 1 ? "is" : "are") left as transcribed, in orange."
            }
        } catch {
            if Task.isCancelled { return }
            status = done + " Polishing stopped (\(error.localizedDescription)); the polished text is incomplete."
        }
        polishing = false
    }

    /// Runs only when the Summarise button is pressed. It uses the polished text if there is any.
    func startSummary() {
        let source = (polishVisible && !polished.isEmpty) ? polished : original
        guard !source.isEmpty else { return }
        summaryTask = Task { await summarise(source) }
    }

    func summarise(_ source: String) async {
        let models = await LocalLLM.discover()
        local.found = models
        guard let chosen = models.first(where: { $0.id == local.selectedID }) else {
            status = "The chosen local model is not running, so there is no summary."
            return
        }
        summaryDescription = ""
        summaryBody = ""
        summarySeconds = nil
        descriptionSeconds = nil
        summaryFraction = 0
        summaryEta = nil
        summaryVisible = true
        summarising = true
        status = "Summarising with \(chosen.label)"
        let started = Date()
        do {
            let result = try await LocalLLM.summarise(source, with: chosen) { done, total in
                summaryFraction = Double(done) / Double(total)
                let elapsed = Date().timeIntervalSince(started)
                summaryEta = elapsed / Double(max(done, 1)) * Double(total - done)
                summaryEtaStamp = Date()
            }
            summaryDescription = result.description
            summaryBody = result.summary
            summaryModelLabel = chosen.label
            summarySeconds = result.summarySeconds
            descriptionSeconds = result.descriptionSeconds
            showSummaryTab = true
            status = "Done: summarised with \(chosen.label)."
        } catch {
            if Task.isCancelled { return }
            summaryVisible = !summaryBody.isEmpty
            status = "Summarising failed (\(error.localizedDescription))."
        }
        summarising = false
    }

    func sessionInfo() -> SessionInfo {
        SessionInfo(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            created: ISO8601DateFormatter().string(from: Date()),
            source: .init(file: sourceFile, bytes: sourceBytes, audioSeconds: audioSeconds),
            whisper: .init(model: modelFileName, engine: "whisper.cpp v1.9.5", carriesContext: false),
            timings: .init(transcribeSeconds: transcribeSeconds, polishSeconds: polishSeconds,
                           summarySeconds: summarySeconds, descriptionSeconds: descriptionSeconds),
            transcript: original,
            segments: segments,
            polish: polishedParts.isEmpty ? nil : .init(model: polishModelLabel,
                paragraphs: polishedParts.map { SessionPart(text: $0.text, fallback: $0.fallback) }),
            summary: summaryBody.isEmpty ? nil : .init(model: summaryModelLabel, description: summaryDescription, body: summaryBody))
    }

    /// Saves the transcription, its generated text and the whole original file in one zip.
    func saveSession() {
        guard !original.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = sourceName + " session.zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if sourceBytes > 2_000_000_000 {
            let alert = NSAlert()
            alert.messageText = "The original file is \(byteString(sourceBytes))"
            alert.informativeText = "The session zip holds the whole original file, so it will be about that size, and saving takes a while."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let info = sessionInfo()
        let source = sourceURL
        let zip = loadedZip
        savingSession = true
        status = "Saving the session…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { () -> Int64 in
                var temp: URL?
                defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
                let file: URL
                if let source {
                    file = source
                } else if let zip {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("transcriber-reopen-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    temp = dir
                    file = try SessionArchive.extractOriginal(from: zip, into: dir)
                } else {
                    throw SessionArchive.Failure.failed("The original file is no longer available.")
                }
                guard FileManager.default.fileExists(atPath: file.path) else {
                    throw SessionArchive.Failure.failed("The original file \(file.lastPathComponent) has been moved or deleted.")
                }
                try SessionArchive.save(info, original: file, to: destination)
                return ((try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value ?? 0
            }
            DispatchQueue.main.async {
                savingSession = false
                switch result {
                case .success(let bytes): status = "Saved \(destination.lastPathComponent) (\(byteString(bytes)))."
                case .failure(let e): status = "Saving failed: \(e.localizedDescription)"
                }
            }
        }
    }

    /// Opens a zip saved by this app, so that the window looks as it did when the zip was made.
    func openSession(_ zip: URL) {
        status = "Opening \(zip.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SessionArchive.open(zip) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    status = e.localizedDescription
                case .success(let info):
                    original = info.transcript
                    segments = info.segments
                    sourceFile = info.source.file
                    sourceName = (info.source.file as NSString).deletingPathExtension
                    sourceURL = nil
                    loadedZip = zip
                    sourceBytes = info.source.bytes
                    audioSeconds = info.source.audioSeconds
                    transcribeSeconds = info.timings.transcribeSeconds
                    polishSeconds = info.timings.polishSeconds
                    summarySeconds = info.timings.summarySeconds
                    descriptionSeconds = info.timings.descriptionSeconds
                    polishedParts = (info.polish?.paragraphs ?? []).map { PolishPart(text: $0.text, fallback: $0.fallback) }
                    polished = polishedParts.map(\.text).joined(separator: "\n\n")
                    polishVisible = !polishedParts.isEmpty
                    polishModelLabel = info.polish?.model ?? ""
                    summaryDescription = info.summary?.description ?? ""
                    summaryBody = info.summary?.body ?? ""
                    summaryModelLabel = info.summary?.model ?? ""
                    summaryVisible = !summaryBody.isEmpty
                    showSummaryTab = false
                    var saved = info.created
                    if let date = ISO8601DateFormatter().date(from: info.created) {
                        saved = date.formatted(date: .abbreviated, time: .shortened)
                    }
                    status = "Opened \(zip.lastPathComponent), saved \(saved). Discard it to open or transcribe another file."
                }
            }
        }
    }

    /// Clears everything, so that another file can be dropped.
    func discard() {
        polishTask?.cancel()
        polishTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        summaryDescription = ""
        summaryBody = ""
        showSummaryTab = false
        summaryVisible = false
        summarising = false
        summaryFraction = 0
        summaryEta = nil
        original = ""
        polished = ""
        polishedParts = []
        polishVisible = false
        polishing = false
        transcribing = false
        fraction = 0
        polishFraction = 0
        polishEta = nil
        sourceName = "transcript"
        sourceFile = ""
        audioSeconds = nil
        segments = []
        sourceURL = nil
        sourceBytes = 0
        loadedZip = nil
        polishModelLabel = ""
        summaryModelLabel = ""
        transcribeSeconds = nil
        polishSeconds = nil
        summarySeconds = nil
        descriptionSeconds = nil
        status = dropHint
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
