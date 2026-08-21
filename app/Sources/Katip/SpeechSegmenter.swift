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
    /// Kesim noktası + kesime SEBEP OLAN sessizliğin uzunluğu.
    ///
    /// Sessizlik süresi kalite için kritik: 0.5 sn'lik bir duraklama nefes/düşünme
    /// (cümle SÜRÜYOR), 1.5 sn'lik bir duraklama gerçek cümle sonu. Parçalar ayrı
    /// çevrildiği için bu ayrımı Whisper yapamaz — dikişi biz onarıyoruz
    /// (bkz. `DictationController.stitch`).
    struct Cut {
        var index: Int
        var silence: TimeInterval
    }

    var speechPeak: Float = 0.03
    var minSpeech: TimeInterval = 0.6      // bundan kısa parçayı gönderme
    var minSilence: TimeInterval = 0.7     // bu kadar sessizlik = kesme noktası
    var tailPadding: TimeInterval = 0.15   // kesime biraz sessizlik ekle
    var sampleRate: Double = 16_000

    /// Bundan kısa bir tampon KESİLMEZ, sonraki parçaya eklenir.
    ///
    /// Whisper 30 saniyelik pencerelerle eğitildi; 2 saniyelik bir kırpıntı
    /// dağılım dışı kalıyor ve hem kelimeleri hem noktalamayı kötü tahmin
    /// ediyor. Log'da ölçüldü: 2.7 sn'lik parça "hiç komik görünmüyor" diye
    /// noktalamasız çıktı, 8.8 sn'lik parça düzgün iki cümle üretti.
    var minSegment: TimeInterval = 4.0

    private var isSpeaking = false
    private var speechFrames = 0
    private var silenceFrames = 0

    mutating func reset() {
        isSpeaking = false
        speechFrames = 0
        silenceFrames = 0
    }

    /// Yeni bir ses bloğu besle. Cümle bittiyse tampondaki kesim noktasını döner.
    ///
    /// Kesim sessizliğin BAŞINA konur (biraz payla): sessizliği de modele
    /// göndermek Whisper'ı Türkçe'de uydurma altyazı üretmeye itiyor.
    mutating func feed(peak: Float, frames: Int, bufferedSamples: Int) -> Cut? {
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

        // Parça çok kısaysa kesme — sayaçları SIFIRLAMADAN bekle, konuşma
        // devam edince aynı tampona eklensin. (Kesmiş gibi davranıp `nil`
        // dönmek konuşma sürerken parçayı sonsuza kadar büyütürdü; burada
        // sadece bu kesimden vazgeçiyoruz.)
        guard Double(cut) / sampleRate >= minSegment else { return nil }

        let silence = Double(silenceFrames) / sampleRate
        isSpeaking = false
        speechFrames = 0
        silenceFrames = 0
        return Cut(index: min(cut, bufferedSamples), silence: silence)
    }
}
