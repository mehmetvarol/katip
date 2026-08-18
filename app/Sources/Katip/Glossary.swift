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

    /// Bütçe yalnızca **111 token** (`Constants.maxTokenContext / 2 - 1`) ve
    /// WhisperKit `.suffix()` ile SONU tutuyor → baştakiler düşer.
    ///
    /// Bu yüzden liste kısa ve sıralı: `refactor`/`deploy`/`endpoint` gibi yaygın
    /// terimler HİÇ yok — P0 duman testinde ipucu olmadan da doğru çıktılar.
    /// Bütçeyi Whisper'ın zaten bildiği kelimelere harcamanın anlamı yok.
    /// En kritik/en nadir özel adlar en SONDA.
    static let defaultTerms = [
        "prop drilling", "optimistic update", "stale time", "reverse geocode",
        "exponential backoff", "error boundary", "lazy load", "bundle size",
        "test coverage", "environment variable", "sub agent",
        "Claude Code", "MCP", "Shopify", "Next.js", "React Native", "App Router",
        "ESP32", "CAN bus", "TPMS", "MQTT", "Home Assistant", "Shelly",
        "Raspberry Pi", "Zustand", "TanStack Query", "Turbopack", "Netlify",
        "Leaflet", "Vitest", "Fleet API",
    ]

    private static var defaultFile: String {
        """
        # Katip — teknik terim sözlüğü
        #
        # Whisper'a "bu kelimeleri böyle yaz" ipucu verir.
        # ⚠️ SIRA ÖNEMLİ: bütçe sadece 111 token ve aşılırsa BAŞTAKİLER düşer
        # (WhisperKit promptTokens.suffix ile sonu tutuyor).
        # En kritik / en nadir terimleri EN SONA yaz.
        # Uygulama açılışta gerçek token sayısını katip.log'a yazar.
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
