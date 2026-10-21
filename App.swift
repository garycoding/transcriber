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
    @State private var unpacking = false
    @StateObject private var player = PlaybackController()
    @State private var follow = true
    @State private var scrubbing = false
    @State private var scrubTime = 0.0
    @State private var showVideo = true
    @State private var map: PlaybackMap?
    @State private var leftHighlight: NSRange?
    @State private var rightHighlight: NSRange?
    @State private var sessionOriginalURL: URL?
    @State private var windowHeight: CGFloat = 760
    @State private var query = ""
    @State private var matches: [NSRange] = []
    @State private var matchIndex: Int?
    @State private var findHighlight: NSRange?
    @State private var matchTimes: [Double] = []
    @State private var rightMarks: [NSRange] = []
    @FocusState private var searchFocused: Bool
    @State private var sessionDirectory: URL?
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
            playbackSection
            searchBar
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
                        ReadOnlyText(text: original, highlight: leftHighlight, find: findHighlight, marks: matches, follow: follow && player.isLoaded,
                                     onDoubleClick: { handleDoubleClick(left: true, $0) }, onUserScroll: { follow = false })
                    }
                    if polishVisible {
                        pane("Polished", text: polished, complete: !polishing, fileName: sourceName + " (polished).txt",
                             note: polishedParts.contains(where: \.fallback) ? "Orange text was left as transcribed." : nil) {
                            PolishedText(parts: polishedParts, highlight: rightHighlight, marks: rightMarks, follow: follow && player.isLoaded,
                                         onDoubleClick: { handleDoubleClick(left: false, $0) }, onUserScroll: { follow = false })
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 700)
        .background(WindowFloor(minSize: NSSize(width: 640, height: 700)))
        .background(GeometryReader { g in
            Color.clear
                .onAppear { windowHeight = g.size.height }
                .onChange(of: g.size.height) { windowHeight = $0 }
        })
        .onChange(of: displayTime) { _ in updateHighlights() }
        .onChange(of: query) { _ in updateMatches() }
        .onChange(of: original) { _ in updateMatches() }
        .onChange(of: segments.count) { n in if transcribing && n % 4 == 0 { rebuildMap() } }
        .onChange(of: player.isLoaded) { _ in updateHighlights() }
        .onChange(of: polishing) { _ in rebuildMap() }
        .onChange(of: transcribing) { _ in rebuildMap() }
        .onAppear {
            // Unpacked sessions from an earlier run are not kept.
            if let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
                try? FileManager.default.removeItem(at: base.appendingPathComponent("Transcriber/Sessions"))
            }
        }
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
                    if savingSession || unpacking { ProgressView().controlSize(.small) }
                    if hasTranscription {
                        Button("Save Session…") { saveSession() }
                            .disabled(busy || savingSession || unpacking)
                            .help("Save the transcript, the polished text, the summary and the original file in one zip file, to open again later")
                        Button("Discard Transcription") { discard() }
                            .disabled(transcribing || unpacking)
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
        let body = content()
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                if let note { Text(note).font(.caption).foregroundColor(.orange) }
            }
            body
                .frame(minHeight: 80, maxHeight: .infinity)
                .clipped()
                .border(Color.secondary.opacity(0.3))
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
        sessionOriginalURL = nil
        player.load(url)
        follow = true
        map = nil
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

    // MARK: Playback

    var displayTime: Double { scrubbing ? scrubTime : player.time }

    /// Builds the link between times and text, from what there is so far.
    func rebuildMap() {
        guard !original.isEmpty, !segments.isEmpty else { map = nil; leftHighlight = nil; rightHighlight = nil; return }
        map = PlaybackMap(text: original, segments: segments,
                          parts: polishedParts.map { (text: $0.text, startWord: $0.startWord, endWord: $0.endWord) })
        updateHighlights()
        updateMarks()
    }

    func updateHighlights() {
        guard let map, player.isLoaded else { leftHighlight = nil; rightHighlight = nil; return }
        let w = map.word(atTime: displayTime)
        leftHighlight = map.leftSentence(forWord: w)
        rightHighlight = (polishVisible && !polishing) ? map.rightSentence(forWord: w) : nil
    }

    /// A double-click on a word of either text: highlight its sentence in both, and move the player and the other
    /// text to that place.
    func handleDoubleClick(left: Bool, _ index: Int) {
        guard let map, player.isLoaded else { return }
        guard let w = left ? map.word(forLeftCharacter: index) : map.word(forRightCharacter: index) else { return }
        follow = true
        player.seek(to: map.time(atMiddleOfWord: w), precise: true)
        updateHighlights()
    }

    /// Moves the player by a number of seconds, and brings the text to the new place.
    func jog(_ seconds: Double) {
        follow = true
        player.seek(to: player.time + seconds, precise: true)
        updateHighlights()
    }

    // MARK: Search

    /// The matches of the query in the original text, ignoring case and accents.
    func updateMatches() {
        findHighlight = nil
        matchIndex = nil
        matches = PlaybackMap.matches(of: query, in: original)
        updateMarks()
    }

    /// Where the matches fall in the audio, and in the polished text, for the marks on the slider and the scroll bars.
    func updateMarks() {
        guard let map, !matches.isEmpty else { matchTimes = []; rightMarks = []; return }
        let words = matches.map { map.word(forLeftCharacter: $0.location) }
        matchTimes = words.map { map.time(atMiddleOfWord: $0) }
        rightMarks = (polishVisible && !polishing) ? words.compactMap { map.rightSentence(forWord: $0) } : []
    }

    /// Goes to the next match (or the previous), counted from the place being played, and moves everything to it:
    /// the player, the original text, and the polished text.
    func find(_ direction: Int) {
        guard let map, let index = map.matchIndex(in: matches, current: matchIndex, direction: direction, atTime: displayTime) else { return }
        matchIndex = index
        let match = matches[index]
        findHighlight = match
        follow = true
        let w = map.word(forLeftCharacter: match.location)
        if player.isLoaded {
            player.seek(to: map.time(atMiddleOfWord: w), precise: true)
            updateHighlights()
        } else {
            leftHighlight = map.leftSentence(forWord: w)
            rightHighlight = (polishVisible && !polishing) ? map.rightSentence(forWord: w) : nil
        }
    }

    var matchLabel: String {
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return "" }
        if matches.isEmpty { return "No matches" }
        if let i = matchIndex { return "\(i + 1) of \(matches.count)" }
        return "\(matches.count) match\(matches.count == 1 ? "" : "es")"
    }

    /// The search field, with next and previous, shown once there is a transcript to search.
    @ViewBuilder var searchBar: some View {
        if !original.isEmpty && !transcribing {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search the transcript", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { find(1) }
                Button { find(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(matches.isEmpty)
                    .help("Previous match")
                Button { find(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(matches.isEmpty)
                    .help("Next match")
                Text(matchLabel).foregroundColor(.secondary).monospacedDigit().frame(minWidth: 80, alignment: .leading)
                // Command-F moves to the search field.
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
        }
    }

    var speedLabel: String {
        let r = Double(player.rate)
        return (r == r.rounded() ? String(Int(r)) : String(format: "%g", r)) + "×"
    }

    /// The controls for the original audio or video, with the picture when it is a video.
    @ViewBuilder var playbackSection: some View {
        if player.isLoaded {
            VStack(spacing: 6) {
                if player.hasVideo && showVideo {
                    VideoView(player: player.player)
                        .frame(height: min(220, max(80, (windowHeight - 520) * 0.6)))
                        .cornerRadius(6)
                }
                HStack(spacing: 10) {
                    Button { jog(-10) } label: { Image(systemName: "gobackward.10") }
                        .help("Back 10 seconds")
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                    }
                    .help(player.isPlaying ? "Pause" : "Play")
                    Button { jog(10) } label: { Image(systemName: "goforward.10") }
                        .help("Forward 10 seconds")
                    Text(elapsed(displayTime)).monospacedDigit().foregroundColor(.secondary).frame(width: 52, alignment: .trailing)
                    Slider(value: Binding(get: { displayTime },
                                          set: { scrubTime = $0; player.seek(to: $0, precise: false) }),
                           in: 0...max(player.duration, 1),
                           onEditingChanged: { editing in
                               if editing { scrubTime = player.time; follow = true } else { player.seek(to: scrubTime, precise: true) }
                               scrubbing = editing
                           })
                    .overlay {
                        GeometryReader { g in
                            ForEach(Array(matchTimes.enumerated()), id: \.offset) { _, t in
                                Rectangle()
                                    .fill(Color.orange)
                                    .frame(width: 2, height: 12)
                                    .position(x: 9 + CGFloat(t / max(player.duration, 1)) * (g.size.width - 18), y: g.size.height / 2)
                            }
                        }
                        .allowsHitTesting(false)
                    }
                    Text(elapsed(player.duration)).monospacedDigit().foregroundColor(.secondary).frame(width: 52, alignment: .leading)
                    Menu(speedLabel) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button(String(format: "%g×", r)) { player.setRate(Float(r)) }
                        }
                    }
                    .frame(width: 62)
                    Toggle("Follow", isOn: $follow)
                        .toggleStyle(.button)
                        .help("Keep the text scrolled to the place being played. Scrolling by hand turns this off.")
                    if player.hasVideo {
                        Toggle("Video", isOn: $showVideo).toggleStyle(.button)
                    }
                }
            }
        }
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
                paragraphs: polishedParts.map { SessionPart(text: $0.text, fallback: $0.fallback, startWord: $0.startWord, endWord: $0.endWord) }),
            summary: summaryBody.isEmpty ? nil : .init(model: summaryModelLabel, description: summaryDescription, body: summaryBody))
    }

    /// Saves the transcription, its generated text and the whole original file in one zip.
    func saveSession() {
        guard !original.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = sourceName + "-transcription_session.zip"
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
        let source = sourceURL ?? sessionOriginalURL
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
                    polishedParts = (info.polish?.paragraphs ?? []).map { PolishPart(text: $0.text, fallback: $0.fallback, startWord: $0.startWord, endWord: $0.endWord) }
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
                    rebuildMap()
                    let message = "Opened \(zip.lastPathComponent), saved \(saved). Discard it to open or transcribe another file."
                    status = "Unpacking the original file…"
                    unpacking = true
                    DispatchQueue.global(qos: .userInitiated).async {
                        let unpacked = Result { () -> (URL, URL) in
                            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                                   appropriateFor: nil, create: true)
                            let dir = base.appendingPathComponent("Transcriber/Sessions/" + UUID().uuidString)
                            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            return (dir, try SessionArchive.extractOriginal(from: zip, into: dir))
                        }
                        DispatchQueue.main.async {
                            unpacking = false
                            switch unpacked {
                            case .success(let (dir, file)):
                                sessionDirectory = dir
                                sessionOriginalURL = file
                                player.load(file)
                                status = message
                            case .failure(let e):
                                status = message + " Its original file could not be unpacked, so it cannot be played: \(e.localizedDescription)"
                            }
                        }
                    }
                }
            }
        }
    }

    /// Clears everything, so that another file can be dropped.
    func discard() {
        player.teardown()
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        sessionDirectory = nil
        sessionOriginalURL = nil
        map = nil
        leftHighlight = nil
        rightHighlight = nil
        query = ""
        matches = []
        matchIndex = nil
        findHighlight = nil
        follow = true
        scrubbing = false
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

/// Keeps the window at least as large as its content needs, including a frame restored at a smaller size.
struct WindowFloor: NSViewRepresentable {
    let minSize: NSSize
    final class Probe: NSView {
        var minSize = NSSize.zero
        override func viewDidMoveToWindow() {
            guard let window else { return }
            window.contentMinSize = minSize
            var size = window.contentRect(forFrameRect: window.frame).size
            size.width = max(size.width, minSize.width)
            size.height = max(size.height, minSize.height)
            if size != window.contentRect(forFrameRect: window.frame).size { window.setContentSize(size) }
        }
    }
    func makeNSView(context: Context) -> Probe { let p = Probe(); p.minSize = minSize; return p }
    func updateNSView(_ view: Probe, context: Context) { view.minSize = minSize; view.window?.contentMinSize = minSize }
}

@main
struct TranscriberApp: App {
    @NSApplicationDelegateAdaptor(Delegate.self) var delegate
    var body: some Scene {
        Window("Transcriber", id: "main") { ContentView() }
            .defaultSize(width: 1000, height: 780)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(after: .appInfo) { LicensesMenuButton() }
                CommandGroup(replacing: .help) { LicensesMenuButton() }
            }
        Window("Open Source Licenses", id: "licenses") { LicensesView() }
    }
}
