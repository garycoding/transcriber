// Transcriber, a macOS drag-and-drop audio transcriber.
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UniformTypeIdentifiers
import AppKit

let whisperPaths = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
let modelURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Transcriber/ggml-small.bin")

enum TranscribeError: LocalizedError {
    case missing(String), failed(String)
    var errorDescription: String? {
        switch self { case .missing(let s), .failed(let s): return s }
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
    guard let whisper = whisperPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw TranscribeError.missing("whisper-cli not found. Install it with: brew install whisper-cpp")
    }
    guard FileManager.default.fileExists(atPath: modelURL.path) else {
        throw TranscribeError.missing("Model not found at \(modelURL.path)")
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

    var body: some View {
        VStack(spacing: 12) {
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

    func start(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ["m4a", "mp3"].contains(ext) else { status = "Unsupported file type: .\(ext)"; return }
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
        WindowGroup("Transcriber") { ContentView() }
    }
}
