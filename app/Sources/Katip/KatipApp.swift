import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

@main
struct KatipApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // LSUIElement=true olduğu için görünür pencere yok; bu sahne sadece
        // SwiftUI yaşam döngüsünü kurar. Arayüz NSStatusItem üzerinden.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private let hotkey = HotkeyMonitor()
    private var animationTimer: Timer?
    private var spinner: NSProgressIndicator?
    private var smoothedLevel: Float = 0
    private var hud: HUDPanel?
    private var wasShown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Öz-test: mikrofon/tıklama gerektirmeden ASR hattını doğrular.
        //   Katip.app/Contents/MacOS/Katip --selftest ses.wav
        if let i = CommandLine.arguments.firstIndex(of: "--learn") {
            let dirs = Array(CommandLine.arguments.dropFirst(i + 1))
                .filter { !$0.hasPrefix("--") }
            runLearn(directories: dirs.isEmpty ? ["~/Desktop"] : dirs)
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--fix") {
            let input = CommandLine.arguments.dropFirst(i + 1).joined(separator: " ")
            print(Snippets.apply(to: Replacements.apply(to: input)))
            exit(0)
        }

        if CommandLine.arguments.contains("--loginprobe") {
            print("baslangic durum: \(SMAppService.mainApp.status.rawValue) (0=notRegistered 1=enabled 2=requiresApproval 3=notFound)")
            let ok = LoginItem.toggle()
            print("toggle sonuc: \(ok) · yeni durum: \(SMAppService.mainApp.status.rawValue) · isEnabled=\(LoginItem.isEnabled)")
            _ = LoginItem.toggle()   // eski hale dondur
            print("geri alindi · durum: \(SMAppService.mainApp.status.rawValue)")
            exit(0)
        }

        if CommandLine.arguments.contains("--historyprobe") {
            History.shared.add(text: "şu component'i refactor edelim", app: "Cursor", seconds: 2.4)
            History.shared.add(text: "Zustand store'una persist ekle", app: "Terminal", seconds: 3.1)
            print("saklama: \(History.retentionDays) gün · kayıt sayısı: \(History.shared.entries.count)")
            print("arama 'zustand': \(History.shared.search("zustand").count) sonuç")
            print("arama 'ZUSTAND': \(History.shared.search("ZUSTAND").count) sonuç (buyuk/kucuk)")
            print("arama 'yok': \(History.shared.search("yok").count) sonuç")
            exit(0)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--vadtest") {
            runVADTest(path: CommandLine.arguments.dropFirst(index + 1).first)
            return
        }

        // Mikrofon hattını uygulamanın KENDİ imzasıyla ölçer. "Ses algılanmadı"
        // hatasında suçlunun izin mi, cihaz mı, kod mu olduğunu ayırmanın tek yolu.
        if CommandLine.arguments.contains("--mictest") {
            runMicTest()
            return
        }

        if CommandLine.arguments.contains("--rendercard") {
            let dir = CommandLine.arguments.last ?? "/tmp"
            let flat = [CGFloat](repeating: 0.05, count: 16)
            let wave: [CGFloat] = [0.2,0.5,0.9,0.4,0.7,1.0,0.3,0.6,0.85,0.45,0.75,0.35,0.55,0.25,0.6,0.4]
            HUDPanel.renderSample(mode: .collapsed, levels: flat, to: dir + "/card-collapsed.png")
            HUDPanel.renderSample(mode: .expanded, levels: flat, to: dir + "/card-expanded.png")
            // Akan dalgayı dört farklı karede göster: tek kare akışı kanıtlamıyor.
            for (index, ticks) in [10, 14, 18, 22].enumerated() {
                HUDPanel.renderSample(mode: .listening, levels: wave,
                                      to: dir + "/card-listening-\(index).png", ticks: ticks)
            }
            HUDPanel.renderSample(mode: .listening, levels: wave,
                                  to: dir + "/card-listening.png", ticks: 16)
            HUDPanel.renderSample(mode: .notice("Mikrofon izni yok"), levels: flat,
                                  to: dir + "/card-notice.png")
            HUDPanel.renderSample(mode: .result("Şu component'i refactor edelim, state yönetimi Zustand'a geçsin."),
                                  levels: flat, to: dir + "/card-result.png")
            print("render edildi: \(dir)")
            exit(0)
        }

        if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
            let path = CommandLine.arguments.dropFirst(index + 1).first
            runSelfTest(path: path)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = icon(for: controller.state)
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "Katip"
        }

        controller.onChange = { [weak self] state in
            self?.render(state)
        }
        controller.onIgnoredClick = { [weak self] message in
            self?.flash(message)
        }
        controller.onNeedsAccessibility = { [weak self] in
            self?.promptForAccessibility()
        }
        controller.onUndelivered = { [weak self] text in
            self?.hud?.present(result: text)
        }
        if HUDPanel.isEnabled { showHUD() }

        hotkey.onNeedsPermission = { [weak self] in self?.promptForInputMonitoring() }
        hotkey.onPress = { [weak self] in self?.controller.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.controller.hotkeyReleased() }
        hotkey.start()

        controller.prepare()
    }

    // MARK: - Etkileşim

    /// Sol tık: kaydı başlat/bitir (istenen davranış — menü açmadan doğrudan).
    /// Sağ tık: menü.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true

        if isRightClick {
            showMenu()
        } else {
            controller.toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: controller.state.label, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if !controller.lastTranscript.isEmpty {
            let preview = String(controller.lastTranscript.prefix(50))
            let item = NSMenuItem(title: "Son metni kopyala: \(preview)…",
                                  action: #selector(copyLast), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        let history = NSMenuItem(title: "Geçmiş…", action: #selector(showHistory),
                                 keyEquivalent: "h")
        history.target = self
        menu.addItem(history)
        menu.addItem(.separator())

        let login = NSMenuItem(title: LoginItem.needsApproval
                               ? "Girişte başlat (Ayarlar'dan onayla)"
                               : "Girişte başlat",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)

        let hudItem = NSMenuItem(title: "Yüzen kart", action: #selector(toggleHUD),
                                 keyEquivalent: "")
        hudItem.target = self
        hudItem.state = HUDPanel.isEnabled ? .on : .off
        menu.addItem(hudItem)

        // Kapalı biçim bilerek neredeyse görünmez; kaybolduğunda geri çağıracak
        // bir yol olmalı.
        let findItem = NSMenuItem(title: "Kartı ekranın ortasına al",
                                  action: #selector(recenterHUD), keyEquivalent: "")
        findItem.target = self
        findItem.isEnabled = HUDPanel.isEnabled
        menu.addItem(findItem)
        menu.addItem(.separator())

        let hotkeyItem = NSMenuItem(title: "Kısayol tuşu", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for choice in HotkeyChoice.allCases {
            let entry = NSMenuItem(title: choice.title, action: #selector(pickHotkey(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = choice.rawValue
            entry.state = (choice == HotkeyChoice.current) ? .on : .off
            hotkeyMenu.addItem(entry)
        }
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        let howto = NSMenuItem(title: "   basılı tut → konuş · çift bas → kilitle",
                               action: nil, keyEquivalent: "")
        howto.isEnabled = false
        menu.addItem(howto)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Sözlük yönlendirmesi (~2 sn yavaşlatır)",
                                action: #selector(toggleGlossary), keyEquivalent: "")
        toggle.target = self
        toggle.state = Transcriber.glossaryEnabled ? .on : .off
        menu.addItem(toggle)

        let glossary = NSMenuItem(title: "Sözlüğü düzenle…",
                                  action: #selector(openGlossary), keyEquivalent: "")
        glossary.target = self
        menu.addItem(glossary)

        let replacements = NSMenuItem(title: "Düzeltme tablosunu düzenle…",
                                      action: #selector(openReplacements), keyEquivalent: "")
        replacements.target = self
        menu.addItem(replacements)

        let snippets = NSMenuItem(title: "Metin kısayollarını düzenle…",
                                  action: #selector(openSnippets), keyEquivalent: "")
        snippets.target = self
        menu.addItem(snippets)

        let learn = NSMenuItem(title: "Projelerimden terim öğren…",
                               action: #selector(learnFromProjects), keyEquivalent: "")
        learn.target = self
        menu.addItem(learn)

        menu.addItem(.separator())

        let accessibility = NSMenuItem(
            title: Permissions.hasAccessibility ? "✔ Erişilebilirlik izni var"
                                                : "⚠️ Erişilebilirlik izni ver… (metin yazma)",
            action: #selector(fixAccessibility), keyEquivalent: "")
        accessibility.target = self
        menu.addItem(accessibility)

        let listen = NSMenuItem(
            title: Permissions.hasInputMonitoring ? "✔ Giriş İzleme izni var"
                                                  : "⚠️ Giriş İzleme izni ver… (kısayol tuşu)",
            action: #selector(fixInputMonitoring), keyEquivalent: "")
        listen.target = self
        menu.addItem(listen)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Çık", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // menü kalıcı olmasın, sol tık yine doğrudan kayıt açsın
    }

    @objc private func showHistory() {
        HistoryWindowController.shared.show()
    }

    @objc private func toggleLoginItem() {
        if !LoginItem.toggle() {
            flash("Girişte başlat ayarlanamadı — Sistem Ayarları > Genel > Giriş Öğeleri")
        }
    }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
    }

    @objc private func recenterHUD() {
        if hud == nil { HUDPanel.isEnabled = true }
        showHUD()
        hud?.recenter()
    }

    @objc private func toggleHUD() {
        HUDPanel.isEnabled.toggle()
        if HUDPanel.isEnabled { showHUD() } else { hideHUD() }
    }

    private func showHUD() {
        if hud == nil {
            let panel = HUDPanel()
            panel.onAction = { [weak self] action in self?.handle(action) }
            hud = panel
        }
        let firstTime = !wasShown
        wasShown = true
        hud?.show()
        hud?.update(state: controller.state, level: 0)
        if firstTime { hud?.peek() }   // kapalı biçim çok sönük — nerede olduğunu göster
        startAnimation()   // boştayken de yaşasın (dalgalar sönümlensin)
    }

    /// Karttaki düğmeler. Panel hiçbir kararı kendi vermiyor; hepsi buradan
    /// tek durum makinesine gidiyor — ikon, kısayol ve kart aynı yolu kullansın.
    private func handle(_ action: HUDPanel.Action) {
        switch action {
        case .dictate:  controller.toggle()
        case .finish:   controller.toggle()
        case .cancel:   controller.cancel()
        case .lock:     controller.lock()
        case .language: flash("Dikte dili: \(controller.cycleLanguage())")
        case .copyText:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
            hud?.dismissOverlay()
        case .dismiss:  hud?.dismissOverlay()
        }
    }

    private func hideHUD() {
        hud?.orderOut(nil)
        hud = nil
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = HotkeyChoice(rawValue: raw) else { return }
        HotkeyChoice.current = choice
        hotkey.start()   // yeni tuşla yeniden bağlan
        Trace.log("kısayol değiştirildi: \(choice.title)")
    }

    @objc private func toggleGlossary() {
        Transcriber.glossaryEnabled.toggle()
        Trace.log("sözlük yönlendirmesi: \(Transcriber.glossaryEnabled ? "açık" : "kapalı") — yeniden başlat")
        flash(Transcriber.glossaryEnabled
              ? "Sözlük açıldı (~2 sn yavaşlar) — yeniden başlat"
              : "Sözlük kapatıldı — yeniden başlat")
    }

    @objc private func openGlossary() {
        _ = Glossary.load()
        NSWorkspace.shared.open(Glossary.fileURL)
    }

    @objc private func openReplacements() {
        _ = Replacements.load()
        NSWorkspace.shared.open(Replacements.fileURL)
    }

    /// Menüden tetiklenince kendi binary'sini `--learn` ile çalıştırıp sonucu
    /// Terminal'de gösteriyoruz: çıktı listesi uzun ve kullanıcı gözden geçirmeli.
    @objc private func learnFromProjects() {
        let binary = Bundle.main.executableURL?.path ?? ""
        let script = """
        tell application "Terminal"
            activate
            do script "'\(binary)' --learn ~/Desktop; echo; echo 'Önerileri gözden geçir:'; open '\(Vocabulary.proposalsURL.path)' 2>/dev/null || true"
        end tell
        """
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    @objc private func openSnippets() {
        _ = Snippets.load()
        NSWorkspace.shared.open(Snippets.fileURL)
    }

    @objc private func fixInputMonitoring() {
        promptForInputMonitoring()
    }

    @objc private func fixAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    /// Tıklamanın neden işe yaramadığını göster. Sessizlik en kötü cevap.
    ///
    /// Kart açıkken mesajı KARTTA gösteriyoruz: menü açmak odağı kapıyor, yani
    /// yazacağımız uygulamanın imleç konumunu kaybediyoruz.
    private func flash(_ message: String) {
        if let hud {
            hud.present(notice: message)
            startAnimation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                hud.dismissOverlay()
            }
            return
        }
        let menu = NSMenu()
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Giriş İzleme olmadan kısayol tuşu hiç çalışmaz (olaylar hiç gelmez).
    /// Erişilebilirlik'ten AYRI bir izin — biri diğerinin yerine geçmiyor.
    private func promptForInputMonitoring() {
        Trace.log("Giriş İzleme izni yok — sistem izin akışı tetikleniyor")
        Permissions.requestInputMonitoring()
        Permissions.openSettings(.inputMonitoring)
    }

    /// Erişilebilirlik izni olmadan metin hiçbir yere yazılamaz.
    ///
    /// NSAlert KULLANMIYORUZ: `runModal()` ana döngüyü bloke ediyor ve model
    /// yüklemesinin MainActor devamı asılı kalıyordu — uygulama hiç hazır olmuyordu.
    /// Bunun yerine sistemin kendi (bloke etmeyen) izin akışını tetikleyip
    /// Ayarlar'ı açıyoruz; durum ikonda ve menüde görünüyor.
    private func promptForAccessibility() {
        Trace.log("erişilebilirlik izni yok — sistem izin akışı tetikleniyor")
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    /// VAD'i mikrofon olmadan doğrula: hazır bir wav'ı gerçek zamanlı beslermiş
    /// gibi bloklara böl, kesim noktalarını yazdır.
    private func runVADTest(path: String?) {
        guard let path, let samples = try? Self.readAudio(at: path) else { exit(2) }
        let rate = 16_000.0
        print("ses: \(String(format: "%.1f", Double(samples.count) / rate)) sn")

        var segmenter = SpeechSegmenter()
        var buffer: [Float] = []
        var segments: [(Double, Double, Double)] = []
        var consumed = 0.0
        let block = 4096

        var index = 0
        while index < samples.count {
            let end = min(index + block, samples.count)
            let chunk = Array(samples[index..<end])
            buffer.append(contentsOf: chunk)
            let peak = chunk.reduce(Float(0)) { max($0, abs($1)) }

            if let cut = segmenter.feed(peak: peak, frames: chunk.count,
                                        bufferedSamples: buffer.count) {
                let length = Double(cut.index) / rate
                segments.append((consumed, consumed + length, cut.silence))
                consumed += length
                buffer.removeFirst(cut.index)
            }
            index = end
        }

        print("\n\(segments.count) parça:")
        for (number, span) in segments.enumerated() {
            print(String(format: "  %2d) %5.1f–%5.1f sn  (%.1f sn)  ardından %.1f sn sessizlik → %@",
                         number + 1, span.0, span.1, span.1 - span.0, span.2,
                         span.2 < Stitcher.sentenceGap ? "cümle SÜRÜYOR" : "cümle SONU"))
        }
        let leftover = Double(buffer.count) / rate
        print(String(format: "  artık: %.1f sn", leftover))
        exit(0)
    }

    /// Projelerden terim öğren, geçmişle karşılaştırıp kural öner.
    private func runLearn(directories: [String]) {
        print("• taranıyor: \(directories.joined(separator: ", "))")
        let found = Vocabulary.scan(directories: directories)
        guard !found.isEmpty else { print("hiç package.json bulunamadı"); exit(1) }

        // Birden çok projede geçen terim daha güvenilir → önce onlar.
        let sorted = found.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        let terms = sorted.map(\.key)

        try? terms.joined(separator: "\n").appending("\n")
            .write(to: Vocabulary.fileURL, atomically: true, encoding: .utf8)
        print("✔ \(terms.count) terim → \(Vocabulary.fileURL.lastPathComponent)\n")

        print("en yaygın terimler:")
        for (term, projects) in sorted.prefix(12) {
            print(String(format: "  %-26s %d proje", (term as NSString).utf8String!, projects.count))
        }

        let history = History.shared.entries.map(\.text)
        print("\n• geçmişte \(history.count) dikte var")
        guard !history.isEmpty else {
            print("  kural önerisi için gerçek dikte lazım — bir süre kullandıktan sonra tekrar çalıştır")
            exit(0)
        }

        let proposals = Vocabulary.proposeRules(terms: terms, transcripts: history)
        if proposals.isEmpty {
            print("  yakın-kaçırma bulunamadı")
        } else {
            let body = "# Katip — önerilen kurallar (gözden geçir, beğendiğini replacements.txt'e taşı)\n"
                + proposals.map { "\($0.0) = \($0.1)" }.joined(separator: "\n") + "\n"
            try? body.write(to: Vocabulary.proposalsURL, atomically: true, encoding: .utf8)
            print("\n\(proposals.count) kural önerisi → \(Vocabulary.proposalsURL.lastPathComponent)")
            for (wrong, right) in proposals.prefix(15) { print("  \(wrong) = \(right)") }
        }
        exit(0)
    }

    // MARK: - Öz-test

    private func runSelfTest(path: String?) {
        guard let path else {
            print("kullanım: Katip --selftest <ses.wav>")
            exit(2)
        }
        Task {
            do {
                print("• ses okunuyor: \(path)")
                let samples = try Self.readAudio(at: path)
                print("  \(samples.count) örnek (\(String(format: "%.1f", Double(samples.count) / 16000)) sn)")

                let args = CommandLine.arguments
                let model = args.firstIndex(of: "--model").flatMap { args.dropFirst($0 + 1).first }
                let useGlossary = args.contains("--glossary") ? true : (args.contains("--no-glossary") ? false : nil)
                print("• model: \(model ?? Transcriber.defaultModel)  sözlük: \(useGlossary ?? Transcriber.glossaryEnabled)")
                let transcriber = Transcriber()
                var clock = Date()
                try await transcriber.load(model: model, useGlossary: useGlossary)
                if let li = args.firstIndex(of: "--lang"), let lang = args.dropFirst(li + 1).first {
                    await transcriber.setLanguage(lang == "auto" ? nil : lang)
                    print("• dil: \(lang)")
                }
                print("  hazır (\(String(format: "%.1f", Date().timeIntervalSince(clock))) sn)")

                // Bağlam yönlendirmesinin BEDELİNİ ölçmek için: her prompt
                // token'ı decoder prefill'ine ekleniyor ve ücretsiz değil.
                let context = args.firstIndex(of: "--context").flatMap { args.dropFirst($0 + 1).first }
                if let context { print("• bağlam: \"\(context)\"") }

                // Üç kez: ilk tur ısınmayı içerir, asıl önemli olan sürekli hâl.
                let audioSeconds = Double(samples.count) / 16000
                var text = ""
                for run in 1...3 {
                    clock = Date()
                    text = try await transcriber.transcribe(samples, context: context)
                    let elapsed = Date().timeIntervalSince(clock)
                    print("  tur \(run): \(String(format: "%.2f", elapsed)) sn  (RTF \(String(format: "%.2f", elapsed / audioSeconds))x)")
                }
                print("\nSONUÇ: \(text)\n")
                exit(text.isEmpty ? 1 : 0)
            } catch {
                print("HATA: \(error)")
                exit(1)
            }
        }
    }

    private static func readAudio(at path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                           frameCapacity: AVAudioFrameCount(file.length))
        else { throw NSError(domain: "Katip", code: 1) }

        try file.read(into: input)

        let ratio = target.sampleRate / file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { throw NSError(domain: "Katip", code: 2) }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard let channel = output.floatChannelData else { throw NSError(domain: "Katip", code: 3) }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// 4 saniye kaydeder, ham girdi formatını ve tepe genliği yazar.
    private func runMicTest() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        print("giriş formatı : \(format.sampleRate) Hz · \(format.channelCount) kanal")
        print("mikrofon izni : \(Permissions.hasMicrophone)")

        // 1) Akustikten bağımsız kesin sınav: sentetik çok kanallı sinüs, gerçek
        //    dönüşüm hattı. "3 kanal → mono" indirgemesi bozulursa burası yakalar.
        if let r = AudioRecorder.conversionSelfCheck(source: format) {
            let ok = r.output > 0.1
            print("dönüşüm sınavı: \(format.channelCount)ch sinüs \(String(format: "%.2f", r.input)) → mono \(String(format: "%.4f", r.output))  \(ok ? "✓" : "✗ SESSİZ — kanal indirgemesi bozuk")")
        } else {
            print("dönüşüm sınavı: ✗ kurulamadı")
        }

        // Karşılaştırma: ESKİ yol — dönüştürücüye kanal indirgemesini de yaptır.
        // Teşhisi kanıtlıyor; "sanırım buydu" ile "buydu" arasındaki fark.
        if let mono16 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                      channels: 1, interleaved: false),
           let direct = AVAudioConverter(from: format, to: mono16),
           let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800),
           let data = input.floatChannelData,
           let out = AVAudioPCMBuffer(pcmFormat: mono16, frameCapacity: 4800) {
            input.frameLength = 4800
            for c in 0..<Int(format.channelCount) {
                for f in 0..<4800 {
                    data[c][f] = 0.5 * sinf(2 * .pi * 440 * Float(f) / Float(format.sampleRate))
                }
            }
            var supplied = false
            var convError: NSError?
            direct.convert(to: out, error: &convError) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            var directPeak: Float = 0
            if let ch = out.floatChannelData {
                for f in 0..<Int(out.frameLength) { directPeak = max(directPeak, abs(ch[0][f])) }
            }
            print("eski yol      : \(format.channelCount)ch sinüs 0.50 → mono \(String(format: "%.4f", directPeak))  \(directPeak > 0.1 ? "✓" : "✗ SESSİZ (hata yok, sessizce sıfır)")")
            if let convError { print("  dönüştürücü hatası: \(convError)") }
        }
        print("")

        var peaks = [Float](repeating: 0, count: Int(format.channelCount))
        var frames = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            frames += Int(buffer.frameLength)
            guard let channels = buffer.floatChannelData else { return }
            for c in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) {
                    peaks[c] = max(peaks[c], abs(channels[c][i]))
                }
            }
        }
        do { engine.prepare(); try engine.start() } catch {
            print("✗ motor başlamadı: \(error)"); exit(1)
        }
        print("▶ 4 saniye konuş…")
        Thread.sleep(forTimeInterval: 4)
        engine.stop()
        print("örnek         : \(frames)")
        for (c, p) in peaks.enumerated() {
            print("  kanal \(c)     : \(String(format: "%.4f", p))")
        }
        let peak = peaks.max() ?? 0

        // Dönüştürücünün çok kanaldan mono'ya inebildiğini AYRICA sına: motorun
        // ses vermesi yetmiyor, bizim hattımızın o sesi taşıyabilmesi gerek.
        if let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: 16_000, channels: 1, interleaved: false),
           let conv = AVAudioConverter(from: format, to: mono) {
            print("dönüştürücü   : kuruldu (\(format.channelCount)ch → 1ch)")
            _ = conv
        } else {
            print("dönüştürücü   : ✗ kurulamadı")
        }

        print("ham tepe      : \(String(format: "%.4f", peak))")

        // Asıl sınav: uygulamanın GERÇEK kayıt hattı. Ham motorun ses vermesi
        // yetmiyor — 3 kanal → mono indirgemesi burada patlıyordu.
        print("▶ kayıt hattı sınanıyor, 4 saniye daha konuş…")
        let recorder = AudioRecorder()
        do { try recorder.start() } catch {
            print("✗ kayıt başlamadı: \(error)"); exit(1)
        }
        Thread.sleep(forTimeInterval: 4)
        let captured = (try? recorder.stop()) ?? []
        print("kayıt örneği  : \(captured.count) (16 kHz mono)")
        print("HAT TEPE      : \(String(format: "%.4f", recorder.lastPeak))")

        // Ham ölçüm ile hat ölçümü FARKLI zaman pencerelerinden geliyor; birbirine
        // oranlayıp hüküm vermek yanıltıcı olur. Sadece raporla.
        print(recorder.lastPeak < 0.0001
              ? "✗ hat tam sessiz"
              : "✓ hat ses taşıyor (konuşurken ≥0.02 bekleniyor — kapı bu)")
        exit(0)
    }

    // MARK: - Görünüm

    private func render(_ state: DictationController.State) {
        hud?.update(state: state, level: controller.inputLevel)
        guard let button = statusItem.button else { return }
        button.toolTip = "Katip — \(state.label)"

        switch state {
        case .recording, .locked:
            stopSpinner()
            startAnimation()
            // Kayıtta kırmızı: bakmadan da "açık" olduğu anlaşılsın.
            button.contentTintColor = state == .locked ? .systemOrange : .systemRed
        case .transcribing:
            stopAnimation()
            startSpinner()
            button.contentTintColor = nil
        default:
            // Kart açıkken animasyon döngüsü sürsün: dalgalar yumuşakça sönümlensin
            // ve durum metni canlı kalsın.
            if hud == nil { stopAnimation() }
            stopSpinner()
            button.contentTintColor = nil
            button.image = icon(for: state)
            button.image?.isTemplate = true
        }

        if case .error(let message) = state { Trace.log("durum hatası: \(message)") }
    }

    // MARK: - Animasyonlar

    /// Konuşurken ikon canlı ses seviyesiyle dalgalanır.
    /// Sabit bir "kayıtta" ikonu sadece açık olduğunu söyler; seviye ise
    /// mikrofonun seni gerçekten duyduğunu söyler — asıl kritik geri bildirim bu.
    private func startAnimation() {
        guard animationTimer == nil else { return }
        // 30 fps: akan dalga 15 fps'te kesik görünüyordu. Boşta zaten duruyor
        // (isSettled ile), o yüzden pil maliyeti sadece dikte sürerken.
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        smoothedLevel = 0
    }

    private func tick() {
        hud?.update(state: controller.state, level: controller.inputLevel)

        // Boşta kart sönümlenince döngüyü kes: menü çubuğu yardımcısı gün boyu
        // açık duruyor, sürekli çizim pil yakar (%9 CPU ölçüldü).
        switch controller.state {
        case .recording, .locked, .transcribing: break
        default:
            if hud?.isSettled ?? true { stopAnimation(); return }
        }

        guard let button = statusItem.button else { return }
        // Ham seviye çok zıplıyor; yumuşat ve konuşma aralığına göre yükselt.
        let raw = min(1, controller.inputLevel * 6)
        smoothedLevel += (raw - smoothedLevel) * 0.4
        let value = Double(max(0.05, smoothedLevel))

        button.image = NSImage(systemSymbolName: "waveform",
                               variableValue: value,
                               accessibilityDescription: "Dinliyor")
        button.image?.isTemplate = false
    }

    /// Çeviri sırasında native yükleniyor topacı.
    private func startSpinner() {
        guard spinner == nil, let button = statusItem.button else { return }
        button.image = nil

        let indicator = NSProgressIndicator(frame: NSRect(x: 4, y: 4, width: 14, height: 14))
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isIndeterminate = true
        indicator.startAnimation(nil)
        button.addSubview(indicator)
        spinner = indicator
    }

    private func stopSpinner() {
        spinner?.stopAnimation(nil)
        spinner?.removeFromSuperview()
        spinner = nil
    }


    private func icon(for state: DictationController.State) -> NSImage? {
        let image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: "Katip")
        return image
    }
}
