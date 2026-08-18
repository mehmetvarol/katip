import Foundation

/// Kendi projelerinden terim öğrenme.
///
/// Kıyas testi Katip'in tek gerçek üstünlüğünün **kişiselleştirme** olduğunu
/// gösterdi (%71 → %84). Ama elle kural yazmak sürtünmeli; kimse günde beş kez
/// dosya açıp kural eklemez. Bu, o katmanı ölçekliyor.
///
/// En yüksek sinyal `package.json` bağımlılıklarında: `@tanstack/react-query`,
/// `zustand`, `maplibre-gl` — Whisper'ın tam da bozduğu isimler bunlar.
enum Vocabulary {
    static var fileURL: URL { Support.directory.appendingPathComponent("vocabulary.txt") }
    static var proposalsURL: URL { Support.directory.appendingPathComponent("onerilen-kurallar.txt") }

    // MARK: - Tarama

    /// Verilen dizinlerdeki projelerden terim çıkarır.
    static func scan(directories: [String]) -> [String: Set<String>] {
        var found: [String: Set<String>] = [:]   // terim -> hangi projelerde
        let fm = FileManager.default

        for dir in directories {
            let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }

            for case let url as URL in walker {
                let path = url.path
                // Bağımlılıkların kendi bağımlılıkları bizi ilgilendirmiyor.
                if path.contains("/node_modules/") || path.contains("/.next/")
                    || path.contains("/.build/") || path.contains("/.git/") {
                    walker.skipDescendants()
                    continue
                }
                guard url.lastPathComponent == "package.json" else { continue }

                let project = url.deletingLastPathComponent().lastPathComponent
                for name in dependencies(at: url) {
                    for term in spokenForms(of: name) {
                        found[term, default: []].insert(project)
                    }
                }
            }
        }
        return found
    }

    private static func dependencies(at url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        var names: [String] = []
        for key in ["dependencies", "devDependencies"] {
            if let block = json[key] as? [String: Any] { names += block.keys }
        }
        return names
    }

    /// Paket adını konuşulan biçime çevir: `@tanstack/react-query` → "TanStack Query".
    ///
    /// Sezgisel bir dönüşüm; amaç mükemmel isim üretmek değil, kullanıcının
    /// gözden geçireceği aday listesi çıkarmak.
    static func spokenForms(of package: String) -> [String] {
        // Bilinen yazımlar. Sezgisel büyütme "Typescript" gibi yanlış üretiyor;
        // gerçek tarama çıktısına bakılarak dolduruldu.
        let casing = [
            "js": "JS", "ts": "TS", "gl": "GL", "ui": "UI", "api": "API",
            "sse": "SSE", "sdk": "SDK", "css": "CSS", "db": "DB", "dom": "DOM",
            "typescript": "TypeScript", "javascript": "JavaScript",
            "tanstack": "TanStack", "next": "Next.js", "nextjs": "Next.js",
            "maplibre": "MapLibre", "zustand": "Zustand", "expo": "Expo",
            "eslint": "ESLint", "postcss": "PostCSS", "tailwindcss": "Tailwind CSS",
            "netinfo": "NetInfo", "asyncstorage": "AsyncStorage",
            "webview": "WebView", "graphql": "GraphQL", "nodemon": "Nodemon",
        ]
        func pretty(_ part: String) -> String {
            if let known = casing[part.lowercased()] { return known }
            guard let first = part.first else { return part }
            return first.uppercased() + part.dropFirst()
        }

        var scope: String?
        var name = package
        if package.hasPrefix("@"), let slash = package.firstIndex(of: "/") {
            scope = String(package[package.index(after: package.startIndex)..<slash])
            name = String(package[package.index(after: slash)...])
        }

        // Tip paketleri ve araç eklentileri terim değil.
        if scope == "types" || name.hasPrefix("eslint-config") { return [] }

        let words = name.split(whereSeparator: { $0 == "-" || $0 == "." }).map { pretty(String($0)) }
        guard !words.isEmpty else { return [] }

        var forms = [words.joined(separator: " ")]
        if let scope, scope != "types" {
            // "@tanstack/react-query" → hem "TanStack Query" hem "React Query"
            forms.append(([pretty(scope)] + words.filter { $0.lowercased() != "react" })
                .joined(separator: " "))
        }
        // "Tailwind CSS PostCSS" gibi kapsam+ad birleşimleri gürültü; kapsam
        // adı zaten terimin içinde geçiyorsa o formu atla.
        return Array(Set(forms)).filter { form in
            form.count > 2 && form.split(separator: " ").count <= 3
        }
    }

    // MARK: - Kural önerisi

    /// Geçmişteki transkriptlerde, sözlükteki bir terime YAKIN ama tam eşleşmeyen
    /// ifadeler ara → `yanlış = doğru` kuralı öner.
    ///
    /// Otomatik uygulamıyoruz: yanlış bir kural, kaçırılan bir terimden kötüdür.
    /// Kullanıcı dosyayı gözden geçirip istediğini `replacements.txt`'e taşır.
    static func proposeRules(terms: [String], transcripts: [String]) -> [(String, String)] {
        var proposals: [String: String] = [:]
        let known = Set(terms.map { fold($0) })

        for text in transcripts {
            let tokens = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { $0.count >= 4 }
            for token in tokens {
                let f = fold(token)
                if known.contains(f) { continue }          // zaten doğru
                for term in terms where abs(fold(term).count - f.count) <= 3 {
                    let d = distance(f, fold(term))
                    // Eşik dar: uzunluğun %25'i. Gevşetmek yanlış eşleşme üretir.
                    if d > 0, Double(d) / Double(max(f.count, 1)) <= 0.25 {
                        proposals[token] = term
                        break
                    }
                }
            }
        }
        return proposals.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive],
                  locale: Locale(identifier: "tr_TR"))
         .replacingOccurrences(of: " ", with: "")
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j-1] + 1,
                                 previous[j-1] + (a[i-1] == b[j-1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
