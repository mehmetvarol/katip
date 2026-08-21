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
    var text: String
    let app: String?
    let seconds: Double?
    /// Ham sesin dosya adı (`Recordings` klasöründe). Eski kayıtlarda YOK —
    /// isteğe bağlı olması bilinçli, alan eklenmeden önce yazılmış
    /// `history.jsonl` satırları böylece okunmaya devam ediyor.
    var audio: String?
    /// Bu metin sonradan yeniden çevrildiyse işaretli. Kullanıcı hangi
    /// kaydın elle düzeltildiğini görebilmeli.
    var retranscribed: Bool?

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

    /// Saklama süresi. Bundan eski kayıtlar açılışta ve her yazımda silinir.
    /// Gerekçe gizlilik: konuşulan her şey düz metin duruyor, süresiz birikmemeli.
    static let retentionDays = 30
    private static var retention: TimeInterval { Double(retentionDays) * 24 * 3600 }

    private(set) var entries: [HistoryEntry] = []
    var onChange: (() -> Void)?

    private var fileURL: URL { Support.directory.appendingPathComponent("history.jsonl") }

    private init() { load() }

    /// - Parameter samples: diktenin ham sesi. Saklanınca kötü çıkan bir
    ///   çeviri baştan konuşmadan yeniden denenebiliyor.
    func add(text: String, app: String?, seconds: Double?, samples: [Float] = []) {
        var entry = HistoryEntry(text: text, app: app, seconds: seconds)
        entry.audio = Recordings.save(samples, id: entry.id)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }

        // Süresi dolmuş kayıt varsa dosyayı baştan yaz, yoksa sadece ekle.
        if prune() {
            rewrite()
        } else {
            append(entry)
        }
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

    /// Yeniden çevrilen bir kaydın metnini değiştirir.
    ///
    /// Satır ekleme yerine dosyayı baştan yazıyoruz: JSON Lines'da bir satırı
    /// yerinde güncellemenin ucuz bir yolu yok ve geçmiş birkaç yüz KB.
    func update(id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = text
        entries[index].retranscribed = true
        rewrite()
        onChange?()
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
        // Ses metinden daha hassas — geçmiş temizlenirken o da gitmeli.
        Recordings.clear()
        onChange?()
        Trace.log("geçmiş temizlendi")
    }

    /// Süresi dolmuş kayıtları bellekten düşür. Bir şey silindiyse `true` döner.
    @discardableResult
    private func prune() -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        let before = entries.count
        entries.removeAll { $0.date < cutoff }
        let removed = before - entries.count
        if removed > 0 {
            Trace.log("geçmiş: \(removed) kayıt \(Self.retentionDays) günden eski, silindi")
        }
        return removed > 0
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
        if prune() { rewrite() }
    }

    /// Dosyayı bellekteki hâlden yeniden üret. `entries` en yeni önce tutuluyor,
    /// dosya ise eskiden yeniye — bu yüzden ters çevriliyor.
    private func rewrite() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = entries.reversed().compactMap { entry -> String? in
            guard let data = try? encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let body = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try? body.write(to: fileURL, atomically: true, encoding: .utf8)
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
