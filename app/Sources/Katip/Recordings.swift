import AVFoundation
import Foundation

/// Diktelerin HAM SESİNİ saklar, böylece kötü çıkan bir çeviri baştan
/// konuşmadan yeniden denenebilir.
///
/// İkinci ve asıl gerekçe ölçüm: bu proje boyunca kalite değişiklikleri
/// İngilizce `jfk.wav` ile ölçülmek zorunda kaldı, çünkü elde tek bir Türkçe
/// test sesi yoktu. Burada biriken kayıtlar kendiliğinden bir regresyon
/// korpusu oluşturuyor (`Katip --selftest <kayıt>`).
///
/// ⚠️ Gizlilik: bu klasörde SESİN duruyor, metnin değil. Sınırlı tutuluyor
/// (son `limit` kayıt) ve menüden tamamen silinebilir.
enum Recordings {
    /// Kaç kayıt saklanacak. 16 kHz / 16-bit mono ≈ 32 KB/sn; ortalama dikte
    /// 71 sn ölçüldü → kayıt başına ~2,3 MB, 20 kayıt ~45 MB. Sesin süresiz
    /// birikmesi hem disk hem gizlilik açısından yanlış olurdu.
    static let limit = 20

    static let sampleRate = 16_000.0

    static var directory: URL {
        let dir = Support.directory.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Kaydı diske yazar ve geçmişte saklanacak dosya adını döner.
    ///
    /// Float32 yerine 16-bit PCM: dosyayı yarıya indiriyor ve kayıp yok sayılır —
    /// mikrofon zaten 16/24-bit veriyor, Whisper'ın girdisi de bu sesten
    /// türüyor.
    static func save(_ samples: [Float], id: UUID) -> String? {
        guard !samples.isEmpty else { return nil }
        let name = "\(id.uuidString).wav"
        let url = directory.appendingPathComponent(name)

        guard let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: 1, interleaved: true),
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: source,
                                            frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count)
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: output.settings)
            try file.write(from: buffer)
        } catch {
            Trace.log("kayıt yazılamadı: \(error)")
            return nil
        }
        prune()
        return name
    }

    static func load(_ name: String) throws -> [Float] {
        let url = directory.appendingPathComponent(name)
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length))
        else { throw CocoaError(.fileReadUnknown) }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw CocoaError(.fileReadUnknown) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
    }

    /// Toplam boyut — kullanıcı ne kadar ses biriktiğini görebilmeli.
    static var totalBytes: Int {
        files().reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func clear() {
        for url in files() { try? FileManager.default.removeItem(at: url) }
        Trace.log("ses kayıtları silindi")
    }

    /// En yeni `limit` kaydı bırak, gerisini sil.
    private static func prune() {
        let sorted = files().sorted { a, b in date(of: a) > date(of: b) }
        guard sorted.count > limit else { return }
        for url in sorted.dropFirst(limit) { try? FileManager.default.removeItem(at: url) }
        Trace.log("ses kayıtları: \(sorted.count - limit) eski dosya silindi")
    }

    private static func files() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        return (contents ?? []).filter { $0.pathExtension == "wav" }
    }

    private static func date(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }
}
