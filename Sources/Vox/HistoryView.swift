import SwiftUI
import AppKit

// The app's real window: a list of recent dictations. Each row's text is
// selectable (Cmd+C) and has a Copy button, so a transcript that had nowhere
// to paste is never lost.

struct HistoryView: View {
    @State private var entries: [DictationEntry] = HistoryStore.all()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Dictation History").font(.headline)
                Spacer()
                Button("Refresh") { entries = HistoryStore.all() }
                Button("Clear") { HistoryStore.clear(); entries = [] }
            }

            if entries.isEmpty {
                Spacer()
                Text("No dictations yet. Hold Right Option and speak.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List {
                    ForEach(entries.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entries[i].text)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Text(entries[i].date, style: .time)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Copy") { copy(entries[i].text) }
                                    .buttonStyle(.borderless)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 380)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
