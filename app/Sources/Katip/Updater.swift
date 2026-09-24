import Foundation

/// "Güncellemeleri denetle" — GitHub Releases üzerinden.
///
/// Neden Sparkle değil: macOS'ta standart çözüm Sparkle 2, ama ad-hoc imzalı
/// bir uygulamada her sürümü ayrıca bir EdDSA anahtarıyla imzalamayı, bir
/// appcast dosyası barındırmayı ve `build.sh`'a gömülü bir framework'ü
/// gerektiriyor. Katip'in yayın hattı zaten GitHub Releases (`gh release
/// create` + zip); en son sürümü okuyan API ucu herkese açık. Bu yüzden ek
/// bağımlılık yok, anahtar yönetimi yok — güven zinciri elle indirmeyle AYNI
/// (aynı GitHub sayfası, HTTPS).
///
/// Gizlilik: SADECE kullanıcı düğmeye bastığında ağa çıkar; arka planda
/// kendiliğinden denetleme yok.
@MainActor
final class Updater {
    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let pageURL: URL
        let size: Int
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(Release)
        case downloading(Double)
        case installing
        case failed(String)
    }

    static let latestURL = URL(string: "https://api.github.com/repos/mehmetvarol/katip/releases/latest")!

    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?

    /// Kurulumdan sonra yeniden başlatmayı AppDelegate yapıyor (aynı
    /// `relaunchApp` yolu — ayrı bir yeniden başlatma kodu tutmamak için).
    var onInstalled: (() -> Void)?

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Yalnızca `--rendermenu` için: menünün her güncelleme durumunu çizebilmek.
    func preview(_ state: State) { self.state = state }

    // MARK: Denetle

    func check() async {
        state = .checking
        Trace.log("güncelleme denetleniyor (şu an \(Self.currentVersion))")
        do {
            let release = try await Self.fetchLatest()
            if Self.isNewer(release.version, than: Self.currentVersion) {
                Trace.log("güncelleme var: \(release.version)")
                state = .available(release)
            } else {
                Trace.log("güncel (en son \(release.version))")
                state = .upToDate(release.version)
            }
        } catch {
            Trace.log("güncelleme denetimi HATA: \(error)")
            state = .failed(Self.describe(error))
        }
    }

    static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Katip/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let size: Int; let browser_download_url: URL }
            let tag_name: String
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let zip = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError.noAsset
        }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, zipURL: zip.browser_download_url, pageURL: payload.html_url, size: zip.size)
    }

    /// "0.2.10" > "0.2.9" — dize karşılaştırması bunu YANLIŞ bilir, parçalar sayı.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: İndir ve kur

    func downloadAndInstall(_ release: Release) async {
        state = .downloading(0)
        do {
            let zip = try await Self.download(release.zipURL) { [weak self] fraction in
                Task { @MainActor in
                    if case .downloading = self?.state { self?.state = .downloading(fraction) }
                }
            }
            state = .installing
            let target = Bundle.main.bundleURL
            let bundleID = Bundle.main.bundleIdentifier ?? "dev.mvrl.katip"
            // ditto + codesign birkaç saniye sürebilir — menüyü dondurmasın.
            try await Task.detached {
                try Self.install(zip: zip, expectedVersion: release.version, bundleID: bundleID, replacing: target)
            }.value
            Trace.log("güncelleme kuruldu: \(release.version) — yeniden başlatılıyor")
            onInstalled?()
        } catch {
            Trace.log("güncelleme kurulumu HATA: \(error)")
            state = .failed(Self.describe(error))
        }
    }

    static func download(_ url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let delegate = DownloadProgress(progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        // URLSession'ın geçici dosyası dönüşten sonra silinebilir — hemen taşı.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("katip-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporary, to: kept)
        return kept
    }

    /// Zip'i açar, içindeki uygulamayı DOĞRULAR ve `target`'ın yerine koyar.
    ///
    /// Doğrulama (hepsi geçmeden hiçbir şeye dokunulmuyor):
    /// - paket kimliği bu uygulamanınkiyle aynı (`dev.mvrl.katip`),
    /// - sürüm, GitHub'ın söylediğiyle aynı,
    /// - `codesign --verify --deep --strict` geçiyor (bozuk/yarım indirme yakalanır).
    ///
    /// Karantina: URLSession indirmeleri karantina bayrağı ALMIYOR, yani yeni
    /// sürüm Gatekeeper uyarısı vermeden ve yer değiştirmeden (App Translocation)
    /// açılıyor — Sparkle da aynı yolu izliyor.
    nonisolated static func install(zip: URL, expectedVersion: String, bundleID expectedID: String,
                                    replacing target: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("katip-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work); try? fm.removeItem(at: zip) }

        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard let app = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError.invalid("zip'te uygulama yok") }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let bundleID = info?["CFBundleIdentifier"] as? String
        let version = info?["CFBundleShortVersionString"] as? String
        guard bundleID == expectedID else {
            throw UpdateError.invalid("paket kimliği eşleşmiyor (\(bundleID ?? "yok"))")
        }
        guard version == expectedVersion else {
            throw UpdateError.invalid("sürüm eşleşmiyor (\(version ?? "yok") ≠ \(expectedVersion))")
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])

        // Yerinde değiştir: önce eskiyi kenara al, yeniyi taşı; yeni taşınamazsa
        // eskisi geri konuyor — yarım kalmış bir uygulama bırakmıyoruz.
        let backup = target.deletingLastPathComponent()
            .appendingPathComponent(".Katip-eski-\(UUID().uuidString).app")
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: app, to: target)
        } catch {
            try? fm.moveItem(at: backup, to: target)
            throw error
        }
        try? fm.removeItem(at: backup)
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.invalid("\((tool as NSString).lastPathComponent) başarısız (\(process.terminationStatus))")
        }
    }

    // MARK: Hatalar

    enum UpdateError: Error, Sendable {
        case server(Int)
        case noAsset
        case invalid(String)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case UpdateError.server(403): return "GitHub şu an yanıt vermiyor (çok sık denendi), biraz sonra dene"
        case UpdateError.server(let code): return "GitHub yanıtı beklenmedik (\(code))"
        case UpdateError.noAsset: return "Son sürümde indirilecek zip yok"
        case UpdateError.invalid(let reason): return "İndirilen dosya doğrulanamadı: \(reason)"
        case let url as URLError where url.code == .notConnectedToInternet: return "İnternet bağlantısı yok"
        case let url as URLError where url.code == .timedOut: return "GitHub'a ulaşılamadı (zaman aşımı)"
        case let cocoa as CocoaError where cocoa.code == .fileWriteNoPermission:
            return "Uygulamalar klasörüne yazma izni yok"
        default: return error.localizedDescription
        }
    }
}

/// İndirme yüzdesi — `URLSession.download(from:delegate:)` ilerlemeyi yalnızca
/// görev temsilcisine bildiriyor.
private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
