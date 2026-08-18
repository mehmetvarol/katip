import Foundation

/// Whisper'ın harfiyen yazdığı düşünme sesleri — "ıı", "eee" gibi. Gerçek
/// anlam taşımıyorlar, dikte metnine karışmaları gürültü.
///
/// Kapalı, sabit bir liste — kullanıcı ayarı DEĞİL (Replacements/Snippets'in
/// aksine). Yalnızca en az 2 karakterlik, tek başına duran ünlem sesleri
/// siliniyor; "şey"/"yani" gibi gerçek kelimelere ASLA dokunulmuyor. Tek
/// harfli "e"/"ı" da bilerek dışarıda — tek harf bir şeyi hecelerken gerçek
/// anlam taşıyabilir.
enum FillerWords {
    private static let fillers: Set<String> = [
        "ıı", "ııı", "ıııı",
        "ee", "eee", "eeee",
        "hı", "hıı", "hımm", "hımmm",
        "hm", "hmm", "hmmm",
        "aa", "aaa",
        "öö", "ööö",
    ]

    /// Uzun biçimler önce denenmeli — yoksa "hımm" içindeki "hı" daha erken
    /// eşleşip "mm" kalıntısını metinde bırakır.
    private static let pattern: String = {
        let escaped = fillers
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
        return "\\b(\(escaped.joined(separator: "|")))\\b,?\\s*"
    }()

    static func strip(from text: String) -> String {
        var out = text.replacingOccurrences(
            of: pattern, with: " ",
            options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s+([,.!?])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"^[,\s]+"#, with: "", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }
}
