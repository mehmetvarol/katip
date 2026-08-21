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
        /// Bu parçanın konuşması BAŞLAMADAN önceki duraklamanın tam uzunluğu.
        ///
        /// Neden "önce" ve neden ayrı ölçülüyor: kesim, eşiğe (`minSilence`)
        /// değer değmez atılıyor — gecikmeyi gizlemek için şart, çeviri
        /// kullanıcı hâlâ konuşurken başlasın diye. Ama bu, kesim ANINDA
        /// duraklamanın daha ne kadar süreceğini bilmediğimiz anlamına
        /// geliyor. İlk sürüm bu yüzden BOZUKTU: her kesim eşiğin kendisini
        /// (0.8 sn) raporluyordu, gerçek 3 saniyelik düşünme molalarını bile.
        /// Gerçek kayıtta ölçüldü — dört kesimin dördü de 0.8 sn dedi.
        ///
        /// Doğrusu: kesimi yine erken at, ama sessizliği konuşma yeniden
        /// başlayana kadar SAYMAYA DEVAM ET ve ölçümü bir SONRAKİ parçaya ilikle.
        var silenceBefore: TimeInterval
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

    /// Kesimden sonra süren sessizliği ölçüyoruz (bkz. `Cut.silenceBefore`).
    private var measuringGap = false
    private var gapFrames = 0
    /// Konuşma yeniden başlayınca dondurulan, bir sonraki kesimde raporlanacak boşluk.
    private var nextGap: TimeInterval = 0

    /// Şu an ölçülmekte olan boşluk. Kayıt kullanıcı tarafından bitirildiğinde
    /// son artık parçanın önündeki boşluğu okumak için gerekiyor.
    var currentGap: TimeInterval {
        measuringGap ? Double(gapFrames) / sampleRate : nextGap
    }

    mutating func reset() {
        isSpeaking = false
        speechFrames = 0
        silenceFrames = 0
        measuringGap = false
        gapFrames = 0
        nextGap = 0
    }

    /// Yeni bir ses bloğu besle. Cümle bittiyse tampondaki kesim noktasını döner.
    ///
    /// Kesim sessizliğin BAŞINA konur (biraz payla): sessizliği de modele
    /// göndermek Whisper'ı Türkçe'de uydurma altyazı üretmeye itiyor.
    mutating func feed(peak: Float, frames: Int, bufferedSamples: Int) -> Cut? {
        if peak > speechPeak {
            // Konuşma döndü → ölçtüğümüz boşluk tamamlandı, dondur.
            if measuringGap {
                nextGap = Double(gapFrames) / sampleRate
                measuringGap = false
                gapFrames = 0
            }
            if !isSpeaking { isSpeaking = true; speechFrames = 0 }
            speechFrames += frames
            silenceFrames = 0
            return nil
        }

        // Bu, `isSpeaking` kapısından ÖNCE olmalı: kesimden sonra `isSpeaking`
        // false ve boşluk asıl o zaman uzuyor.
        if measuringGap { gapFrames += frames }

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

        // Bu parçanın ÖNÜNDEKİ boşluk, bir önceki kesimden beri ölçülen.
        let gapBefore = nextGap
        nextGap = 0

        // Şu anda tükettiğimiz sessizlik, bir SONRAKİ parçanın önündeki
        // boşluğun başlangıcı — saymaya oradan devam ediyoruz.
        measuringGap = true
        gapFrames = silenceFrames

        isSpeaking = false
        speechFrames = 0
        silenceFrames = 0
        return Cut(index: min(cut, bufferedSamples), silenceBefore: gapBefore)
    }
}
