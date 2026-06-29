import Foundation

// Persists the most recent dictations so nothing is ever lost, even if the
// transcript had nowhere to paste. Capped at a small number of entries.

struct DictationEntry: Codable {
    let text: String
    let date: Date
}

enum HistoryStore {
    static let maxEntries = 6

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Vox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    static func all() -> [DictationEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([DictationEntry].self, from: data) else { return [] }
        return entries
    }

    static func add(_ text: String) {
        var entries = all()
        entries.insert(DictationEntry(text: text, date: Date()), at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL)
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
