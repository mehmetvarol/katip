import Foundation

/// Dikte geçmişi.
///
/// JSON Lines (satır başına bir kayıt) — veritabanı bağımlılığı yok, dosya
/// `grep`'lenebilir, bozulursa tek satır kaybedilir. Uygulama bir menü çubuğu
/// yardımcısı; SQLite'ı taşımaya değmez.
///
/// ⚠️ Konuştuğun her şey düz metin olarak burada durur. Menüden temizlenebilir.
struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let text: String
    let app: String?
    let seconds: Double?

    init(text: String, app: String?, seconds: Double?) {
        self.id = UUID()
        self.date = Date()
        self.text = text
        self.app = app
        self.seconds = seconds
    }
}

@MainActor
final class History {
    static let shared = History()

    /// Dosya sınırsız büyümesin; dikte kısa metinler olduğu için 1000 kayıt
    /// birkaç yüz KB eder.
    private static let limit = 1000

    private(set) var entries: [HistoryEntry] = []
    var onChange: (() -> Void)?

    private var fileURL: URL { Support.directory.appendingPathComponent("history.jsonl") }

    private init() { load() }

    func add(text: String, app: String?, seconds: Double?) {
        let entry = HistoryEntry(text: text, app: app, seconds: seconds)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        append(entry)
        onChange?()
    }

    func search(_ query: String) -> [HistoryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        // Türkçe'ye duyarlı karşılaştırma: "i/İ" ve aksan farkları eşleşsin.
        return entries.filter {
            $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive],
                          locale: Locale(identifier: "tr_TR")) != nil
        }
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        onChange?()
        Trace.log("geçmiş temizlendi")
    }

    // MARK: - Kalıcılık

    private func load() {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = raw.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(HistoryEntry.self, from: data)
        }.reversed()
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    private func append(_ entry: HistoryEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
