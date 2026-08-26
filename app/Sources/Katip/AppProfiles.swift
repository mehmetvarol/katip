import Foundation

/// Odaktaki uygulamaya göre dikte dili ve sözlük yönlendirmesini değiştirir.
///
/// Neden gerekli: kod ortamında (Cursor, Terminal, Claude Code) sözlük ve
/// İngilizce terim tanıma önemli — Katip'in asıl kullanım amacı bu. Günlük
/// yazışmada (Mail, Mesajlar) aynı sözlük gereksiz risk: "component" gibi bir
/// kelimenin GERÇEKTEN geçtiği bir cümleyi yanlışlıkla teknik terime çevirme
/// ihtimali var, bkz. `FuzzyTerms`'in yanlış pozitif ölçümü.
///
/// Dosya: ~/Library/Application Support/Katip/app-profiles.txt
enum AppProfiles {
    struct Profile {
        var language: Transcriber.LanguageSelection?
        var glossary: Bool?
    }

    static var fileURL: URL {
        Support.directory.appendingPathComponent("app-profiles.txt")
    }

    /// `appName`, odaktaki uygulamanın görünen adı (`NSRunningApplication.localizedName`).
    /// İlk eşleşen kural kazanır — yukarıdan aşağı sırayla bakılıyor.
    static func profile(for appName: String?) -> Profile {
        guard let appName, !appName.isEmpty else { return Profile(language: nil, glossary: nil) }
        let needle = appName.lowercased()
        for rule in load() where needle.contains(rule.match) {
            return Profile(language: rule.language, glossary: rule.glossary)
        }
        return Profile(language: nil, glossary: nil)
    }

    private struct Rule {
        var match: String   // hep küçük harf — karşılaştırma böyle yapılıyor
        var language: Transcriber.LanguageSelection?
        var glossary: Bool?
    }

    static func ensureFileExists() {
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try? defaultFile.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private static func load() -> [Rule] {
        ensureFileExists()
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line -> Rule? in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }

            let fields = parts[1].split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let languageField = fields.first ?? ""
            let glossaryField = fields.count > 1 ? fields[1].lowercased() : ""

            let language: Transcriber.LanguageSelection? = languageField.isEmpty
                ? nil : .parse(languageField)
            let glossary: Bool? = switch glossaryField {
                case "acik", "açık", "on": true
                case "kapali", "kapalı", "off": false
                default: nil
            }
            guard language != nil || glossary != nil else { return nil }
            return Rule(match: parts[0].lowercased(), language: language, glossary: glossary)
        }
    }

    private static let defaultFile = """
    # Katip — uygulama-bazlı kurallar
    #
    # Odaktaki uygulamaya göre dikte dilini ve sözlük yönlendirmesini değiştirir.
    #
    # Biçim:  <uygulama adının bir parçası> = <dil> | <sözlük>
    #   uygulama adı : NSRunningApplication.localizedName içinde ARANIYOR —
    #                  büyük/küçük duyarsız, tam ad gerekmiyor ("chrome" yeter).
    #   dil          : tr / en / auto / tr,en gibi — Dikte Dili menüsündeki
    #                  AYNI biçim. Boş bırakılırsa genel dil ayarın kullanılır.
    #   sözlük       : acik / kapali. Boş bırakılırsa genel ayar kullanılır.
    #
    # İLK eşleşen satır kazanır. Değişiklik için uygulamayı yeniden başlat.

    # --- vibe coding: teknik terim sözlüğü tam güçte ---
    cursor = tr,en | acik
    terminal = tr,en | acik
    claude = tr,en | acik
    code = tr,en | acik
    xcode = tr,en | acik

    # --- yazışma: teknik terimler karışmasın ---
    mail = tr | kapali
    slack = tr | kapali
    messages = tr | kapali
    notes = tr | kapali
    """
}
