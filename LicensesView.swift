// SPDX-FileCopyrightText: 2026 Gary Frattarola <garyf@parkviewlab.ai>
// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI

/// One piece of software the app uses or ships, with where its licence text is kept in the app bundle.
struct Notice: Identifiable {
    let name: String
    let version: String
    let summary: String
    let license: String
    let url: URL
    let textFile: String
    var id: String { name }

    static var all: [Notice] {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return [
            Notice(name: "Transcriber", version: appVersion,
                   summary: "This app.",
                   license: "AGPL-3.0-or-later", url: URL(string: "https://github.com/garycoding/transcriber")!,
                   textFile: "Transcriber-LICENSE"),
            Notice(name: "whisper.cpp and ggml", version: "1.9.5",
                   summary: "Speech recognition. It is built into the app as a separate program, whisper-cli, which the app runs on your audio.",
                   license: "MIT", url: URL(string: "https://github.com/ggml-org/whisper.cpp")!,
                   textFile: "whisper.cpp-and-ggml-LICENSE"),
            Notice(name: "OpenAI Whisper model", version: "small",
                   summary: "The speech model, in the form whisper.cpp reads. It is downloaded the first time the app is used and is not part of the app itself.",
                   license: "MIT", url: URL(string: "https://github.com/openai/whisper")!,
                   textFile: "openai-whisper-LICENSE"),
        ]
    }

    /// The licence text shipped in the app's Resources/legal folder.
    var text: String {
        if let url = Bundle.main.url(forResource: textFile, withExtension: "txt", subdirectory: "legal"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return "The licence text is not in this build of the app. It is in the app's source, in the legal folder: \(url.absoluteString)"
    }
}

/// The Open Source Licenses window: each piece of software, its licence, a link to its source, and the
/// licence text. Links open in the system's browser.
struct LicensesView: View {
    @State private var open: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Transcriber is built on open source software. Thank you to the people who wrote and share it.")
                    .foregroundColor(.secondary)
                ForEach(Notice.all) { notice in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(notice.name).font(.headline)
                            Text(notice.version).foregroundColor(.secondary)
                            Spacer()
                            Text(notice.license).font(.subheadline).foregroundColor(.secondary)
                        }
                        Text(notice.summary)
                        Link(notice.url.absoluteString, destination: notice.url).font(.callout)
                        DisclosureGroup("Licence text", isExpanded: Binding(
                            get: { open.contains(notice.id) },
                            set: { if $0 { open.insert(notice.id) } else { open.remove(notice.id) } })) {
                            Text(notice.text)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(Color.secondary.opacity(0.12))
                                .cornerRadius(6)
                        }
                    }
                    Divider()
                }
                Text("Programs you may have running on this Mac, such as LM Studio, Ollama or llama.cpp, are used only if you choose one, and are not part of Transcriber. They have their own licences.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("The app makes no network connection other than downloading the speech model the first time it is used, and talking to a model program running on this Mac.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 420)
        .onExitCommand { NSApp.keyWindow?.performClose(nil) }
    }
}

/// The menu item that opens the licenses window.
struct LicensesMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Source Licenses…") { openWindow(id: "licenses") }
    }
}
