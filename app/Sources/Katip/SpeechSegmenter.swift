import Foundation

/// Konuşmayı cümle aralarındaki sessizlikten bölen basit enerji tabanlı VAD.
///
/// Ayrı bir tip olmasının sebebi **test edilebilirlik**: mikrofon olmadan, hazır
/// bir ses dosyası üzerinden kesim noktalarını doğrulayabiliyoruz
/// (`Katip --vadtest ses.wav`).
///
/// Eşikler tahminle değil ölçümle seçildi: gerçek konuşmada tepe ~0.38,
/// sessiz kayıtlarda 0.004-0.006.
struct SpeechSegmenter {
    var speechPeak: Float = 0.03
    var minSpeech: TimeInterval = 0.6      // bundan kısa parçayı gönderme
    var minSilence: TimeInterval = 0.45    // bu kadar sessizlik = cümle bitti
    var tailPadding: TimeInterval = 0.15   // kesime biraz sessizlik ekle
    var sampleRate: Double = 16_000

    private var isSpeaking = false
    private var speechFrames = 0
    private var silenceFrames = 0

    mutating func reset() {
        isSpeaking = false
        speechFrames = 0
        silenceFrames = 0
    }

    /// Yeni bir ses bloğu besle. Cümle bittiyse tampondaki kesim indeksini döner.
    ///
    /// Kesim sessizliğin BAŞINA konur (biraz payla): sessizliği de modele
    /// göndermek Whisper'ı Türkçe'de uydurma altyazı üretmeye itiyor.
    mutating func feed(peak: Float, frames: Int, bufferedSamples: Int) -> Int? {
        if peak > speechPeak {
            if !isSpeaking { isSpeaking = true; speechFrames = 0 }
            speechFrames += frames
            silenceFrames = 0
            return nil
        }

        guard isSpeaking else { return nil }
        silenceFrames += frames

        guard Double(silenceFrames) / sampleRate >= minSilence,
              Double(speechFrames) / sampleRate >= minSpeech else { return nil }

        let padding = Int(tailPadding * sampleRate)
        let cut = max(1, bufferedSamples - silenceFrames + padding)
        isSpeaking = false
        speechFrames = 0
        silenceFrames = 0
        return min(cut, bufferedSamples)
    }
}
