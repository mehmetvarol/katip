import AppKit
import AVFoundation
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Öz-test: mikrofon/tıklama gerektirmeden ASR hattını doğrular.
        //   Katip.app/Contents/MacOS/Katip --selftest ses.wav
        if let index = CommandLine.arguments.firstIndex(of: "--vadtest") {
            runVADTest(path: CommandLine.arguments.dropFirst(index + 1).first)
            return
        }

        if CommandLine.arguments.contains("--rendercard") {
            let dir = CommandLine.arguments.last ?? "/tmp"
            let wave: [CGFloat] = [0.2,0.5,0.9,0.4,0.7,1.0,0.3,0.6,0.85,0.45,0.75,0.35,0.55,0.25]
            HUDPanel.renderSample(state: .idle, levels: Array(repeating: 0.06, count: 14),
                                  to: dir + "/card-idle.png")
            HUDPanel.renderSample(state: .recording, levels: wave, to: dir + "/card-recording.png")
            HUDPanel.renderSample(state: .locked, levels: wave, to: dir + "/card-locked.png")
            HUDPanel.renderSample(state: .transcribing, levels: wave, to: dir + "/card-transcribing.png")
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

        let hudItem = NSMenuItem(title: "Yüzen kart", action: #selector(toggleHUD),
                                 keyEquivalent: "")
        hudItem.target = self
        hudItem.state = HUDPanel.isEnabled ? .on : .off
        menu.addItem(hudItem)
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

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
    }

    @objc private func toggleHUD() {
        HUDPanel.isEnabled.toggle()
        if HUDPanel.isEnabled { showHUD() } else { hideHUD() }
    }

    private func showHUD() {
        if hud == nil {
            let panel = HUDPanel()
            // Karta tıklamak menü çubuğu ikonuyla aynı işi yapsın.
            panel.onClick = { [weak self] in self?.controller.toggle() }
            hud = panel
        }
        hud?.show()
        hud?.update(state: controller.state, level: 0)
        startAnimation()   // boştayken de yaşasın (dalgalar sönümlensin)
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

    @objc private func fixInputMonitoring() {
        promptForInputMonitoring()
    }

    @objc private func fixAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
    }

    /// Tıklamanın neden işe yaramadığını göster. Sessizlik en kötü cevap.
    private func flash(_ message: String) {
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
        var segments: [(Double, Double)] = []
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
                let length = Double(cut) / rate
                segments.append((consumed, consumed + length))
                consumed += length
                buffer.removeFirst(cut)
            }
            index = end
        }

        print("\n\(segments.count) parça:")
        for (number, span) in segments.enumerated() {
            print(String(format: "  %2d) %5.1f–%5.1f sn  (%.1f sn)",
                         number + 1, span.0, span.1, span.1 - span.0))
        }
        let leftover = Double(buffer.count) / rate
        print(String(format: "  artık: %.1f sn", leftover))
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
                print("  hazır (\(String(format: "%.1f", Date().timeIntervalSince(clock))) sn)")

                // Üç kez: ilk tur ısınmayı içerir, asıl önemli olan sürekli hâl.
                let audioSeconds = Double(samples.count) / 16000
                var text = ""
                for run in 1...3 {
                    clock = Date()
                    text = try await transcriber.transcribe(samples)
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
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
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
