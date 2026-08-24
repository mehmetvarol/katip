import Foundation

/// Sözlükteki terimlere YAKIN ama tam eşleşmeyen kelimeleri düzeltir.
///
/// `Replacements` tam eşleşme ister — "Zostan" için kural yazılmamışsa hiç
/// yakalamaz, her yeni yanlış duyma elle bir satır eklemeyi gerektirir. Bu
/// katman, sözlükteki (`Glossary.load()`) her terime karşı düzenleme mesafesi
/// (Levenshtein) ölçüp yeterince yakınsa OTOMATİK düzeltiyor — kural yazmadan.
///
/// Replacements'ın YERİNE değil YANINDA: kesin kural her zaman önce çalışır
/// ve daha ucuzdur. Bu katman yalnızca henüz kural yazılmamış varyasyonlar
/// için bir güvenlik ağı.
///
/// ## Eşik ölçümle seçildi, tahminle değil
///
/// İlk deneme daha gevşek bir eşikle (terim uzunluğunun ~%35'i) kuruldu ve
/// 107 kayıtlık GERÇEK dikte geçmişinde sınandı. Sonuç kabul edilemezdi —
/// sıradan Türkçe kelimeler teknik terimlere yanlışlıkla eşleşti:
///
///     "sistem"  → "statem"   (mesafe 2, "sistem" gayet doğru bir kelime)
///     "tane"    → "state"    (mesafe 2, "bir tane" — çok sık kullanılan kelime)
///     "Store"   → "state"    (mesafe 2, Zustand'ın KENDİ terimi, state değil)
///
/// Eşik `len ≤ 6 → 1, else → 2`'ye sıkılaştırılınca aynı 107 kayıt + 1906
/// kelimede yanlış pozitif SIFIRA indi, gerçek vakaların 4'ü hâlâ yakalanıyor:
///
///     "zostan"     → Zustand   (mesafe 2)
///     "persis"     → persist   (mesafe 1)
///     "komponent"  → component (mesafe 1)
///     "kompanent"  → component (mesafe 2)
///
/// Bilinen bir sınır: "sted"→state ve "cokey"→cookie bu eşikle YAKALANMIYOR
/// (gerçek düzenleme mesafeleri 3 — sıkı eşiğin izin verdiğinden fazla).
/// Onları yakalayacak kadar gevşetmek yukarıdaki yanlış pozitifleri geri
/// getiriyor — harf-düzeyinde bir ölçüm, sesli harf düşüren bu tip fonetik
/// hataları sıradan kelimelerden güvenle ayıramıyor. Bu ikisi `replacements.txt`
/// ile (kesin kural) kapalı kalmaya devam ediyor; oradaki mevcut kurallar
/// zaten bunları kapsıyor.
enum FuzzyTerms {
    /// Bundan kısa kelimeler denenmiyor — kısa kelimede 1 harflik fark anlamı
    /// tamamen değiştirebilir, yanlış pozitif riski orantısız büyür.
    private static let minWordLength = 4

    private static func tolerance(for term: String) -> Int {
        term.count <= 6 ? 1 : 2
    }

    private static let turkish = Locale(identifier: "tr_TR")

    static func correct(_ text: String, terms: [String]) -> String {
        let candidates = terms.filter { $0.count >= minWordLength }
        guard !candidates.isEmpty else { return text }

        // Harf dizilerini (kelimeleri) bul, aralarını AYNEN koru — noktalama,
        // apostrof, boşluk dokunulmuyor. `Replacements`'la aynı ilke: kök
        // düzeltilir, ek (varsa) serbest kalır.
        let pattern = try! NSRegularExpression(pattern: "[\\p{L}]+")
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let word = ns.substring(with: match.range)
            if let m = bestMatch(for: word, in: candidates) {
                out += m.term + m.suffix
            } else {
                out += word
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// En yakın terimi bulur. `nil` dönerse kelime dokunulmadan kalır.
    static func bestMatch(for word: String, in candidates: [String]) -> (term: String, suffix: String, distance: Int)? {
        guard word.count >= minWordLength else { return nil }
        let lower = word.lowercased(with: turkish)
        // Zaten doğruysa (herhangi bir terimin kendisiyse) dokunma.
        guard !candidates.contains(where: { $0.lowercased(with: turkish) == lower }) else { return nil }

        var best: (term: String, suffix: String, distance: Int)?
        for term in candidates {
            let termLower = term.lowercased(with: turkish)
            // Uzunluk çok farklıysa mesafe hesaplamaya bile gerek yok.
            guard abs(termLower.count - lower.count) <= 3 else { continue }

            let distance = levenshtein(lower, termLower)
            if distance <= tolerance(for: term), best.map({ distance < $0.distance }) ?? true {
                best = (term, "", distance)
            }

            // Önek karşılaştırması: Türkçe eki apostrofsuz bitişik gelmiş
            // olabilir ("componenti" = "component" + "i").
            if lower.count > termLower.count {
                let prefix = String(lower.prefix(termLower.count))
                let suffix = String(lower.dropFirst(termLower.count))
                let prefixDistance = levenshtein(prefix, termLower)
                if prefixDistance <= tolerance(for: term),
                   best.map({ prefixDistance < $0.distance }) ?? true {
                    best = (term, suffix, prefixDistance)
                }
            }
        }
        return best
    }

    /// Standart düzenleme (Levenshtein) mesafesi — tek satır fark bile
    /// tek bir ekleme/silme/değiştirme sayılır.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                curr[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : 1 + min(prev[j - 1], prev[j], curr[j - 1])
            }
            prev = curr
        }
        return prev[b.count]
    }
}
