import Foundation

/// Teknik terim sözlüğü — Whisper'a "bu kelimeleri böyle yaz" ipucu verir.
///
/// Bütçe **111 token** (`Constants.maxTokenContext / 2 - 1`) ve WhisperKit
/// bütçe aşımında `promptTokens.suffix()` ile SONU tutuyor
/// → **kritik terimler listenin SONUNDA.**
/// (P0 tezgâhındaki `glossary.txt` faster-whisper içindi ve tam tersi sıradaydı.)
///
/// Dosyadan okunur: ~/Library/Application Support/Katip/glossary.txt
/// Dosya yoksa varsayılan liste yazılır ve kullanılır.
enum Glossary {
    static var promptText: String {
        let terms = load()
        return terms.joined(separator: ", ")
    }

    static var fileURL: URL {
        Support.directory.appendingPathComponent("glossary.txt")
    }

    static func load() -> [String] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? defaultFile.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return defaultTerms
        }
        let terms = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return terms.isEmpty ? defaultTerms : terms
    }

    /// Bütçe **40 token** (`Transcriber.glossaryTokenBudget`) ve WhisperKit
    /// gibi biz de SONU tutuyoruz → **kritik terimler listenin SONUNDA.**
    ///
    /// Liste ölçümle yeniden yazıldı (2026-08-21). Eski liste `refactor`,
    /// `deploy`, `state` gibi yaygın terimleri BİLEREK dışarıda bırakıyordu —
    /// gerekçe "P0 duman testinde ipucu olmadan da doğru çıktılar"dı. Gerçek
    /// Türkçe kayıtlar bu varsayımı çürüttü; aynı terimler dikte içinde
    /// şöyle çıktı:
    ///
    ///     state       → "sted"                deploy    → "Dipliya"
    ///     persist     → "Persis"              cookie    → "COKEY"
    ///     localStorage→ "localized storage"   Zustand   → "Zostan"
    ///
    /// Duman testi tek bir terimi sessiz bir bağlamda söylüyordu; gerçek
    /// dikte terimi hızlı Türkçe bir cümlenin ORTASINDA söylüyor. İkincisi
    /// çok daha zor ve ölçümü yapılması gereken tek şey oydu.
    ///
    /// Bütçe dar olduğu için liste kısa: kazanç boyuttan değil İSABETTEN
    /// geliyor. 109 token'lık eski liste ölçümde hiçbir şey düzeltmedi ve
    /// çeviriyi iki katına çıkardı, çünkü aranan terim içinde yoktu.
    /// Hepsi gerçek kayıtta bozulmuş terimler; spekülatif giriş yok.
    /// Sıra önemli — bütçe aşılırsa baştakiler düşer, o yüzden en sık
    /// bozulanlar sonda.
    static let defaultTerms = [
        "Claude Code", "Zustand", "middleware", "component",
        "deploy", "cookie", "httpOnly", "persist", "state", "localStorage",
    ]

    private static var defaultFile: String {
        """
        # Katip — teknik terim sözlüğü
        #
        # Whisper'a "bu kelimeleri böyle yaz" ipucu verir.
        #
        # ⚠️ KISA TUT. Bütçe 40 token ve her token ~0.02 sn gecikme demek.
        # Ölçüldü: isabetli 23 token'lık liste terimi düzeltti (+0.47 sn),
        # alakasız 109 token'lık liste hiçbir şey düzeltmedi (+2.37 sn).
        # Kazanç boyuttan değil isabetten geliyor.
        #
        # ⚠️ SIRA ÖNEMLİ: bütçe aşılırsa BAŞTAKİLER düşer.
        # En kritik / en nadir terimleri EN SONA yaz.
        # Uygulama açılışta gerçek token sayısını katip.log'a yazar.
        #
        # Buraya yalnızca DİKTEDE GERÇEKTEN BOZULAN terimleri ekle. Whisper'ın
        # zaten doğru yazdığı bir kelimeye bütçe harcamak, gerçekten gereken
        # bir terimi listeden düşürür.
        #
        # Her satırda virgülle ayrılmış terimler. '#' ile başlayan satırlar yok sayılır.
        # Değişiklik için uygulamayı yeniden başlat.

        \(defaultTerms.joined(separator: ", "))

        """
    }
}

/// Whisper'ın ısrarla fonetiğe kaçtığı terimler için deterministik düzeltme.
///
/// Neden gerekli: P0 duman testinde `hook` sözlükte olmasına rağmen "Hawk"
/// olarak çıktı. Prompt yönlendirmesi gümüş kurşun değil — bu katman şart.
enum Replacements {
    static var fileURL: URL {
        Support.directory.appendingPathComponent("replacements.txt")
    }

    /// Türkçe ekler yüzünden SADECE BAŞTA kelime sınırı arıyoruz.
    ///
    /// `\bkomponent\b` yazsaydık "komponent**i**" hiç eşleşmezdi — Türkçe'de
    /// terimler neredeyse her zaman ek alır (komponenti, store'una, query'de).
    /// Baş sınırı + serbest son sayesinde kök değişir, ek yerinde kalır:
    ///   "komponenti"  →  "componenti"
    ///   "zustant'a"   →  "Zustand'a"
    static func apply(to text: String) -> String {
        var out = text
        for (wrong, right) in load() {
            out = out.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: wrong))",
                with: right,
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
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    private static let defaultFile = """
    # Katip — düzeltme tablosu
    #
    # Whisper'ın senin telaffuzunla çözemediği terimleri kural tabanlı düzeltir.
    # Sıfır gecikme, tam kontrol — sözlük yönlendirmesinin (~2 sn) yapamadığını
    # bedavaya yapar. Asıl kaliteyi bu dosya belirler.
    #
    # Biçim:  yanlış = doğru      (büyük/küçük harf duyarsız)
    #
    # Eşleşme SADECE kelime BAŞINDA sınır arar, sonu serbesttir — çünkü Türkçe'de
    # terimler ek alır. "komponent = component" kuralı "komponenti"yi de düzeltir
    # ve ek korunur → "componenti".
    #
    # Dikkat: sonu serbest olduğu için kısa/yaygın kelimeleri kural yapma.
    # ("boyut = build" yazarsan "boyutlandırma" da bozulur.)

    # --- gerçek ölçümden gelen kör noktalar (2026-08-18) ---
    komponent = component
    kompanent = component
    zustant = Zustand
    zul stand = Zustand
    zustance = Zustand
    local storage = localStorage
    lokal storage = localStorage
    10 stack query = TanStack Query
    ten stack query = TanStack Query
    tan stack query = TanStack Query

    # --- diğer ---
    Hawk = hook
    refaktör = refactor

    """
}

enum Support {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Katip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
