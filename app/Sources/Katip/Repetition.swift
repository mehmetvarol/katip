import Foundation

/// Decoder'ın tekrar döngüsüne düşüp düşmediğini ölçer.
///
/// Ayrı bir tip olmasının sebebi test edilebilirlik — `SpeechSegmenter` ile
/// aynı gerekçe. Modeli çalıştırmadan, kaydedilmiş arıza çıktısı üzerinden
/// doğrulanabiliyor (`Katip --repetitiontest`).
///
/// Neden gerekli: bağlam yönlendirmesi (`Transcriber.transcribe(_:context:)`)
/// decoder'ı önceki metne kilitleyebiliyor. WhisperKit'in kendi
/// `compressionRatioThreshold` geri çekilmesi bu vakayı KAÇIRDI — beş sıcaklık
/// denemesinin beşi de döngüye düştü (ölçüldü: jfk.wav + uyumsuz bağlam).
enum Repetition {
    /// Tek bir kelimenin metinde kaplayabileceği en büyük pay.
    ///
    /// Gerçek konuşmada bir kelime metnin üçte birini kaplamaz; döngüde
    /// yarısını kaplıyor. Aradaki boşluk geniş, eşik hassas değil.
    static let dominanceLimit = 0.33

    /// Bu kadar kelimeden kısa metinlerde ölçüm anlamsız — "evet evet evet"
    /// masum bir cevap, döngü değil.
    static let minimumWords = 8

    static func isRepetitive(_ text: String) -> Bool {
        let words = text.lowercased(with: Locale(identifier: "tr_TR"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 2 }
        guard words.count >= minimumWords else { return false }

        var counts: [String: Int] = [:]
        for word in words { counts[String(word), default: 0] += 1 }
        guard let top = counts.values.max() else { return false }
        return Double(top) / Double(words.count) > dominanceLimit
    }
}
