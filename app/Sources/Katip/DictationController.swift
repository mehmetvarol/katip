import AppKit
import Foundation

/// Tüm akışın tek sahibi. Adım 2'de global kısayol da buraya bağlanacak —
/// üç tetikleyici (ikon / bas-tut / çift-bas-kilit) tek durum makinesini beslemeli,
/// yoksa "ikonla başlattım tuşla bitirdim" gibi durumlarda tutarsızlık çıkar.
@MainActor
final class DictationController {
    enum State: Equatable {
        case loadingModel
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
            case .loadingModel: "Model yükleniyor…"
            case .idle: "Hazır"
            case .recording: "Dinliyor — bitirmek için tıkla"
            case .locked: "🔒 Kilitli — sürekli dinliyor, bitirmek için tuşa bas"
            case .transcribing: "Yazıya çevriliyor…"
            case .error(let message): message
            }
        }
    }

    private(set) var state: State = .loadingModel {
        didSet { if oldValue != state { onChange?(state) } }
    }

    var onChange: ((State) -> Void)?

    /// Kullanıcı bir şey yapılamayacak bir anda tıkladığında UI haber vermeli.
    /// Sessiz no-op en kötü davranış: "tıkladım, hiçbir şey olmadı".
    var onIgnoredClick: ((String) -> Void)?

    /// Erişilebilirlik izni yoksa uygulama tamamen işlevsiz — açılışta sorulmalı.
    var onNeedsAccessibility: (() -> Void)?

    private(set) var lastTranscript: String = ""

    /// Anlık mikrofon seviyesi (0...1) — ikon animasyonunu besler.
    /// Sadece "çalışıyor" demiyor, "mikrofon seni DUYUYOR" diyor: sessiz mikrofonu
    /// saniyeler içinde fark ettiren şey bu.
    var inputLevel: Float { recorder.level }

    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()

    func prepare() {
        FocusTracker.shared.start()
        Trace.log("prepare() — erişilebilirlik izni: \(Permissions.hasAccessibility)")
        // Model yüklemesi mikrofon iznini BEKLEMEZ. İzin diyalogu kullanıcı
        // yanıtlayana kadar askıda kalıyor; bunu beklemek uygulamayı hiç hazır
        // olmayan bir duruma sokuyordu (bu hataya bir kez düştük).
        Task {
            do {
                Trace.log("model yükleniyor…")
                try await transcriber.load()
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
            state = .recording
        } catch {
            state = .error("Kayıt başlatılamadı: \(error.localizedDescription)")
        }
    }

    private func finish() {
        awaitingSecondTap = false
        secondTapTask?.cancel()

        // Kilit modunda parçalar zaten yazıldı; burada sadece kalan artık var.
        // O artık kısa olabilir, minimum süre şartını uygulama.
        let wasStreaming = (state == .locked)
        stopStreaming()

        let samples: [Float]
        do {
            samples = try recorder.stop(requireMinimum: !wasStreaming)
            Trace.log("kayıt bitti — \(samples.count) örnek (\(String(format: "%.1f", Double(samples.count) / AudioRecorder.sampleRate)) sn), tepe seviye \(String(format: "%.3f", recorder.lastPeak))")
        } catch {
            Trace.log("kayıt HATA: \(error)")
            if wasStreaming { state = .idle } else { state = .error(error.localizedDescription); resetSoon() }
            return
        }

        // Sessizlik kapısı. Log'dan ölçüldü: gerçek konuşma tepe 0.378,
        // sessiz kayıtlar 0.004-0.006. Sessizliği modele vermek Whisper'ı
        // Türkçe'de uydurma altyazı üretmeye itiyor ("Altyazı M.K." çıktı).
        guard recorder.lastPeak >= 0.02 else {
            Trace.log("ses yok (tepe \(String(format: "%.3f", recorder.lastPeak))) — çeviri atlandı")
            if wasStreaming {
                state = .idle          // parçalar yazıldı, artık sessizdi: normal
            } else {
                state = .error("Ses algılanmadı — mikrofonu kontrol et")
                resetSoon()
            }
            return
        }

        state = .transcribing
        Task {
            await deliver(samples)
            if case .transcribing = state { state = .idle }
        }
    }

    /// Çevir ve imlece yaz. Kilit modunda her cümle parçası için ayrı çağrılır,
    /// çağrılar sıralı olduğu için metin doğru sırada birikir.
    private func deliver(_ samples: [Float]) async {
        do {
            let started = Date()
            let text = try await transcriber.transcribe(samples)
            Trace.log("çeviri \(String(format: "%.2f", Date().timeIntervalSince(started))) sn → \"\(text)\"")
            guard !text.isEmpty else { return }

            lastTranscript = text
            let target = FocusTracker.shared.previousApp?.localizedName
            try await TextInjector.inject(text)
            Trace.log("metin yazıldı ✔")
            History.shared.add(text: text, app: target,
                               seconds: Double(samples.count) / AudioRecorder.sampleRate)
            NotificationCenter.default.post(name: .katipHistoryChanged, object: nil)
        } catch {
            if !lastTranscript.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(lastTranscript, forType: .string)
            }
            Trace.log("HATA: \(error) — metin panoya bırakıldı")
            state = .error(error.localizedDescription)
            resetSoon()
        }
    }

    // MARK: - Kilit modu akışı (VAD ile parçalama)

    private var streamTask: Task<Void, Never>?

    /// Kilit modunda cümle aralarındaki sessizlikten bölüp her parçayı ayrı
    /// çevirir. Böylece uzun konuşmada metin AKARAK gelir; sonda toplu bekleme
    /// olmaz (39 sn konuşma tek seferde 7.3 sn bekletiyordu).
    private func startStreaming() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            Trace.log("kilit modu akışı başladı")
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.state == .locked else { break }
                guard let segment = self.recorder.takeSegment() else { continue }
                Trace.log("parça hazır — \(String(format: "%.1f", Double(segment.count) / AudioRecorder.sampleRate)) sn")
                await self.deliver(segment)
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
                state = .locked
                startStreaming()
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

    func cancel() {
        stopStreaming()
        recorder.cancel()
        state = .idle
    }

    private func resetSoon() {
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .error = state { state = .idle }
        }
    }
}
