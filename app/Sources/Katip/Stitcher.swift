import Foundation

/// Ayrı ayrı çevrilmiş dikte parçalarını TEK bir metne diker.
///
/// Neden gerekli: her VAD parçası Whisper'a bağımsız bir ses klibi olarak
/// gidiyor. Model her klibi yeni bir söyleyiş sanıyor, dolayısıyla dikişlerde
/// iki tür hata üretiyor (ikisi de gerçek log'dan):
///
///   1. Uydurma cümle sonu — nefes almak için durduğunda parçayı noktalayıp
///      sonrakini büyük harfle başlatıyor:
///      "…yanlış anlaşılma var." + "Ben canlı görsel istemiyorum."
///   2. Kayıp noktalama — gerçek cümle sonunda hiç nokta koymuyor:
///      "…o kadar değişiklik yaptık" + "hiç komik görünmüyor"
///
/// Ayrımı yapabilecek tek bilgi Whisper'da değil bizde: **kesime sebep olan
/// sessizliğin uzunluğu**. Kısa duraklama = cümle sürüyor, uzun duraklama =
/// cümle bitti. `SpeechSegmenter.Cut.silence` bunu taşıyor.
enum Stitcher {
    struct Piece {
        var text: String
        /// Bu parçadan ÖNCEKİ duraklamanın uzunluğu. İlk parçada anlamsız.
        ///
        /// "Sonraki" değil "önceki" olması teknik bir zorunluluk: kesim
        /// eşiğe değer değmez atılıyor, duraklamanın gerçek uzunluğu ancak
        /// konuşma geri döndüğünde biliniyor (bkz. `SpeechSegmenter.Cut`).
        var silenceBefore: TimeInterval
    }

    /// Bu eşiğin ALTI nefes/düşünme, ÜSTÜ cümle sonu sayılır.
    ///
    /// VAD zaten ≥0.7 sn sessizlikte kesiyor, yani buradaki bütün duraklamalar
    /// 0.7 sn'den uzun. 1.1 sn "durup düşündüm" ile "cümleyi bitirdim" arasında
    /// makul bir sınır; yanlış tarafa düşmenin bedeli tek bir noktalama işareti.
    static let sentenceGap: TimeInterval = 1.1

    private static let turkish = Locale(identifier: "tr_TR")
    private static let terminators: Set<Character> = [".", "!", "?", "…", ":", ";", ","]

    /// Bir cümlenin BAŞINDA neredeyse hiç bulunmayan bağlaç ve edatlar.
    ///
    /// Whisper'ın koyduğu noktayı yalnızca burada listelenen bir kelime
    /// izliyorsa siliyoruz. Liste bilerek DAR: özel isimleri küçültme riski
    /// almıyoruz ve asimetriyi gözetiyoruz — cümle ortasında fazladan bir
    /// nokta okumayı zorlaştırır ama anlamı korur, meşru bir noktayı silmek
    /// ise iki cümleyi birbirine yapıştırır. İlk denemede "ben", "bu", "şimdi"
    /// gibi kelimeler de listedeydi ve gerçek log'daki "…yanlış anlaşılma var."
    /// + "Ben canlı görsel istemiyorum." çiftini yapıştırdı; hepsi çıkarıldı.
    private static let continuations: Set<String> = [
        "ve", "veya", "ya", "ki", "de", "da", "yani", "çünkü", "zira",
        "ama", "fakat", "ancak", "hem",
        "için", "gibi", "ile", "kadar", "diye", "göre", "rağmen",
    ]

    static func join(_ pieces: [Piece]) -> String {
        var out = ""
        for (index, piece) in pieces.enumerated() {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard !out.isEmpty else { out = text; continue }

            // Dikişin türünü ÖNCEKİ parçanın sessizliği belirler.
            let gap = piece.silenceBefore
            if gap < sentenceGap, startsWithContinuation(text) {
                // Kısa duraklama VE bağlaçla devam → cümle sürüyor.
                out = dropSentenceEnd(out)
                out += " " + lowercasedFirst(text)
            } else if gap >= sentenceGap {
                out = ensureSentenceEnd(out)
                out += " " + capitalizedFirst(text)
            } else {
                // Kararsız dikiş: modelin yazdığına DOKUNMA.
                out += " " + text
            }
        }
        return out
    }

    /// Nefes duraklamasında Whisper'ın koyduğu sahte noktayı kaldır.
    ///
    /// "?" ve "!" DOKUNULMAZ: onları model rastgele koymuyor, gerçekten soru
    /// veya ünlem tonu duyduğunda koyuyor. "…" da bilinçli bir işaret.
    private static func dropSentenceEnd(_ text: String) -> String {
        guard text.hasSuffix(".") , !text.hasSuffix("..") else { return text }
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
