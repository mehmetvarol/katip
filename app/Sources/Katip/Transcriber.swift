import Foundation
import WhisperKit

/// WhisperKit sarmalayıcı. Model bir kez yüklenir ve bellekte SICAK tutulur —
/// soğuk yükleme 1-3 saniye, her katipde yeniden yüklemek kabul edilemez.
actor Transcriber {
    /// macOS'ta hız/doğruluk dengesi için önerilen varyant.
    static let defaultModel = "large-v3-v20240930_turbo"

    private var pipe: WhisperKit?
    private var promptTokens: [Int]?
    private var useGlossary = true
    /// Ölçüm için geçici dil değiştirme.
    var languageOverride: String?

    var isReady: Bool { pipe != nil }

    /// Sözlük yönlendirmesi AÇIK — ama sıkı bir token bütçesiyle.
    ///
    /// Önce kapalıydı: 31 terimlik varsayılan liste 109 token tutuyor ve
    /// ölçümde çeviriyi 1.7 → 4.0 sn'ye çıkarıyordu. Sonradan anlaşıldı ki
    /// sorun sözlük fikri değil, **listenin uzunluğu ve alakasızlığı**.
    ///
    /// Gerçek Türkçe kayıtla ölçüldü (10 sn'lik parça, 2026-08-21):
    ///
    ///     kapalı              0 token   2.11 sn   "localized storage'ta" ✗
    ///     küçük+isabetli     23 token   2.58 sn   "localStorage'de"      ✓
    ///     tam+alakasız      109 token   4.48 sn   "localized storage'ta" ✗
    ///
    /// Gecikme token başına doğrusal (~0.02 sn/token), yani bütçe doğrudan
    /// bedeli belirliyor. Kazanç ise boyuttan değil **isabetten** geliyor:
    /// 109 token'lık liste hiçbir şey düzeltmedi çünkü aradığımız terim
    /// içinde yoktu.
    static var glossaryEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "useGlossary") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useGlossary") }
    }

    /// Sözlüğe ayrılan token tavanı.
    ///
    /// Bütçe `promptTokens`'ın TAMAMI için 111 (`maxTokenContext / 2 - 1`) ve
    /// bağlam yönlendirmesiyle PAYLAŞILIYOR. Bağlam daha değerli — cümlenin
    /// ortasında olduğumuzu yalnızca o söyleyebiliyor — o yüzden sözlük 40
    /// ile sınırlandı: 40 + 32 = 72, tavanın altında, ~0.8 sn'ye mal oluyor.
    static let glossaryTokenBudget = 40

    /// Ölçüm için model/sözlük değiştirilebilir; uygulama varsayılanları kullanır.
    func load(model: String? = nil, useGlossary: Bool? = nil) async throws {
        guard pipe == nil else { return }
        self.useGlossary = useGlossary ?? Self.glossaryEnabled
        // downloadBase şart: varsayılan ~/Documents/huggingface, yani 1.5 GB'lık
        // model Belgeler klasörüne dökülüyor. Application Support'a alıyoruz.
        // ANE yerine Metal (GPU).
        //
        // Neden: bu makinede (M1 Pro / macOS 26.6) large-v3-turbo'nun ANE derlemesi
        // ANECompilerService'i 25+ dakika %100 CPU'da tutup bitmedi ve derleme
        // önbelleği hiç büyümedi — yani ilerlemiyordu. GPU yolunda model saniyeler
        // içinde yükleniyor. Metal ~9x real-time, katip için fazlasıyla yeterli.
        //
        // ANE daha az güç çeker; ileride tekrar denemeye değer (KATIP_ANE=1).
        let useANE = ProcessInfo.processInfo.environment["KATIP_ANE"] == "1"
        let compute = ModelComputeOptions(
            melCompute: .cpuAndGPU,
            audioEncoderCompute: useANE ? .cpuAndNeuralEngine : .cpuAndGPU,
            textDecoderCompute: useANE ? .cpuAndNeuralEngine : .cpuAndGPU)

        let config = WhisperKitConfig(
            model: model ?? Self.defaultModel,
            downloadBase: Support.directory,
            computeOptions: compute,
            // WhisperKit'in kendi prewarm'ı ölçüldü: ilk çeviriyi hızlandırmıyor
            // (yine 4.9 sn) ama yükleme süresine ~2 sn ekliyor. Kapalı.
            prewarm: false,
            load: true)
        let pipe = try await WhisperKit(config)
        self.pipe = pipe

        // Sözlük/düzeltme dosyaları model durumundan bağımsız oluşsun —
        // kullanıcı her hâlükârda düzenleyebilmeli.
        _ = Glossary.load()
        _ = Replacements.load()
        _ = Snippets.load()
        buildPromptTokens()

        await warmUp()
    }

    /// Sahte bir çeviri koştur.
    ///
    /// İlk gerçek çeviri 4.9 sn, sonrakiler 1.7 sn — aradaki ~3 sn tek seferlik
    /// ısınma. WhisperKit'in `prewarm` seçeneği bunu KAPSAMIYOR (ölçüldü).
    /// Bu yüzden bedeli açılışa alıyoruz: kullanıcı ilk katipsinde beklemesin.
    private func warmUp() async {
        guard let pipe else { return }
        // Sessizlik İŞE YARAMIYOR: no-speech kapısı çözümlemeyi kısa devre ediyor
        // ve ısınma 0.0 sn sürüyor (ölçüldü). Decoder'ı gerçekten çalıştırmak için
        // hafif gürültü + `noSpeechThreshold: nil` gerekiyor.
        var noise = [Float](repeating: 0, count: 48_000)  // 3 sn
        for index in noise.indices { noise[index] = Float.random(in: -0.3...0.3) }

        let started = Date()
        _ = try? await pipe.transcribe(
            audioArray: noise,
            decodeOptions: DecodingOptions(task: .transcribe, language: "tr",
                                           temperature: 0, detectLanguage: false,
                                           withoutTimestamps: true,
                                           noSpeechThreshold: nil))
        Trace.log("ısınma \(String(format: "%.1f", Date().timeIntervalSince(started))) sn")
    }

    func setLanguage(_ lang: String?) { languageOverride = lang }

    /// - Parameter context: Aynı diktenin ÖNCEKİ parçasından çıkan metin.
    ///   Whisper'ın `condition_on_previous_text`'i — decoder'a "bu cümle
    ///   devam ediyor" bilgisini veren tek mekanizma.
    func transcribe(_ samples: [Float], context: String? = nil) async throws -> String {
        guard let pipe else { throw TranscriberError.notLoaded }
        // Tokenizer yükleme anında hazır olmayabiliyor; ilk katipde tekrar dene.
        // Sessizce atlanırsa terminoloji yönlendirmesi hiç çalışmaz.
        if promptTokens == nil, useGlossary { buildPromptTokens() }

        let options = DecodingOptions(
            task: .transcribe,
            // Dil SABİT. Otomatik algılama bu projede düşman: İngilizce terimle
            // başlayan bir Türkçe cümlede pencereyi `en` sanıp ekleri bozuyor.
            language: languageOverride ?? "tr",
            temperature: 0,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: Self.fitsSingleWindow(samples) ? prompt(for: context) : nil,
            // Sessizlikte uydurma metin üretimine karşı (Türkçe'de "Altyazı M.K." tipi).
            noSpeechThreshold: 0.6
        )

        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")

        // Bağlam yönlendirmesinin bilinen arıza modu: decoder önceki metne
        // kilitlenip tekrar döngüsüne giriyor. Ölçüldü (jfk.wav, kasten
        // uyumsuz bağlam): "ne yapın ne yapın ne yapın…", 2.07 sn yerine
        // 14.97 sn. WhisperKit'in kendi `compressionRatioThreshold` geri
        // çekilmesi bu vakada YETMEDİ — beş sıcaklık denemesi de döngüye
        // düştü. O yüzden bağlamı atıp bir kez daha deniyoruz; bedel sadece
        // arıza anında ödeniyor.
        if context != nil, Repetition.isRepetitive(text) {
            Trace.log("bağlamlı çeviri tekrara düştü — bağlamsız yeniden deneniyor")
            return try await transcribe(samples, context: nil)
        }
        return Self.clean(text)
    }

    /// Ses tek bir Whisper penceresine (30 sn) sığıyor mu?
    ///
    /// ÖNEMLİ: `promptTokens` yalnızca burada güvenli. Çok pencereli
    /// çözümlemede prompt, çıktının SESSİZCE KESİLMESİNE yol açıyor —
    /// gerçek kayıtlarla ölçüldü (2026-08-21):
    ///
    ///     41 sn ses + 109 token → son iki cümle kayboldu, 7.2 → 23.0 sn
    ///     38 sn ses +  23 token → metnin TAMAMI gitti, geriye son cümle kaldı
    ///     10 sn ses +  23 token → tam metin, 2.11 → 2.58 sn, terim düzeldi
    ///
    /// Tekrar döngüsünü `Repetition` yakalıyor ama bu ONDAN FARKLI bir arıza:
    /// çıktı bozuk değil, EKSİK — hiçbir sağlık göstergesi tetiklenmiyor.
    /// Sessiz veri kaybına karşı tek savunma prompt'u hiç göndermemek.
    ///
    /// Canlı dikteyi etkilemiyor: VAD parçaları 4-13 sn arasında, hepsi tek
    /// pencere. Asıl koruduğu yer "Yeniden çevir" — orada kaydın tamamı tek
    /// çağrıda gidiyor ve 30 sn'yi rahatça aşıyor.
    private static func fitsSingleWindow(_ samples: [Float]) -> Bool {
        Double(samples.count) / 16_000 <= 28
    }

    // MARK: - Bağlam yönlendirme

    /// Bir dikte parçası çevrilirken decoder'a verilecek ön-bağlam.
    ///
    /// İki kaynak birleşiyor: kullanıcı sözlüğü (statik terminoloji) ve önceki
    /// parçanın metni (dinamik bağlam). Sıra ÖNEMLİ — WhisperKit bütçe aşımında
    /// `promptTokens`'ı SONDAN tutuyor, yani en değerli olan sona konmalı.
    /// Önceki metin sözlükten daha değerli: cümlenin ortasında olduğumuzu
    /// yalnızca o söyleyebiliyor.
    private func prompt(for context: String?) -> [Int]? {
        guard let context, !context.isEmpty, let tokenizer = pipe?.tokenizer else {
            return promptTokens
        }
        // Bağlamı kısa tut. Her prompt token'ı decoder prefill'ine ekleniyor ve
        // ölçüldü ki 109 token ~2.3 sn'ye mal oluyor (bkz. `glossaryEnabled`).
        // Cümlenin devam ettiğini anlatmak için son bir cümlelik kuyruk yeter.
        let tail = String(context.suffix(Self.contextCharacterBudget))
        let contextTokens = tokenizer.encode(text: " " + tail).suffix(Self.contextTokenBudget)
        return (promptTokens ?? []) + Array(contextTokens)
    }

    /// Ölçümle seçildi, tahminle değil — bkz. `--selftest --context`.
    private static let contextCharacterBudget = 120
    private static let contextTokenBudget = 32

    // MARK: - Terminoloji yönlendirme

    /// Glossary.terms -> token id'leri. WhisperKit `promptTokens.suffix()` ile
    /// SONDAN tutuyor, yani kritik terimler listenin SONUNDA olmalı.
    /// (faster-whisper `hotwords` bunun tersi — oradan taşırken listeyi çevir.)
    private func buildPromptTokens() {
        guard useGlossary else { return }
        guard let tokenizer = pipe?.tokenizer else {
            Trace.log("tokenizer hazır değil — sözlük yönlendirmesi atlandı")
            return
        }
        let text = Glossary.promptText
        guard !text.isEmpty else { return }

        let tokens = tokenizer.encode(text: " " + text)
        // Kırpmayı WhisperKit'e bırakmıyoruz: o yalnızca 111'lik TOPLAM tavanı
        // biliyor, bağlama yer ayırmayı bilmiyor. Sondan tutuyoruz çünkü
        // dosyanın kuralı "en kritik terimler sona" (WhisperKit de suffix alır).
        if tokens.count > Self.glossaryTokenBudget {
            Trace.log("sözlük \(tokens.count) token — bütçe \(Self.glossaryTokenBudget), BAŞTAKİ terimler düşürüldü")
        } else {
            Trace.log("sözlük yüklendi (\(tokens.count) token / \(Self.glossaryTokenBudget) bütçe)")
        }
        promptTokens = Array(tokens.suffix(Self.glossaryTokenBudget))
    }

    /// Bilinen Whisper Türkçe halüsinasyon kalıpları — sessizlik/gürültü
    /// üzerine üretilen sahte altyazı kredisi ("Altyazı M.K." tipi). Harf
    /// dışındaki her şeyi (nokta, boşluk, büyük/küçük harf) atıp KANONİK
    /// biçimde karşılaştırıyoruz, yoksa "Altyazı M.K" / "altyazı m.k." gibi
    /// varyasyonlar kaçar.
    ///
    /// Parça zaten VAD tarafından AYRI çevrildiği için (bkz. akan metin),
    /// segmentin TAMAMI bu kalıba denk gelirse gerçek konuşmayla karışmadan
    /// güvenle atılabilir — `deliver()` zaten boş metni görmezden geliyor.
    private static let hallucinations: Set<String> = ["altyazımk"]

    private static func canonicalForHallucinationCheck(_ text: String) -> String {
        text.lowercased(with: Locale(identifier: "tr_TR"))
            .unicodeScalars.filter { CharacterSet.letters.contains($0) }
            .map(String.init).joined()
    }

    private static func clean(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hallucinations.contains(canonicalForHallucinationCheck(out)) else { return "" }

        out = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = FillerWords.strip(from: out)
        // Sıra önemli: önce yanlış duyulanı düzelt, sonra kısayolu genişlet.
        // Tersi olsaydı yanlış duyulmuş bir tetikleyici hiç eşleşmezdi.
        return Snippets.apply(to: Replacements.apply(to: out))
    }

    enum TranscriberError: LocalizedError {
        case notLoaded
        var errorDescription: String? { "Model henüz yüklenmedi." }
    }
}
