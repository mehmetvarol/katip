import Foundation

/// Metin kısayolları: söylediğin kısa bir tetikleyici, hazır bir metin bloğuna
/// genişler. Vibe coding'de tekrar tekrar söylediğin kalıplar için —
/// proje bağlamı, kodlama kuralları, standart prompt önekleri.
///
/// `Replacements`'tan farkı amaç: o **yanlışı düzeltir**, bu **kısayı uzatır**.
/// Bu yüzden sırayla çalışıyorlar: önce düzeltme (tetikleyici yanlış duyulduysa
/// düzelsin), sonra genişletme.
///
/// Dosya: ~/Library/Application Support/Katip/snippets.txt
enum Snippets {
    static var fileURL: URL {
        Support.directory.appendingPathComponent("snippets.txt")
    }

    static func apply(to text: String) -> String {
        var out = text
        for (trigger, expansion) in load() {
            // Tetikleyici bilinçli söylenen bir ifade; kelime sınırlarıyla ara.
            var pattern = "\\b\(NSRegularExpression.escapedPattern(for: trigger))\\b"

            // Genişleyen blok zaten noktalamayla bitiyorsa, tetikleyicinin kendi
            // noktasını da MAÇA DAHİL ET — yoksa "açıkla.." çıkıyor.
            //
            // Bunu metnin tamamını temizleyerek yapmak cazip ama yanlış: öyle
            // denendiğinde "gerçekten mi?!" → "gerçekten mi?" ve "üç nokta..."
            // → "üç nokta." oldu. Düzeltme sadece dikişin olduğu yerde olmalı.
            if let last = expansion.last, ".!?".contains(last) {
                pattern += "\\s*[.!?]?"
            }

            out = out.replacingOccurrences(
                of: pattern, with: expansion,
                options: [.regularExpression, .caseInsensitive])
        }
        return out
    }

    static func load() -> [(String, String)] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? defaultFile.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            // \n yazarak çok satırlı blok tanımlanabilsin.
            return (parts[0], parts[1].replacingOccurrences(of: "\\n", with: "\n"))
        }
    }

    /// Varsayılan dosyada AKTİF kural yok — hepsi yorumlu örnek.
    /// Gerekçe: beklenmedik bir tetikleyicinin konuşmanın ortasında ateşlenip
    /// metni genişletmesi, kaçırılan bir terimden çok daha rahatsız edici.
    private static let defaultFile = """
    # Katip — metin kısayolları
    #
    # Söylediğin kısa bir ifade, hazır bir metin bloğuna genişler.
    # Biçim:  tetikleyici = genişletilecek metin
    # Çok satır için \\n kullan.
    #
    # ⚠️ Tetikleyiciyi AYIRT EDİCİ seç. "prompt" gibi tek ve yaygın bir kelime
    #    seçersen normal konuşmanın ortasında ateşlenir. İki kelimeli,
    #    günlük konuşmada geçmeyecek ifadeler iyi çalışır.
    #
    # Aşağıdakiler örnek — kullanmak için başındaki # işaretini kaldır.

    # standart bağlam = Proje: Next.js 16 + TypeScript + Tailwind 4. Türkçe açıkla, kod bloğu ver.
    # kodlama kuralları = Temiz kod, gereksiz yorum yok, mevcut desenlere uy, test yaz.
    # inceleme isteği = Bu değişikliği gözden geçir: hata, sadeleştirme ve performans açısından bak.
    # imza bloğu = \\n--\\nMehmet Varol

    """
}
