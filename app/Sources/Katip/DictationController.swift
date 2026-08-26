import AppKit
import Foundation

/// Tüm akışın tek sahibi. Adım 2'de global kısayol da buraya bağlanacak —
/// üç tetikleyici (ikon / bas-tut / çift-bas-kilit) tek durum makinesini beslemeli,
/// yoksa "ikonla başlattım tuşla bitirdim" gibi durumlarda tutarsızlık çıkar.
@MainActor
final class DictationController {
    enum State: Equatable {
        /// `progress` yalnızca gerçek bir indirme sürerken dolu — model diskte
        /// zaten varsa (her normal açılış) hep nil kalır, yüzde hiç görünmez.
        case loadingModel(progress: Double? = nil)
        case idle
        case recording
        case locked        // sürekli dinleme — tuşu bırakabilirsin
        case transcribing
        case error(String)

        var symbol: String {
            switch self {
            case .loadingModel: "arrow.down.circle"
            case .idle: "mic"
            case .recording, .locked: "mic.fill"
            case .transcribing: "waveform"
            case .error: "exclamationmark.triangle"
            }
        }

        var label: String {
            switch self {
            case .loadingModel(let progress):
                // Model zaten diskteyse (her normal açılış) tek bir 100% callback'i
                // geliyor — o an gerçekte hiçbir şey inmiyor, "indiriliyor" YANLIŞ olur.
                (progress ?? 0) > 0 && (progress ?? 0) < 1
                    ? "Model indiriliyor… %\(Int((progress ?? 0) * 100))"
                    : "Model yükleniyor…"
            case .idle: "Hazır"
            case .recording: "Dinliyor — bitirmek için tıkla"
            case .locked: "🔒 Kilitli — sürekli dinliyor, bitirmek için tuşa bas"
            case .transcribing: "Yazıya çevriliyor…"
            case .error(let message): message
            }
        }
    }

    private(set) var state: State = .loadingModel() {
        didSet { if oldValue != state { onChange?(state) } }
    }

    var onChange: ((State) -> Void)?

    /// Kullanıcı bir şey yapılamayacak bir anda tıkladığında UI haber vermeli.
    /// Sessiz no-op en kötü davranış: "tıkladım, hiçbir şey olmadı".
    var onIgnoredClick: ((String) -> Void)?

    /// Erişilebilirlik izni yoksa uygulama tamamen işlevsiz — açılışta sorulmalı.
    var onNeedsAccessibility: (() -> Void)?

    /// Metin imlece yazılamadıysa (izin yok / şifre alanı açık) çeviri kaybolmasın:
    /// UI onu kartta gösterip kopyalatabilsin.
    var onUndelivered: ((String) -> Void)?

    private(set) var lastTranscript: String = ""

    /// Anlık mikrofon seviyesi (0...1) — ikon animasyonunu besler.
    /// Sadece "çalışıyor" demiyor, "mikrofon seni DUYUYOR" diyor: sessiz mikrofonu
    /// saniyeler içinde fark ettiren şey bu.
    var inputLevel: Float { recorder.level }

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()

    /// Yüzde güncellemelerini seyrekleştirir — indirme callback'i saniyede
    /// onlarca kez tetikleniyor, her seferinde `state` değiştirip tüm UI'ı
    /// (ikon + tooltip + HUD) yeniden çizdirmek gereksiz iş.
    private var lastReportedDownloadPercent = -1

    func prepare() {
        FocusTracker.shared.start()
        Trace.log("prepare() — erişilebilirlik izni: \(Permissions.hasAccessibility)")
        // Model yüklemesi mikrofon iznini BEKLEMEZ. İzin diyalogu kullanıcı
        // yanıtlayana kadar askıda kalıyor; bunu beklemek uygulamayı hiç hazır
        // olmayan bir duruma sokuyordu (bu hataya bir kez düştük).
        Task {
            do {
                Trace.log("model yükleniyor…")
                try await transcriber.load(onDownloadProgress: { [weak self] fraction in
                    Task { @MainActor in self?.reportDownloadProgress(fraction) }
                })
                await transcriber.setLanguages(languageSelection)
                Trace.log("model hazır")
                state = .idle
            } catch {
                Trace.log("model HATA: \(error)")
                state = .error("Model yüklenemedi: \(error.localizedDescription)")
            }
        }

        Task {
            Trace.log("mikrofon izni isteniyor (mevcut: \(Permissions.hasMicrophone))")
            await Permissions.requestMicrophone()
            Trace.log("mikrofon izni sonuç: \(Permissions.hasMicrophone)")
        }

        // Uyarı MODAL: runModal() ana döngüyü bloke eder. Model yükleme Task'ı
        // kurulduktan SONRA ve ayrı bir tur'da göstermeliyiz — yoksa uyarı
        // kapatılana kadar model hiç yüklenmiyor (bu hataya bir kez düştük).
        if !Permissions.hasAccessibility {
            DispatchQueue.main.async { [weak self] in self?.onNeedsAccessibility?() }
        }
    }

    private func reportDownloadProgress(_ fraction: Double) {
        let percent = Int((fraction * 100).rounded())
        guard percent != lastReportedDownloadPercent else { return }
        lastReportedDownloadPercent = percent
        guard case .loadingModel = state else { return }
        state = .loadingModel(progress: fraction)
    }

    func toggle() {
        Trace.log("toggle() — durum: \(state)")
        switch state {
        case .recording, .locked: finish()
        case .idle, .error: begin()
        case .loadingModel:
            onIgnoredClick?("Model hâlâ yükleniyor — birkaç saniye sonra tekrar dene.")
        case .transcribing:
            onIgnoredClick?("Önceki kayıt hâlâ çevriliyor…")
        }
    }

    // MARK: -

    private func begin() {
        Trace.log("begin() — mikrofon izni: \(Permissions.hasMicrophone)")
        guard Permissions.hasMicrophone else {
            state = .error("Mikrofon izni yok")
            Permissions.openSettings(.microphone)
            return
        }
        do {
            try recorder.start()
            Trace.log("kayıt başladı")
            pieces.removeAll()
            context = ""
            sessionAudio = []
            spokenSeconds = 0
            state = .recording
            applyAppProfile()
            startStreaming()
        } catch {
            state = .error("Kayıt başlatılamadı: \(error.localizedDescription)")
        }
    }

    private func finish() {
        awaitingSecondTap = false
        secondTapTask?.cancel()

        // Akışta çevrilmiş parçalar varsa kalan artık kısa olabilir; minimum
        // süre şartını uygulama.
        let wasStreaming = (state == .locked)
        stopStreaming()

        let samples: [Float]
        do {
            // Akışta parçalar zaten yazıldıysa kalan artık kısa olabilir.
            samples = try recorder.stop(requireMinimum: !wasStreaming && pieces.isEmpty)
            Trace.log("kayıt bitti — \(samples.count) örnek (\(String(format: "%.1f", Double(samples.count) / AudioRecorder.sampleRate)) sn), tepe seviye \(String(format: "%.3f", recorder.lastPeak))")
        } catch {
            Trace.log("kayıt HATA: \(error)")
            // Biriken parçalar burada YAZILMALI; yoksa "son parça çok kısaydı"
            // diye tüm dikte sessizce çöpe gider.
            guard pieces.isEmpty else { completeSession(); return }
            if wasStreaming { state = .idle }
            else { state = .error(error.localizedDescription); resetSoon() }
            return
        }

        // Sessizlik kapısı. Log'dan ölçüldü: gerçek konuşma tepe 0.378,
        // sessiz kayıtlar 0.004-0.006. Sessizliği modele vermek Whisper'ı
        // Türkçe'de uydurma altyazı üretmeye itiyor ("Altyazı M.K." çıktı).
        guard recorder.lastPeak >= 0.02 else {
            Trace.log("ses yok (tepe \(String(format: "%.3f", recorder.lastPeak))) — çeviri atlandı")
            guard pieces.isEmpty else { completeSession(); return }
            if wasStreaming {
                state = .idle
            } else {
                state = .error("Ses algılanmadı — mikrofonu kontrol et")
                resetSoon()
            }
            return
        }

        state = .transcribing
        enqueueDelivery(samples)
        completeSession()
    }

    /// Bekleyen tüm çevirilerin bitmesini bekler, sonra metni TEK seferde yazar.
    private func completeSession() {
        state = .transcribing
        Task { [weak self] in
            await self?.deliveryChain?.value
            guard let self else { return }
            await self.flush()
            if case .transcribing = self.state { self.state = .idle }
        }
    }

    /// Çevir ve imlece yaz. Kilit modunda her cümle parçası için ayrı çağrılır,
    /// çağrılar sıralı olduğu için metin doğru sırada birikir.
    /// Teslimler SIRALI olmalı: akış parçası ile bitişteki artık aynı anda
    /// gelirse metin karışık sırada yapışır. Her teslim bir öncekini bekler.
    private var deliveryChain: Task<Void, Never>?

    /// Oturum boyunca çevrilen parçalar. Tek seferde yazılacak.
    ///
    /// Parçaları geldikçe yapıştırmak (eski davranış) her duraklamada imlece bir
    /// şey yazılması demekti; kullanıcı bunu "her sustuğumda kopyalıyor" diye
    /// bildirdi. Çeviri hâlâ parçalı — iş konuşma sürerken yapılıyor, sadece
    /// TESLİM sona alındı. Böylece bekleme uzamıyor ama yapıştırma bir kez oluyor.
    private var pieces: [String] = []

    /// Şimdiye kadar çevrilen metin — bir SONRAKİ parçaya decoder bağlamı
    /// olarak veriliyor. Whisper'ın cümlenin ortasında olduğunu anlamasının
    /// tek yolu bu; onsuz her parçayı büyük harfle başlatıp noktayla bitiriyor.
    private var context = ""

    /// Oturumun TAMAMININ ham sesi. Akış parçaları tampondan çıkarıldığı için
    /// kayıt bittiğinde geriye sadece son artık kalıyor — sesi saklamak
    /// isteyen tarafın parçaları burada yeniden birleştirmesi şart.
    private var sessionAudio: [Float] = []

    private func enqueueDelivery(_ samples: [Float]) {
        let previous = deliveryChain
        deliveryChain = Task { [weak self] in
            await previous?.value
            await self?.deliver(samples)
        }
    }

    private func deliver(_ samples: [Float]) async {
        // Çeviriden ÖNCE: metin boş dönse de (sessizlik kapısı, halüsinasyon
        // filtresi) ses oturumun parçası. Yeniden çeviri o parçayı da görmeli.
        sessionAudio.append(contentsOf: samples)
        do {
            let started = Date()
            let cpuStart = SystemLoad.cpuTime()
            // Bağlam uzun duraklamadan sonra da veriliyor: kuyruk noktayla
            // bitiyorsa model zaten yeni cümleye büyük harfle başlıyor, ve
            // terminoloji bağlamı iki cümle boyunca korunuyor.
            let carry = context.isEmpty ? nil : context
            let text = try await transcriber.transcribe(samples, context: carry)

            let wall = Date().timeIntervalSince(started)
            let cpu = SystemLoad.cpuTime() - cpuStart
            // cpu ≪ wall: darboğaz DIŞARIDA (başka iş CPU/GPU paylaşıyor).
            // cpu ≈ wall: darboğaz BİZİM hesaplamamızda (bkz. SystemLoad.swift).
            Trace.log("çeviri \(String(format: "%.2f", wall)) sn (cpu \(String(format: "%.2f", cpu)) sn, yük \(String(format: "%.1f", SystemLoad.loadAverage())), termal \(SystemLoad.thermalState())) → \"\(text)\"")
            guard !text.isEmpty else { return }
            pieces.append(text)
            context = String((context + " " + text).suffix(200))
            spokenSeconds += Double(samples.count) / AudioRecorder.sampleRate
        } catch {
            Trace.log("çeviri HATASI: \(error)")
            state = .error(error.localizedDescription)
            resetSoon()
        }
    }

    private var spokenSeconds: Double = 0

    /// Oturumun tamamını TEK seferde imlece yazar.
    private func flush() async {
        let text = Stitcher.join(pieces)
        let seconds = spokenSeconds
        let audio = sessionAudio
        pieces.removeAll()
        context = ""
        sessionAudio = []
        spokenSeconds = 0
        guard !text.isEmpty else { return }

        lastTranscript = text
        let target = FocusTracker.shared.previousApp?.localizedName
        do {
            try await TextInjector.inject(text)
            Trace.log("metin yazıldı ✔ (\(text.count) karakter, tek parça)")
            History.shared.add(text: text, app: target, seconds: seconds, samples: audio)
            NotificationCenter.default.post(name: .katipHistoryChanged, object: nil)
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Trace.log("HATA: \(error) — metin panoya bırakıldı")
            History.shared.add(text: text, app: target, seconds: seconds, samples: audio)
            NotificationCenter.default.post(name: .katipHistoryChanged, object: nil)
            state = .error(error.localizedDescription)
            resetSoon()
            onUndelivered?(text)
        }
    }

    // MARK: - Yeniden çeviri

    /// Saklanmış bir kaydı yeniden çevirir.
    ///
    /// Canlı diktenin AKSİNE sesi parçalamıyor: tamamı tek çağrıda gidiyor.
    /// Canlı yolda parçalama bir zorunluluk (metin akarak gelsin, sonda 13 sn
    /// beklenmesin); burada öyle bir kısıt yok, dolayısıyla modele bütün bağlam
    /// birden veriliyor ve dikiş hiç oluşmuyor. Bedeli süre: kayıt kadar uzun
    /// bir bekleme.
    ///
    /// Metni imlece YAZMIYOR — kullanıcı bu sırada geçmiş penceresinde,
    /// odak orada; yazmak metni yanlış yere düşürürdü.
    func retranscribe(_ entry: HistoryEntry) async -> Result<String, Error> {
        guard let name = entry.audio, Recordings.exists(name) else {
            return .failure(RetranscribeError.audioMissing)
        }
        guard state == .idle || isError else {
            return .failure(RetranscribeError.busy)
        }
        do {
            let samples = try Recordings.load(name)
            let started = Date()
            let text = try await transcriber.transcribe(samples)
            Trace.log("yeniden çeviri \(String(format: "%.2f", Date().timeIntervalSince(started))) sn → \"\(text)\"")
            guard !text.isEmpty else { return .failure(RetranscribeError.empty) }
            History.shared.update(id: entry.id, text: text)
            return .success(text)
        } catch {
            Trace.log("yeniden çeviri HATASI: \(error)")
            return .failure(error)
        }
    }

    enum RetranscribeError: LocalizedError {
        case audioMissing, busy, empty
        var errorDescription: String? {
            switch self {
            case .audioMissing: "Bu kaydın sesi artık saklanmıyor."
            case .busy: "Önce süren dikteyi bitir."
            case .empty: "Ses yeniden çevrildi ama metin çıkmadı."
            }
        }
    }

    // MARK: - Kilit modu akışı (VAD ile parçalama)

    private var streamTask: Task<Void, Never>?

    /// Kilit modunda cümle aralarındaki sessizlikten bölüp her parçayı ayrı
    /// çevirir. Böylece uzun konuşmada metin AKARAK gelir; sonda toplu bekleme
    /// olmaz (39 sn konuşma tek seferde 7.3 sn bekletiyordu).
    /// Kayıt SÜRERKEN cümle aralarındaki sessizlikten bölüp yazar.
    ///
    /// Artık kilit moduna özel değil — bas-tut'ta da çalışıyor. Gerekçe ölçüm:
    /// gerçek diktelerin ortalaması **71 saniye** (uzun prompt söylüyoruz), ve
    /// bu sürede bitişte ~13 sn bekleniyordu. Akışla bekleme son cümleye iniyor.
    /// Kısa diktede zaten kesme olmaz (VAD ≥0.6 sn konuşma + ≥0.45 sn sessizlik ister).
    private func startStreaming() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            Trace.log("akış başladı")
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { break }
                switch self.state {
                case .recording, .locked: break
                default: return                     // kayıt bitti, döngüyü kapat
                }
                guard let segment = self.recorder.takeSegment() else { continue }
                Trace.log("parça hazır — \(String(format: "%.1f", Double(segment.samples.count) / AudioRecorder.sampleRate)) sn, öncesinde \(String(format: "%.1f", segment.silenceBefore)) sn duraklama")
                self.enqueueDelivery(segment.samples)
            }
        }
    }

    private func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Kısayol tetikleyicisi (bas-tut ↔ çift-bas-kilit)

    /// Eşikler. Kayıt İLK basışta hemen başlar; hold/çift-bas ayrımı bırakışta
    /// yapılır — beklemek ilk hecenin kaybı demek olurdu.
    private static let tapThreshold: TimeInterval = 0.25   // bundan kısa basış = "tık"
    private static let doubleTapWindow: TimeInterval = 0.4 // ikinci tık için pencere

    private var pressStarted: Date?
    private var awaitingSecondTap = false
    private var secondTapTask: Task<Void, Never>?

    func hotkeyPressed() {
        // Kilitliyken tuşa basmak kaydı bitirir.
        if state == .locked {
            Trace.log("kilit modu tuşla kapatıldı")
            finish()
            return
        }

        // Çift-bas: ikinci basış kilit moduna geçirir.
        if awaitingSecondTap {
            awaitingSecondTap = false
            secondTapTask?.cancel()
            if state == .recording {
                Trace.log("çift bas → KİLİT modu")
                state = .locked   // akış begin()'de başladı, sürüyor
            }
            return
        }

        pressStarted = Date()
        if state == .idle || isError { begin() }
    }

    func hotkeyReleased() {
        guard state == .recording else { return }
        let held = pressStarted.map { Date().timeIntervalSince($0) } ?? 0
        pressStarted = nil

        if held >= Self.tapThreshold {
            Trace.log("bas-tut bırakıldı (\(String(format: "%.2f", held)) sn)")
            finish()
            return
        }

        // Kısa basış: ikinci tıkı bekle. Gelmezse normal kısa kayıt olarak bitir.
        awaitingSecondTap = true
        secondTapTask?.cancel()
        secondTapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
            guard !Task.isCancelled, let self, self.awaitingSecondTap else { return }
            self.awaitingSecondTap = false
            if self.state == .recording { self.finish() }
        }
    }

    private var isError: Bool { if case .error = state { return true }; return false }

    /// Karttaki kilit düğmesi. Kayıt yoksa başlatıp doğrudan kilide geçer —
    /// çift-basışla aynı sonuca fareyle de ulaşılsın.
    // MARK: - Uygulama-bazlı kurallar

    /// Her `begin()`'de ÇAĞRILIYOR — profil bulunsa da bulunmasa da, önceki
    /// oturumdan kalan bir geçersiz kılma bir sonrakine SIZMASIN diye. Yani
    /// "temizle" diye ayrı bir adım yok: her oturum kendi doğru değerini
    /// baştan kuruyor.
    ///
    /// Menüdeki (kalıcı) `languageSelection`'a HİÇ DOKUNMUYOR — kullanıcının
    /// kendi seçimi bu. Yalnızca Transcriber'ın O OTURUM için kullanacağı
    /// canlı değeri değiştiriyor; oturum bitince bir sonraki `begin()` zaten
    /// kendi doğrusunu (profil ya da kullanıcının menü seçimi) yeniden kurar.
    private func applyAppProfile() {
        let appName = FocusTracker.shared.previousApp?.localizedName
        let profile = AppProfiles.profile(for: appName)

        let effectiveLanguage = profile.language ?? languageSelection
        Task { await transcriber.setLanguages(effectiveLanguage) }

        Task { await transcriber.setGlossaryOverride(profile.glossary) }

        if profile.language != nil || profile.glossary != nil {
            Trace.log("uygulama kuralı (\(appName ?? "?")) — dil: \(effectiveLanguage.serialized), sözlük: \(profile.glossary.map { $0 ? "açık" : "kapalı" } ?? "genel ayar")")
        }
    }

    // MARK: - Dikte dili

    /// Menüde sunulan diller. Whisper zaten çok dilli olduğu için ek dil
    /// eklemek model boyutunu ARTIRMIYOR — sadece decode anındaki dil
    /// token'ı değişiyor.
    enum LanguageChoice: String, CaseIterable {
        case tr, en, de, fr, es, it, ru, ar

        var title: String {
            switch self {
            case .tr: "Türkçe"
            case .en: "İngilizce"
            case .de: "Almanca"
            case .fr: "Fransızca"
            case .es: "İspanyolca"
            case .it: "İtalyanca"
            case .ru: "Rusça"
            case .ar: "Arapça"
            }
        }
    }

    private static let languageKey = "dictationLanguage"

    /// Eski format tek bir string'di: "tr", "en" veya "auto" (nil'in disk
    /// SENTINEL'i). Yeni format aynı anahtarı kullanıyor ama virgülle
    /// ayrılmış birden çok kodu da kabul ediyor ("tr,en") — eski değerler
    /// (tek kod / "auto") YENİ ŞEMADA DA geçerli, geriye dönük göç gerekmedi.
    private(set) var languageSelection: Transcriber.LanguageSelection = {
        let raw = UserDefaults.standard.string(forKey: DictationController.languageKey) ?? "tr"
        return DictationController.parseLanguage(raw)
    }()

    private static func parseLanguage(_ raw: String) -> Transcriber.LanguageSelection {
        guard raw != "auto" else { return .auto }
        let codes = raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return .fixed(codes.isEmpty ? ["tr"] : codes)
    }

    private static func serializeLanguage(_ selection: Transcriber.LanguageSelection) -> String {
        switch selection {
        case .auto: "auto"
        case .fixed(let codes): codes.joined(separator: ",")
        }
    }

    var languageLabel: String {
        switch languageSelection {
        case .auto: "OTO"
        case .fixed(let codes): codes.map { $0.uppercased() }.joined(separator: "+")
        }
    }

    var isAutoLanguage: Bool { languageSelection == .auto }

    func isLanguageSelected(_ code: LanguageChoice) -> Bool {
        guard case .fixed(let codes) = languageSelection else { return false }
        return codes.contains(code.rawValue)
    }

    private func applyLanguage(_ selection: Transcriber.LanguageSelection) {
        languageSelection = selection
        UserDefaults.standard.set(Self.serializeLanguage(selection), forKey: Self.languageKey)
        Task { await transcriber.setLanguages(selection) }
        Trace.log("dikte dili → \(languageLabel)")
    }

    func setAutoLanguage() { applyLanguage(.auto) }

    /// Bir dili işaretle/kaldır. Otomatik moddaysa önce oradan çıkarıp tek
    /// dille başlar. Son kalan dil kaldırılamaz — boş seçim anlamsız.
    func toggleLanguage(_ code: LanguageChoice) {
        guard case .fixed(var codes) = languageSelection else {
            applyLanguage(.fixed([code.rawValue]))
            return
        }
        if let index = codes.firstIndex(of: code.rawValue) {
            guard codes.count > 1 else { return }
            codes.remove(at: index)
        } else {
            codes.append(code.rawValue)
        }
        applyLanguage(.fixed(codes))
    }

    func cancel() {
        stopStreaming()
        recorder.cancel()
        pieces.removeAll()          // iptal: çevrilmiş parçalar da atılır
        context = ""
        sessionAudio = []
        spokenSeconds = 0
        state = .idle
    }

    private func resetSoon() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .error = state { state = .idle }
        }
    }
}
