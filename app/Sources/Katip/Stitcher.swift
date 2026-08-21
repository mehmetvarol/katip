import Foundation

/// Ayrı ayrı çevrilmiş dikte parçalarını TEK bir metne diker.
///
/// Neden gerekli: her VAD parçası Whisper'a bağımsız bir ses klibi olarak
/// gidiyor. Model her klibi yeni bir söyleyiş sanıyor, dolayısıyla dikişlerde
/// iki tür hata üretiyor (ikisi de gerçek log'dan):
///
///   1. Uydurma cümle sonu — nefes almak için durduğunda parçayı noktalayıp
///      sonrakini büyük harfle başlatıyor:
///      "…dosyaya çıkart." + "Ve persist middleware'ini de ekle."
///   2. Kayıp noktalama — gerçek cümle sonunda hiç nokta koymuyor:
///      "…o kadar değişiklik yaptık" + "hiç komik görünmüyor"
///
/// ## Süre eşiği denendi ve çürütüldü
///
/// İlk sürüm ayrımı **duraklama süresine** bakarak yapıyordu: kısa boşluk
/// nefes, uzun boşluk cümle sonu. Fikir makuldü, ölçüm çürüttü.
///
/// Gerçek dikte kayıtlarından 7 dikiş etiketlenip ölçüldü (2026-08-21;
/// ayrıntı vault'ta `2026-08-21-katip-duraklama-esigi-olcumu`):
///
///     cümle SÜRÜYOR : 0.8  0.9  1.7  2.1 sn
///     cümle SONU    : 1.2  1.4       2.8 sn
///
/// İki sınıf tamamen iç içe — üstelik en KISA boşluk (0.8 sn) cümle ortası,
/// en UZUNU (2.8 sn) cümle sonu. Ayıran hiçbir eşik yok ve daha büyük bir
/// örneklem de yaratamaz, çünkü konuşmada duraklama uzunluğu sözdizimini
/// değil BİLİŞSEL YÜKÜ ölçüyor: 2.1 saniyelik boşlukta kullanıcı "…dosyaya
/// çıkart" deyip durmuş, İngilizce terimi hatırlayıp "ve persist
/// middleware'ini de ekle" diye DEVAM etmişti.
///
/// Karar bu yüzden artık yalnızca KELİMEYE bakıyor. Süre ölçümü
/// `SpeechSegmenter`'da duruyor — log ve `--vadtest` için değerli, ama
/// hiçbir kararı beslemiyor.
enum Stitcher {
    private static let turkish = Locale(identifier: "tr_TR")
    private static let terminators: Set<Character> = [".", "!", "?", "…", ":", ";", ","]

    /// Bir cümlenin BAŞINDA neredeyse hiç bulunmayan bağlaç ve edatlar.
    ///
    /// Whisper'ın koyduğu noktayı yalnızca burada listelenen bir kelime
    /// izliyorsa siliyoruz. Liste bilerek DAR: özel isimleri küçültme riski
    /// almıyoruz ve asimetriyi gözetiyoruz — cümle ortasında fazladan bir
    /// nokta okumayı zorlaştırır ama anlamı korur, meşru bir noktayı silmek
    /// ise iki cümleyi birbirine yapıştırır. İlk denemede "ben", "bu", "şimdi"
    /// gibi kelimeler de listedeydi ve gerçek log'daki "…yanlış anlaşılma
    /// var." + "Ben canlı görsel istemiyorum." çiftini yapıştırdı; hepsi
    /// çıkarıldı.
    ///
    /// Türkçe yazıda "Ama"/"Çünkü" ile cümleye başlamak mümkün — yani bu
    /// kural bazen meşru bir bölmeyi birleştirecek. Kabul edilen takas: dikte
    /// edilen metinde bağlaçla başlayan bir parça, cümlenin devamı olma
    /// ihtimali çok daha yüksek.
    private static let continuations: Set<String> = [
        "ve", "veya", "ya", "ki", "de", "da", "yani", "çünkü", "zira",
        "ama", "fakat", "ancak", "hem",
        "için", "gibi", "ile", "kadar", "diye", "göre", "rağmen",
    ]

    static func join(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            let text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !out.isEmpty else { out = text; continue }

            if startsWithContinuation(text) {
                out = dropSentenceEnd(out)
                out += " " + lowercasedFirst(text)
            } else {
                out = ensureSentenceEnd(out)
                out += " " + capitalizedFirst(text)
            }
        }
        return out
    }

    /// Nefes duraklamasında Whisper'ın koyduğu sahte noktayı kaldır.
    ///
    /// "?" ve "!" DOKUNULMAZ: onları model rastgele koymuyor, gerçekten soru
    /// veya ünlem tonu duyduğunda koyuyor. "…" da bilinçli bir işaret.
    private static func dropSentenceEnd(_ text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        return String(text.dropLast())
    }

    private static func ensureSentenceEnd(_ text: String) -> String {
        guard let last = text.last, !terminators.contains(last) else { return text }
        return text + "."
    }

    private static func startsWithContinuation(_ text: String) -> Bool {
        let word = text.prefix(while: { $0.isLetter })
        return !word.isEmpty && continuations.contains(String(word).lowercased(with: turkish))
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        return String(first).lowercased(with: turkish) + String(text.dropFirst())
    }

    private static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return String(first).uppercased(with: turkish) + String(text.dropFirst())
    }
}
