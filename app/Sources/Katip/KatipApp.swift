import AppKit
import AVFoundation
import ServiceManagement

/// Giriş noktası — SwiftUI `App` DEĞİL, düz AppKit.
///
/// Önceden `struct KatipApp: App` + boş bir `Settings { EmptyView() }` sahnesi
/// vardı, tek amacı SwiftUI yaşam döngüsünü kurmaktı. macOS 27'de bu sahne
/// açılışta 900×450'lik boş bir "Katip Settings" penceresi olarak açılmaya
/// başladı (kullanıcı ekran görüntüsüyle bildirdi, pencere listesinde de
/// görüldü). Arayüzün tamamı zaten AppKit (NSStatusItem, paneller); SwiftUI
/// sadece geçmiş penceresinin içinde `NSHostingController` ile kullanılıyor,
/// onun için App yaşam döngüsü gerekmiyor.
@main
enum KatipMain {
    /// `NSApplication.delegate` zayıf referans — delege burada canlı tutuluyor.
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.mainMenu = makeMainMenu()
        app.run()
    }

    /// SwiftUI App'in kendiliğinden verdiği ana menünün yerine. LSUIElement
    /// olduğu için görünmüyor ama kısayolların kaynağı bu: geçmiş penceresinin
    /// arama alanında ⌘C/⌘V/⌘A/⌘Z ve pencereyi ⌘W ile kapatmak ancak bu menü
    /// öğeleri varsa çalışıyor.
    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Pencereyi Kapat", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Katip'ten Çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Düzen")
        edit.addItem(withTitle: "Geri Al", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Yinele", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Kes", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopyala", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Yapıştır", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Tümünü Seç", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let controller = DictationController()
    private let hotkey = HotkeyMonitor()
    private let updater = Updater()
    private var animationTimer: Timer?
    /// İkonun dolumu — yüzen kartın dalgasıyla AYNI uyarlanır ölçer.
    private var iconMeter = LevelMeter()
    private var lastIconTick = CACurrentMediaTime()
    private var hud: HUDPanel?
    private var wasShown = false

    /// nil değilse: uygulama Uygulamalar klasöründe değil. Bu durumda
    /// izinler (Erişilebilirlik/Mikrofon/Giriş İzleme) HER AÇILIŞTA
    /// sıfırlanır — bkz. `checkInstallLocation()`.
    private var installLocationWarning: String?

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

        // Ses saklama turu: yaz → oku → karşılaştır. Yeniden çeviri buna
        // dayanıyor; bozuk bir kaydet/oku sessizce kötü metin üretirdi.
        if CommandLine.arguments.contains("--recordingprobe") {
            runRecordingProbe()
            return
        }

        // Kartın çerçevesi GERÇEKTEN akıyor mu? Yay matematiği ve iniş kararı
        // ayrı ayrı test edildi ama ikisini pencereye bağlayan zincir (display
        // link → setFrame) ancak burada görünüyor. Ekran gerekmiyor: pencere
        // çerçevesini kare kare örnekliyoruz.
        if CommandLine.arguments.contains("--hudprobe") {
            let panel = HUDPanel()
            panel.show()
            let start = panel.frame
            var samples: [(t: Double, w: CGFloat)] = []
            let t0 = CACurrentMediaTime()
            panel.update(state: .recording, level: 0.5)   // .collapsed → .listening

            Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
                samples.append((CACurrentMediaTime() - t0, panel.frame.width))
                guard CACurrentMediaTime() - t0 > 0.7 else { return }
                timer.invalidate()

                print("başlangıç genişlik \(Int(start.width)) → hedef \(Int(panel.frame.width))")
                print("\nyörünge (16 ms aralık):")
                for s in samples where Int(s.t * 1000) % 48 < 20 {
                    let filled = Int((s.w - start.width) / max(1, panel.frame.width - start.width) * 40)
                    print(String(format: "  %4.0f ms  %6.1f px  %@", s.t * 1000, s.w,
                                 String(repeating: "█", count: max(0, min(40, filled)))))
                }
                let distinct = Set(samples.map { Int($0.w) }).count
                print("\nfarklı ara genişlik: \(distinct)")
                print(distinct >= 5 ? "✔ çerçeve akıyor (sıçrama değil)"
                                    : "✗ SIÇRAMA — animasyon çalışmıyor")
                exit(distinct >= 5 ? 0 : 1)
            }
            return
        }

        // Bulanık terim eşleştirmesi: bilinen vakaları hâlâ yakalıyor mu,
        // gerçek geçmişte yeni bir yanlış pozitif üretmiş mi? Eşik ölçümle
        // seçildi (bkz. FuzzyTerms.swift); sözlük veya geçmiş değiştikçe bu
        // sondayı tekrar çalıştırmak dengeyi bozup bozmadığını gösterir.
        if CommandLine.arguments.contains("--fuzzytest") {
            let terms = Glossary.load()
            print("terimler: \(terms.joined(separator: ", "))\n")

            let known: [(String, String)] = [
                ("zostan", "Zustand"), ("persis", "persist"),
                ("komponent", "component"), ("kompanent", "component"),
            ]
            print("═══ bilinen vakalar ═══")
            var missed = 0
            for (wrong, expected) in known {
                if let m = FuzzyTerms.bestMatch(for: wrong, in: terms), m.term == expected {
                    print("✔ \(wrong) → \(m.term)\(m.suffix)  (mesafe \(m.distance))")
                } else {
                    print("✗ \(wrong) → yakalanamadı (beklenen \(expected))")
                    missed += 1
                }
            }

            print("\n═══ geçmişte yanlış pozitif taraması ═══")
            // GERÇEK zinciri yürütüyoruz: Replacements önce çalışır, "Zostan"
            // gibi ÇOKTAN kesin kuralla kapatılmış vakalar FuzzyTerms'e hiç
            // ulaşmaz. Sadece FuzzyTerms'i tek başına çalıştırmak, kural
            // eklenmeden ÖNCEKİ eski geçmiş metnini test edip yanlış alarm
            // verirdi.
            let entries = History.shared.entries
            var flagged = 0
            let pattern = try! NSRegularExpression(pattern: "[\\p{L}]+")
            for entry in entries {
                let afterExact = Replacements.apply(to: entry.text)
                let ns = afterExact as NSString
                for match in pattern.matches(in: afterExact, range: NSRange(location: 0, length: ns.length)) {
                    let word = ns.substring(with: match.range)
                    guard let m = FuzzyTerms.bestMatch(for: word, in: terms) else { continue }
                    let corrected = m.term + m.suffix
                    guard corrected.lowercased() != word.lowercased() else { continue }
                    flagged += 1
                    print("⚠️  \"\(word)\" → \"\(corrected)\"  (mesafe \(m.distance))  — \(afterExact.prefix(60))")
                }
            }
            print("\n\(entries.count) kayıt tarandı, \(flagged) yanlış pozitif")
            let ok = missed == 0 && flagged == 0
            print(ok ? "\n✔ sağlam" : "\n✗ dengesizlik var")
            exit(ok ? 0 : 1)
        }

        // Uygulama kuralları: eşleşme mantığı VE gerçek etkisi (sözlük
        // gerçekten kapanıyor mu) ölçülüyor.
        if CommandLine.arguments.contains("--appprofiletest") {
            print("═══ eşleşme ═══")
            let cases: [(String?, String, Bool)] = [
                ("Cursor", "tr,en", true),
                ("Visual Studio Code", "tr,en", true),
                ("Terminal", "tr,en", true),
                ("Mail", "tr", false),
                ("Slack", "tr", false),
                ("Notes", "tr", false),
                ("Safari", "?", false),   // hiçbir kuralla eşleşmemeli
                (nil, "?", false),
            ]
            var failed = 0
            for (name, expectedLang, expectedGlossary) in cases {
                let p = AppProfiles.profile(for: name)
                if name == "Safari" || name == nil {
                    let ok = p.language == nil && p.glossary == nil
                    print("\(ok ? "✔" : "✗") \(name ?? "nil") → kural yok bekleniyordu, bulunan: \(String(describing: p.language)), \(String(describing: p.glossary))")
                    if !ok { failed += 1 }
                } else {
                    let ok = p.language?.serialized == expectedLang && p.glossary == expectedGlossary
                    print("\(ok ? "✔" : "✗") \(name!) → \(p.language?.serialized ?? "nil"), sözlük=\(String(describing: p.glossary))  (beklenen \(expectedLang), \(expectedGlossary))")
                    if !ok { failed += 1 }
                }
            }

            print("\n═══ gerçek etki: sözlük override çeviriyi değiştiriyor mu ═══")
            let recordingArg = CommandLine.arguments.firstIndex(of: "--appprofiletest").flatMap {
                CommandLine.arguments.dropFirst($0 + 1).first
            }
            guard let path = recordingArg, let samples = try? Self.readAudio(at: path) else {
                print("(kayıt verilmedi — sadece eşleşme sınandı: Katip --appprofiletest <kayıt.wav>)")
                exit(failed == 0 ? 0 : 1)
            }
            Task {
                let transcriber = Transcriber()
                try? await transcriber.load()

                await transcriber.setGlossaryOverride(false)
                let off = (try? await transcriber.transcribe(samples)) ?? "(hata)"
                print("sözlük KAPALI (uygulama kuralı gibi) → \"\(off)\"")

                await transcriber.setGlossaryOverride(true)
                let on = (try? await transcriber.transcribe(samples)) ?? "(hata)"
                print("sözlük AÇIK  (uygulama kuralı gibi) → \"\(on)\"")

                let changed = off != on
                print(changed ? "\n✔ override gerçekten etkiliyor (iki çıktı farklı)"
                              : "\n(iki çıktı aynı — bu kayıtta sözlük zaten devreye girmiyor olabilir)")
                exit(failed == 0 ? 0 : 1)
            }
            return
        }

        // Dalga GERÇEK bir kayıtla nasıl davranıyor? Seviyeleri kayıttan
        // çıkarıp animasyonun kendi kodundan geçiriyoruz — render'daki tek tek
        // seviyeler değil, zaman içindeki gerçek davranış.
        if let index = CommandLine.arguments.firstIndex(of: "--waveprobe") {
            guard let path = CommandLine.arguments.dropFirst(index + 1).first,
                  let samples = try? Self.readAudio(at: path) else {
                print("kullanım: Katip --waveprobe <kayıt.wav>"); exit(2)
            }
            let bars = HUDPanel.waveTrace(samples: samples)

            let blocks = Array(" ▁▂▃▄▅▆▇█")
            print("kayıt: \((path as NSString).lastPathComponent)  ·  \(bars.count) tampon\n")
            print("seviye  " + String(bars.map { blocks[min(8, Int($0.level / 0.05 * 2))] }))
            print("dalga   " + String(bars.map { blocks[min(8, Int($0.height * 8.99))] }))

            // SÜREKLİ sessizlik: kendisi ve önceki ~0.5 sn sessiz olan tamponlar.
            // Konuşmanın hemen ardındaki tamponu "sessiz" saymak yanlış ölçüm —
            // orada dalga daha sönüyor ve sönme kuyruğu İSTENEN davranış.
            let quiet = bars.indices
                .filter { i in i >= 6 && (max(0, i - 6)...i).allSatisfy { bars[$0].level <= 0.03 } }
                .map { bars[$0].height }
            let loud  = bars.filter { $0.level > 0.03 }.map(\.height)
            func avg(_ xs: [CGFloat]) -> CGFloat { xs.isEmpty ? 0 : xs.reduce(0,+) / CGFloat(xs.count) }
            print(String(format: "\nsürekli sessizlik (%d tampon): ort %.2f · en yüksek %.2f",
                         quiet.count, avg(quiet), quiet.max() ?? 0))
            print(String(format: "konuşma   (%d tampon): ort %.2f · en yüksek %.2f",
                         loud.count, avg(loud), loud.max() ?? 0))

            // Menü çubuğu ikonunun gövde dolumu: aynı LevelMeter, uygulamadaki
            // gibi 30 Hz tikle (bir tampon ≈ 85 ms ≈ 3 tik).
            var meter = LevelMeter()
            let fills: [CGFloat] = bars.map { bar in
                for _ in 0..<3 { meter.step(level: bar.level, dt: 0.085 / 3) }
                return meter.punch
            }
            let quietFill = bars.indices
                .filter { i in i >= 6 && (max(0, i - 6)...i).allSatisfy { bars[$0].level <= 0.03 } }
                .map { fills[$0] }
            let loudFill = bars.indices.filter { bars[$0].level > 0.03 }.map { fills[$0] }
            let sortedLoud = loudFill.sorted()
            let p50 = sortedLoud.isEmpty ? 0 : sortedLoud[sortedLoud.count / 2]
            print(String(format: "\nikon dolumu — sessizlik: ort %.2f · konuşma: ort %.2f · p50 %.2f · en yüksek %.2f",
                         avg(quietFill), avg(loudFill), p50, loudFill.max() ?? 0))

            let ok = avg(quiet) < 0.08 && avg(loud) > 0.30 && avg(quietFill) < 0.05
            print(ok ? "\n✔ sessizlik düz, konuşma belirgin" : "\n✗ ayrım yetersiz")
            exit(ok ? 0 : 1)
        }

        // GERÇEK kod yolunda köşeye savurma. --boundsprobe yalnızca yay
        // matematiğini sınıyor; buradaki dizi setDragging → applyHover →
        // setMode → resize etkileşimini de içeriyor.
        if CommandLine.arguments.contains("--cornerprobe") {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            let panel = HUDPanel()
            panel.show()
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 400, y: visible.maxY - 300))
            let startFrame = panel.frame
            print("ekran \(visible)  ·  başlangıç \(startFrame.origin)")

            // Sağ-üst köşeye sert çapraz savuruş (~2800 px/sn).
            let speed: CGFloat = 2000, step = 1.0 / 60.0
            let o = startFrame.origin
            panel.beginDrag(at: NSPoint(x: o.x, y: o.y))
            for i in 1...12 {
                let deadline = Date().addingTimeInterval(step)
                while Date() < deadline { }
                let d = speed * CGFloat(Double(i) * step)
                panel.continueDrag(to: NSPoint(x: o.x + d, y: o.y + d))
            }
            panel.setDragging(false)

            var minX = CGFloat.infinity, maxRight: CGFloat = 0
            var minY = CGFloat.infinity, maxTop: CGFloat = 0
            let t0 = CACurrentMediaTime()
            Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
                let f = panel.frame
                minX = min(minX, f.minX); maxRight = max(maxRight, f.maxX)
                minY = min(minY, f.minY); maxTop = max(maxTop, f.maxY)
                guard CACurrentMediaTime() - t0 > 2.0 else { return }
                timer.invalidate()

                let f2 = panel.frame
                print(String(format: "yol sınırları  x %.0f…%.0f (ekran %.0f…%.0f)",
                             minX, maxRight, visible.minX, visible.maxX))
                print(String(format: "               y %.0f…%.0f (ekran %.0f…%.0f)",
                             minY, maxTop, visible.minY, visible.maxY))
                print(String(format: "son konum      (%.0f, %.0f) boyut %.0f×%.0f",
                             f2.minX, f2.minY, f2.width, f2.height))
                let outside = minX < visible.minX - 1 || maxRight > visible.maxX + 1
                            || minY < visible.minY - 1 || maxTop > visible.maxY + 1
                let landedInside = visible.insetBy(dx: -1, dy: -1).contains(f2)
                print(outside ? "\n✗ YOL ekran dışına taştı" : "\n✔ yol hep ekran içinde")
                print(landedInside ? "✔ ekran içinde durdu" : "✗ EKRAN DIŞINDA DURDU")
                exit(outside || !landedInside ? 1 : 0)
            }
            return
        }

        // Sert fiskede kart ekran dışına çıkıyor mu? Yayın taşması hedefi
        // aşabilir; hedef ekran içinde olsa bile YOL ekran dışına sapabilir.
        if CommandLine.arguments.contains("--boundsprobe") {
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 949)
            let card = NSRect(x: 1150, y: 700, width: 112, height: 26)
            print("ekran \(Int(visible.width))×\(Int(visible.height)) · kart (\(Int(card.minX)),\(Int(card.minY))) sağ-üst köşeye yakın\n")

            for speed in [800, 1500, 3000, 6000] as [CGFloat] {
                let v = NSPoint(x: speed * 0.7, y: speed * 0.7)   // çapraz, köşeye
                let target = HUDPanel.landingOrigin(frame: card, visible: visible, velocity: v)
                var sx = Spring(damping: 0.8, response: 0.4, value: card.minX, target: target.x, velocity: v.x)
                var sy = Spring(damping: 0.8, response: 0.4, value: card.minY, target: target.y, velocity: v.y)

                var worstOut: CGFloat = 0
                var t = 0.0
                while t < 2.0 {
                    sx.step(1/120); sy.step(1/120); t += 1/120
                    let outX = max(visible.minX - sx.value, sx.value + card.width - visible.maxX, 0)
                    let outY = max(visible.minY - sy.value, sy.value + card.height - visible.maxY, 0)
                    worstOut = max(worstOut, max(outX, outY))
                }
                let verdict = worstOut < 1 ? "ekran içinde" :
                              worstOut > card.width ? "TAMAMEN KAYBOLUYOR" : "kısmen taşıyor"
                print(String(format: "  %5.0f px/sn → hedef (%5.0f,%5.0f)  en fazla %6.1f px dışarı  %@",
                             speed, target.x, target.y, worstOut, verdict))
            }
            exit(0)
        }

        // Sürükleme hızı GERÇEKTEN ölçülüyor mu? Şikâyetin ("savurunca
        // akmıyor") en olası sebebi hızın hiç yakalanmaması — o zaman her
        // bırakma "yavaş" sayılır ve fiske diye bir şey olmaz.
        if CommandLine.arguments.contains("--dragprobe") {
            let panel = HUDPanel()
            panel.show()
            // Ekranın SOLUNA al: sağa doğru 400 px sürükleyecek yer olsun,
            // yoksa lastik bant devreye girip ölçümü kendisi bozar.
            let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1512, height: 949)
            panel.setFrameOrigin(NSPoint(x: visible.minX + 40, y: visible.midY))
            let startX = panel.frame.minX, y = panel.frame.minY

            // 1200 px/sn hızla 20 kare sağa sürükle (16.7 ms aralık).
            let speed: CGFloat = 1200, step = 1.0 / 60.0
            panel.beginDrag(at: NSPoint(x: startX, y: y))
            var elapsed = 0.0
            for i in 1...20 {
                elapsed = Double(i) * step
                // Gerçek zaman damgası şart: örnekler CACurrentMediaTime kullanıyor.
                let deadline = Date().addingTimeInterval(step)
                while Date() < deadline { }
                panel.continueDrag(to: NSPoint(x: startX + speed * CGFloat(elapsed), y: y))
            }
            let v = panel.releaseVelocity()
            let measured = hypot(v.x, v.y)
            let error = abs(measured - speed) / speed * 100
            print(String(format: "gerçek hız   %.0f px/sn", speed))
            print(String(format: "ölçülen hız  %.0f px/sn  (sapma %%%.1f)", measured, error))
            print("fiske eşiği  \(Int(HUDPanel.flickVelocity)) px/sn → \(measured > HUDPanel.flickVelocity ? "FİSKE algılandı" : "fiske ALGILANMADI")")
            let ok = error < 10 && measured > HUDPanel.flickVelocity
            print(ok ? "\n✔ hız ölçümü sağlam" : "\n✗ hız ölçümü BOZUK — fırlatma çalışmaz")
            exit(ok ? 0 : 1)
        }

        // Canlı log'da p90 8.88 sn, --selftest'te AYNI kayıt 3.03 sn — 3 kat
        // fark. Şüphe: dikte SÜRERKEN dalga animasyonu 120 Hz'de GPU'da çiziyor,
        // Whisper'ın Metal çevirisi de aynı GPU'yu kullanıyor. Bu sondanın işi
        // bu şüpheyi doğrulamak: AYNI transcribe() çağrısını bir kez hiçbir
        // pencere yokken, bir kez production'daki gibi kart canlı animasyon
        // gösterirken çalıştırıp KIYASLIYOR — tahmin değil, ölçüm.
        if let index = CommandLine.arguments.firstIndex(of: "--gpuprobe") {
            guard let path = CommandLine.arguments.dropFirst(index + 1).first,
                  let samples = try? Self.readAudio(at: path) else {
                print("kullanım: Katip --gpuprobe <kayıt.wav>"); exit(2)
            }
            Task {
                print("• ses: \(String(format: "%.1f", Double(samples.count) / 16000)) sn\n")
                let transcriber = Transcriber()
                try? await transcriber.load()

                func run(_ runs: Int) async -> [Double] {
                    var times: [Double] = []
                    for _ in 0..<runs {
                        let t0 = Date()
                        _ = try? await transcriber.transcribe(samples)
                        times.append(Date().timeIntervalSince(t0))
                    }
                    return times
                }

                print("═══ Pencere YOK (izole, --selftest gibi) ═══")
                let baseline = await run(3)
                for (i, t) in baseline.enumerated() { print(String(format: "  tur %d: %.2f sn", i+1, t)) }

                print("\n═══ Kart CANLI animasyon gösterirken (production .locked hâli) ═══")
                let panel = HUDPanel()
                panel.show()
                // Gerçek akış döngüsü 150 ms'de bir seviye güncelliyor
                // (DictationController.startStreaming) — aynı temposu taklit
                // ediyoruz ki GPU yükü production'la BİREBİR eşleşsin.
                let ticker = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
                    panel.update(state: .locked, level: Float.random(in: 0.15...0.35))
                }
                RunLoop.main.add(ticker, forMode: .common)
                try? await Task.sleep(for: .milliseconds(300))   // animasyon otursun

                let withHUD = await run(3)
                ticker.invalidate()
                for (i, t) in withHUD.enumerated() { print(String(format: "  tur %d: %.2f sn", i+1, t)) }

                let baseAvg = baseline.reduce(0,+) / Double(baseline.count)
                let hudAvg = withHUD.reduce(0,+) / Double(withHUD.count)
                let ratio = hudAvg / baseAvg
                print(String(format: "\nortalama: pencere yok %.2f sn  ·  kart canlıyken %.2f sn  ·  oran %.2fx", baseAvg, hudAvg, ratio))
                print(ratio > 1.5 ? "\n✗ GPU çakışması DOĞRULANDI" : "\n✔ fark önemsiz — sebep başka yerde")
                exit(ratio > 1.5 ? 1 : 0)
            }
            return
        }

        // Takılma teşhisi: uzun bir hareket boyunca kare temposunu ölçer.
        // "Akmıyor" şikâyetinin sebebi kare atlama mı, yoksa kare başına iş
        // süresi mi — gözle ayırt edilemez, sayıyla ayırt edilir.
        if CommandLine.arguments.contains("--jankprobe") {
            let panel = HUDPanel()
            panel.show()
            panel.frameLog = []
            let t0 = CACurrentMediaTime()
            panel.debugFling(to: NSPoint(x: 900, y: 500), velocity: NSPoint(x: 1400, y: 0))

            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                guard CACurrentMediaTime() - t0 > 1.2 else { return }
                timer.invalidate()
                let log = panel.frameLog ?? []
                guard log.count > 4 else { print("✗ hiç kare üretilmedi"); exit(1) }

                let dts = log.map { $0.dt * 1000 }
                let works = log.map { $0.work * 1000 }
                let budget = 1000.0 / 60                       // 16.7 ms
                let dropped = dts.filter { $0 > budget * 1.5 }.count

                func pct(_ xs: [Double], _ p: Double) -> Double {
                    let s = xs.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
                }
                print("kare sayısı \(log.count)")
                print(String(format: "kare aralığı  ort %.1f ms · p50 %.1f · p95 %.1f · en kötü %.1f",
                             dts.reduce(0,+) / Double(dts.count), pct(dts, 0.5), pct(dts, 0.95), dts.max()!))
                print(String(format: "setFrame işi  ort %.2f ms · p95 %.2f · en kötü %.2f",
                             works.reduce(0,+) / Double(works.count), pct(works, 0.95), works.max()!))
                print(String(format: "atlanan kare  %d / %d  (%%%.0f)", dropped, log.count,
                             Double(dropped) / Double(log.count) * 100))
                print(dropped * 10 <= log.count ? "\n✔ tempo düzgün" : "\n✗ TAKILIYOR")
                exit(0)
            }
            return
        }

        // Fiske → iniş noktası. Kartı elle savurmadan kararı doğrulamanın yolu.
        if CommandLine.arguments.contains("--flicktest") {
            let visible = NSRect(x: 0, y: 0, width: 1512, height: 900)
            let card = NSRect(x: 700, y: 400, width: 140, height: 32)
            print("ekran \(Int(visible.width))×\(Int(visible.height)), kart ortada (700, 400)")
            print("yapışma mesafesi \(Int(HUDPanel.snapDistance)) px, kenar boşluğu \(Int(HUDPanel.snapMargin)) px\n")
            let cases: [(String, NSPoint)] = [
                ("dur (hız yok)",            NSPoint(x: 0, y: 0)),
                ("hafif itiş sağa",          NSPoint(x: 150, y: 0)),
                ("fiske sağa",               NSPoint(x: 1200, y: 0)),
                ("sert fiske sağa",          NSPoint(x: 3000, y: 0)),
                ("fiske sola",               NSPoint(x: -1200, y: 0)),
                ("fiske aşağı",              NSPoint(x: 0, y: -1200)),
                ("çapraz fiske sağ-yukarı",  NSPoint(x: 900, y: 900)),
            ]
            for (label, v) in cases {
                let landing = HUDPanel.landingOrigin(frame: card, visible: visible, velocity: v)
                let px = card.minX + Momentum.projection(of: v.x)
                let py = card.minY + Momentum.projection(of: v.y)
                let snapped = abs(landing.x - px) > 1 || abs(landing.y - py) > 1
                print(String(format: "  %-24@ kestirim (%6.0f,%6.0f) → iniş (%6.0f,%6.0f)  %@",
                             label as NSString, px, py, landing.x, landing.y,
                             snapped ? "KENARA YAPIŞTI" : "serbest"))
            }
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

        // Güncelleyiciyi uçtan uca sınar — gerçek GitHub API'si ve gerçek zip,
        // ama kurulum SAHTE bir uygulamanın yerine (gerçek /Applications/Katip.app'e
        // dokunmaz): `Katip --updateprobe <geçici-dizin>`.
        if let index = CommandLine.arguments.firstIndex(of: "--updateprobe") {
            let dir = URL(fileURLWithPath: CommandLine.arguments.dropFirst(index + 1).first ?? NSTemporaryDirectory())
            Task { @MainActor in
                var failed = 0
                func expect(_ ok: Bool, _ label: String) { print((ok ? "✔ " : "✗ ") + label); if !ok { failed += 1 } }

                print("═══ sürüm karşılaştırma ═══")
                expect(Updater.isNewer("0.2.10", than: "0.2.9"), "0.2.10 > 0.2.9 (dize sırası değil)")
                expect(!Updater.isNewer("0.2.20", than: "0.2.20"), "aynı sürüm güncelleme sayılmaz")
                expect(!Updater.isNewer("0.2.19", than: "0.2.20"), "eski sürüm güncelleme sayılmaz")
                expect(Updater.isNewer("0.3", than: "0.2.99"), "0.3 > 0.2.99")

                print("\n═══ GitHub API ═══")
                guard let release = try? await Updater.fetchLatest() else {
                    print("✗ en son sürüm okunamadı"); exit(1)
                }
                print("en son: \(release.version) · \(release.size) bayt · \(release.zipURL.lastPathComponent)")

                func fakeApp(version: String) throws -> URL {
                    let app = dir.appendingPathComponent("Sahte-\(UUID().uuidString.prefix(6)).app")
                    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                            withIntermediateDirectories: true)
                    let plist: NSDictionary = ["CFBundleIdentifier": "dev.mvrl.katip", "CFBundleShortVersionString": version]
                    plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
                    return app
                }
                func version(of app: URL) -> String? {
                    NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
                }

                print("\n═══ indir + doğrula + kur (sahte hedef) ═══")
                do {
                    let zip = try await Updater.download(release.zipURL) { _ in }
                    let target = try fakeApp(version: "0.0.1")
                    try Updater.install(zip: zip, expectedVersion: release.version, bundleID: "dev.mvrl.katip", replacing: target)
                    expect(version(of: target) == release.version, "hedef \(release.version) oldu")
                    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                        .filter { $0.hasPrefix(".Katip-eski") } ?? []
                    expect(leftovers.isEmpty, "yedek kopya temizlendi")
                } catch { expect(false, "kurulum: \(Updater.describe(error))") }

                print("\n═══ reddetme: yanlış sürüm / yanlış kimlik → hedefe dokunulmamalı ═══")
                for (label, expectedVersion, bundleID) in [("yanlış sürüm", "9.9.9", "dev.mvrl.katip"),
                                                            ("yanlış kimlik", release.version, "com.baska.uygulama")] {
                    do {
                        let zip = try await Updater.download(release.zipURL) { _ in }
                        let target = try fakeApp(version: "0.0.1")
                        do {
                            try Updater.install(zip: zip, expectedVersion: expectedVersion, bundleID: bundleID, replacing: target)
                            expect(false, "\(label): KABUL EDİLDİ")
                        } catch {
                            expect(version(of: target) == "0.0.1", "\(label) reddedildi, hedef sağlam — \(Updater.describe(error))")
                        }
                    } catch { expect(false, "\(label): indirme \(error)") }
                }

                print(failed == 0 ? "\n✔ güncelleyici sağlam" : "\n✗ \(failed) kontrol başarısız")
                exit(failed == 0 ? 0 : 1)
            }
            return
        }

        // Menü çubuğu menüsünü ve ikonlarını ekransız PNG'ye çizer — tasarımla
        // karşılaştırmak için (`Katip --rendermenu <dizin>`).
        if CommandLine.arguments.contains("--rendermenu") {
            let dir = CommandLine.arguments.last ?? "/tmp"
            let base = statusMenuElements()
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
            func with(_ status: StatusMenu.Status, _ hint: StatusMenu.Hint,
                      progress: Double? = nil) -> [StatusMenu.Element] {
                var elements = base
                elements[0] = .header(.init(version: version, status: status, hint: hint, progress: progress))
                return elements
            }
            StatusMenu.renderSample(with(.ready, .idle("⌥")), to: dir + "/menu-ready.png")
            StatusMenu.renderSample(with(.ready, .idle("⌥")), expanded: "edit", to: dir + "/menu-edit.png")
            StatusMenu.renderSample(with(.ready, .idle("⌥")), expanded: "lang", to: dir + "/menu-lang.png")
            StatusMenu.renderSample(with(.ready, .idle("⌥")), expanded: "perms", to: dir + "/menu-perms.png")
            StatusMenu.renderSample(with(.recording, .recording("⌥")), level: 0.12, to: dir + "/menu-recording.png")
            StatusMenu.renderSample(with(.transcribing, .none), to: dir + "/menu-transcribing.png")
            StatusMenu.renderSample(with(.downloading(0.42), .text("İlk açılışta bir kez · ~1.6 GB"), progress: 0.42),
                                    to: dir + "/menu-download.png")
            let sampleRelease = Updater.Release(
                version: "0.2.21", zipURL: URL(string: "https://example.invalid/Katip.zip")!,
                pageURL: URL(string: "https://github.com/mehmetvarol/katip/releases")!, size: 2_652_678)
            for (name, state) in [("idle", Updater.State.idle), ("checking", .checking), ("uptodate", .upToDate("0.2.20")),
                                  ("available", .available(sampleRelease)), ("downloading", .downloading(0.42)),
                                  ("failed", .failed("İnternet bağlantısı yok"))] {
                updater.preview(state)
                var elements = statusMenuElements()
                elements[0] = .header(.init(version: version, status: .ready, hint: .idle("⌥")))
                StatusMenu.renderSample(elements, to: dir + "/menu-update-\(name).png")
            }
            updater.preview(.idle)
            // İkonlar 8x büyütülmüş; template olanlar açık zeminde (sistem onları siyaha boyar).
            func saveIcon(_ image: NSImage, _ name: String, dark: Bool) {
                let px = 18 * 8
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.92, alpha: 1)).setFill()
                NSRect(x: 0, y: 0, width: px, height: px).fill()
                image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name))
            }
            saveIcon(StatusIcon.recording(level: 0.2, color: .systemRed), "icon-rec-low.png", dark: true)
            saveIcon(StatusIcon.recording(level: 0.8, color: .systemRed), "icon-rec-high.png", dark: true)
            saveIcon(StatusIcon.recording(level: 0.5, color: .systemOrange), "icon-locked.png", dark: true)
            saveIcon(StatusIcon.transcribing(time: 0.1), "icon-trans-a.png", dark: false)
            saveIcon(StatusIcon.transcribing(time: 0.4), "icon-trans-b.png", dark: false)
            saveIcon(StatusIcon.downloading(progress: 0.42), "icon-download.png", dark: false)
            print("render edildi: \(dir)")
            exit(0)
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
            // Çeviri sırasında dönen gösterge — dört kare, döndüğünü kanıtla.
            for (index, ticks) in [4, 10, 16, 22].enumerated() {
                HUDPanel.renderSample(mode: .transcribing, levels: flat,
                                      to: dir + "/card-transcribing-\(index).png", ticks: ticks)
            }
            // NOT: buradaki "seviye" render'ları KALDIRILDI. Kazanç artık
            // uyarlanır olduğu için sabit bir seviyeyi beslemek anlamsız —
            // referans o seviyeye yakınsıyor ve her seviye aynı görünüyor.
            // Yerini `--waveprobe <kayıt.wav>` aldı: gerçek bir kaydı zaman
            // içinde geçirip sessizlik/konuşma ayrımını sayıyla veriyor.
            HUDPanel.renderSample(mode: .notice("Mikrofon izni yok"), levels: flat,
                                  to: dir + "/card-notice.png")
            HUDPanel.renderSample(mode: .result("Şu component'i refactor edelim, state yönetimi Zustand'a geçsin."),
                                  levels: flat, to: dir + "/card-result.png")
            LanguageMenu.renderSample(to: dir + "/language-menu.png")
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

        updater.onChange = { [weak self] in self?.statusMenu?.reload() }
        updater.onInstalled = { [weak self] in self?.relaunchApp() }

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
        checkInstallLocation()

        hotkey.onNeedsPermission = { [weak self] in self?.promptForInputMonitoring() }
        hotkey.onPress = { [weak self] in self?.controller.hotkeyPressed() }
        hotkey.onRelease = { [weak self] in self?.controller.hotkeyReleased() }
        hotkey.start()

        // Geçmiş penceresi modeli tanımıyor; yeniden çeviri bağlantısını
        // burada kuruyoruz.
        HistoryWindowController.shared.retranscribe = { [weak self] entry in
            guard let self else { return .failure(DictationController.RetranscribeError.busy) }
            return await self.controller.retranscribe(entry)
        }

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
            // Native menü gibi: menü açıkken ikona tıklamak önce onu kapatır.
            statusMenu?.dismiss()
            controller.toggle()
        }
    }

    // MARK: - Menü çubuğu menüsü

    /// Native NSMenu yerine kendi koyu panelimiz (bkz. StatusMenu.swift).
    private var statusMenu: StatusMenu?

    private func showMenu() {
        if let menu = statusMenu { menu.dismiss(); return }
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))

        let menu = StatusMenu(builder: { [weak self] in self?.statusMenuElements() ?? [] },
                              level: { [weak self] in CGFloat(self?.controller.inputLevel ?? 0) })
        menu.anchorWindow = window
        menu.onClose = { [weak self] in
            self?.statusItem.button?.highlight(false)
            self?.statusMenu = nil
        }
        button.highlight(true)
        statusMenu = menu
        menu.show(below: anchor)
    }

    private func statusMenuElements() -> [StatusMenu.Element] {
        typealias Row = StatusMenu.Row
        let state = controller.state
        let permissions = permissionRows()
        var items: [StatusMenu.Element] = [.header(menuHeader(for: state, missing: permissions.missing))]

        if installLocationWarning != nil {
            items += [.separator, .row(Row(
                id: "install", symbol: "exclamationmark.triangle", title: "Uygulamalar'a taşı",
                caption: "Yoksa izinler her açılışta sıfırlanır", accessory: .link("Göster"),
                tone: .warning, action: { [weak self] in self?.revealForInstallFix() }))]
        }

        // İzin sorunu varsa en üste çıkıyor — asıl yapılması gereken iş o.
        if permissions.missing > 0 {
            items += [.separator, .section("İzinler")] + permissions.rows.map { .row($0) } + [.row(restartRow())]
        }

        items.append(.separator)
        if !controller.lastTranscript.isEmpty {
            let preview = controller.lastTranscript.replacingOccurrences(of: "\n", with: " ")
            items.append(.row(Row(id: "last", symbol: "text.alignleft", title: preview,
                                  accessory: .hoverSymbol("doc.on.doc"), tone: .soft,
                                  action: { [weak self] in self?.copyLast() })))
        }
        items.append(.row(Row(id: "history", symbol: "clock", title: "Geçmiş", accessory: .shortcut("⌘H"),
                              action: { [weak self] in self?.showHistory() })))

        // Dikte
        items += [.separator, .section("Dikte"),
                  .row(Row(id: "lang", symbol: "globe", title: "Dil",
                           accessory: .disclosure(languageValue()), expands: "lang")),
                  .group("lang", languageRows()),
                  .row(Row(id: "hotkey", symbol: "option", title: "Kısayol",
                           accessory: .disclosure(Self.hotkeyValue(HotkeyChoice.current)), expands: "hotkey")),
                  .group("hotkey", hotkeyRows()),
                  .row(Row(id: "glossary", symbol: "book", title: "Sözlük yönlendirmesi",
                           caption: "Terimler daha doğru, ~0.8 sn yavaşlatır",
                           accessory: .toggle(Transcriber.glossaryEnabled), closes: false,
                           action: { [weak self] in self?.toggleGlossary() })),
                  .row(Row(id: "edit", symbol: "pencil", title: "Düzenle", accessory: .disclosure("5 dosya"),
                           expands: "edit")),
                  .group("edit", [
                    Row(id: "e-glossary", symbol: "book", title: "Sözlük",
                        action: { [weak self] in self?.openGlossary() }),
                    Row(id: "e-replace", symbol: "arrow.left.arrow.right", title: "Düzeltme tablosu",
                        action: { [weak self] in self?.openReplacements() }),
                    Row(id: "e-apps", symbol: "square.grid.2x2", title: "Uygulama kuralları",
                        action: { [weak self] in self?.openAppProfiles() }),
                    Row(id: "e-snippets", symbol: "chevron.left.forwardslash.chevron.right", title: "Metin kısayolları",
                        action: { [weak self] in self?.openSnippets() }),
                    Row(id: "e-learn", symbol: "folder", title: "Projelerimden terim öğren",
                        action: { [weak self] in self?.learnFromProjects() }),
                  ])]

        // Görünüm
        items += [.separator, .section("Görünüm"),
                  .row(Row(id: "card", symbol: "capsule", title: "Yüzen kart",
                           accessory: .toggle(HUDPanel.isEnabled), closes: false,
                           action: { [weak self] in self?.toggleHUD() })),
                  // Kapalı biçim bilerek neredeyse görünmez; kaybolduğunda geri çağıracak bir yol.
                  .row(Row(id: "recenter", symbol: "scope", title: "Kartı ortala",
                           tone: HUDPanel.isEnabled ? .normal : .dim,
                           action: HUDPanel.isEnabled ? { [weak self] in self?.recenterHUD() } : nil)),
                  .row(Row(id: "login", symbol: "power", title: "Girişte başlat",
                           caption: LoginItem.needsApproval ? "Ayarlar'dan onay bekliyor" : nil,
                           accessory: .toggle(LoginItem.isEnabled), closes: false,
                           action: { [weak self] in self?.toggleLoginItem() }))]

        // Her şey yolundaysa izinler tek satır; açınca ayrıntı + yeniden başlat.
        if permissions.missing == 0 {
            items += [.separator,
                      .row(Row(id: "perms", symbol: "checkmark.shield", title: "İzinler",
                               accessory: .badges(["mic", "accessibility", "keyboard"]), expands: "perms")),
                      .group("perms", permissions.rows + [restartRow()])]
        }

        items += [.separator] + updateRows().map { .row($0) }
        items += [.separator, .row(Row(id: "quit", symbol: "rectangle.portrait.and.arrow.right", title: "Çık",
                                       accessory: .shortcut("⌘Q"), action: { NSApp.terminate(nil) }))]
        return items
    }

    /// "Güncellemeleri denetle" — yalnızca tıklayınca ağa çıkar (bkz. Updater).
    private func updateRows() -> [StatusMenu.Row] {
        typealias Row = StatusMenu.Row
        let check: () -> Void = { [weak self] in Task { await self?.updater.check() } }
        switch updater.state {
        case .idle:
            return [Row(id: "update", symbol: "arrow.triangle.2.circlepath", title: "Güncellemeleri denetle",
                        caption: "Şu an \(Updater.currentVersion)", closes: false, action: check)]
        case .checking:
            return [Row(id: "update", symbol: "arrow.triangle.2.circlepath", title: "Denetleniyor…",
                        accessory: .spinner)]
        case .upToDate(let latest):
            return [Row(id: "update", symbol: "checkmark.circle", title: "Katip güncel",
                        caption: "\(latest) en son sürüm", accessory: .pill("Güncel", .systemGreen),
                        closes: false, action: check)]
        case .available(let release):
            let megabytes = String(format: "%.1f MB", Double(release.size) / 1_048_576)
            return [
                Row(id: "update", symbol: "arrow.down.circle", title: "\(release.version) sürümüne güncelle",
                    caption: "\(megabytes) · kurar ve yeniden başlatır", tone: .primary, closes: false,
                    action: { [weak self] in Task { await self?.updater.downloadAndInstall(release) } }),
                Row(id: "update-notes", symbol: "doc.text", title: "Neler yeni?", accessory: .link("GitHub"),
                    action: { NSWorkspace.shared.open(release.pageURL) }),
            ]
        case .downloading(let fraction):
            return [Row(id: "update", symbol: "arrow.down.circle", title: "İndiriliyor…",
                        accessory: .progress(fraction))]
        case .installing:
            return [Row(id: "update", symbol: "arrow.down.circle", title: "Kuruluyor…",
                        caption: "Katip birazdan yeniden açılacak", accessory: .spinner)]
        case .failed(let message):
            // Oksuz: ↗ dışarı bağlantı gibi duruyordu, oysa satır sadece yeniden denetliyor.
            return [Row(id: "update", symbol: "exclamationmark.triangle", title: "Güncelleme başarısız — tekrar dene",
                        caption: message, tone: .warning, closes: false, action: check)]
        }
    }

    private func menuHeader(for state: DictationController.State, missing: Int) -> StatusMenu.Header {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let glyph = HotkeyChoice.current.glyph
        switch state {
        case .idle:
            return .init(version: version, status: missing > 0 ? .permissions(missing) : .ready,
                         hint: glyph.isEmpty ? .text("Kısayol kapalı — dikte için ikona tıkla") : .idle(glyph))
        case .recording:
            return .init(version: version, status: .recording,
                         hint: glyph.isEmpty ? .text("Bitirmek için ikona tıkla") : .recording(glyph))
        case .locked:
            return .init(version: version, status: .locked, hint: glyph.isEmpty ? .none : .locked(glyph))
        case .transcribing:
            return .init(version: version, status: .transcribing, hint: .none)
        case .loadingModel(let progress):
            if let progress, progress > 0, progress < 1 {
                return .init(version: version, status: .downloading(progress),
                             hint: .text("İlk açılışta bir kez · ~1.6 GB"), progress: progress)
            }
            return .init(version: version, status: .loading, hint: .none)
        case .error(let message):
            return .init(version: version, status: .error, hint: .text(message))
        }
    }

    /// Üç izin satırı + kaç tanesinin eksik olduğu. "Reddedilmiş" ile "henüz
    /// sorulmadı" ayrı gösteriliyor: reddedilmişse sistem bir daha sormaz,
    /// tek yol Ayarlar (bkz. Permissions.isInputMonitoringDenied).
    private func permissionRows() -> (rows: [StatusMenu.Row], missing: Int) {
        typealias Row = StatusMenu.Row
        var rows: [Row] = []
        var missing = 0

        if Permissions.hasMicrophone {
            rows.append(Row(id: "p-mic", symbol: "mic", title: "Mikrofon", accessory: .pill("Var", .systemGreen)))
        } else {
            missing += 1
            let denied = Permissions.isMicrophoneDenied
            rows.append(Row(id: "p-mic", symbol: denied ? "nosign" : "mic",
                            title: denied ? "Mikrofon reddedildi" : "Mikrofon",
                            caption: denied ? "Sistem bir daha sormaz — Ayarlar'dan aç" : "Sesini duymak için",
                            accessory: .link(denied ? "Ayarlar" : "İzin ver"), tone: denied ? .danger : .warning,
                            action: { Permissions.openSettings(.microphone) }))
        }

        if Permissions.hasAccessibility {
            rows.append(Row(id: "p-ax", symbol: "accessibility", title: "Erişilebilirlik",
                            accessory: .pill("Var", .systemGreen)))
        } else {
            missing += 1
            rows.append(Row(id: "p-ax", symbol: "accessibility", title: "Erişilebilirlik",
                            caption: "Metni imlece yazmak için", accessory: .link("İzin ver"), tone: .warning,
                            action: { [weak self] in self?.fixAccessibility() }))
        }

        if Permissions.hasInputMonitoring {
            rows.append(Row(id: "p-input", symbol: "keyboard", title: "Giriş İzleme",
                            accessory: .pill("Var", .systemGreen)))
        } else {
            missing += 1
            let denied = Permissions.isInputMonitoringDenied
            rows.append(Row(id: "p-input", symbol: denied ? "nosign" : "keyboard",
                            title: denied ? "Giriş İzleme reddedildi" : "Giriş İzleme",
                            caption: denied ? "Sistem bir daha sormaz — Ayarlar'dan aç" : "Kısayol tuşu için",
                            accessory: .link(denied ? "Ayarlar" : "İzin ver"), tone: denied ? .danger : .warning,
                            action: { [weak self] in self?.fixInputMonitoring() }))
        }
        return (rows, missing)
    }

    private func restartRow() -> StatusMenu.Row {
        // İzin verildikten sonra süreç yeniden başlamadan geçerli olmayabilir
        // (Erişilebilirlik durumu süreç başına önbelleklenir).
        StatusMenu.Row(id: "restart", symbol: "arrow.clockwise", title: "Katip'i yeniden başlat",
                       caption: "İzin verdikten sonra gerekir", tone: .primary,
                       action: { [weak self] in self?.relaunchApp() })
    }

    private func languageValue() -> String {
        if controller.isAutoLanguage { return "Otomatik" }
        let picked = DictationController.LanguageChoice.allCases.filter { controller.isLanguageSelected($0) }
        switch picked.count {
        case 0: return "Otomatik"
        case 1: return picked[0].title
        case 2: return picked.map(\.title).joined(separator: ", ")
        default: return "\(picked.count) dil"
        }
    }

    /// Menüyü kapatmıyor — checklist gibi, istediğin kadar dil işaretle.
    private func languageRows() -> [StatusMenu.Row] {
        var rows = [StatusMenu.Row(id: "l-auto", symbol: nil, title: "Otomatik algıla",
                                   accessory: .check(controller.isAutoLanguage), closes: false,
                                   action: { [weak self] in self?.controller.setAutoLanguage() })]
        for choice in DictationController.LanguageChoice.allCases {
            rows.append(StatusMenu.Row(id: "l-" + choice.rawValue, symbol: nil, title: choice.title,
                                       accessory: .check(controller.isLanguageSelected(choice)), closes: false,
                                       action: { [weak self] in self?.controller.toggleLanguage(choice) }))
        }
        return rows
    }

    private func hotkeyRows() -> [StatusMenu.Row] {
        HotkeyChoice.allCases.map { choice in
            StatusMenu.Row(id: "k-" + choice.rawValue, symbol: nil, title: Self.hotkeyValue(choice),
                           accessory: .check(choice == HotkeyChoice.current), closes: false,
                           action: { [weak self] in self?.pickHotkey(choice) })
        }
    }

    /// "Sağ Option (⌥)" → "Sağ Option ⌥" — tasarımdaki yazım.
    private static func hotkeyValue(_ choice: HotkeyChoice) -> String {
        choice.title.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
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
        case .language: showLanguageMenu()
        case .copyText:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(controller.lastTranscript, forType: .string)
            hud?.dismissOverlay()
        case .dismiss:  hud?.dismissOverlay()
        }
    }

    /// Küre düğmesi: sabit sıradan geçmek yerine işaretlenebilir bir liste
    /// açılıyor. Türkçe+İngilizce gibi karışık cümleler zaten TEK dilde
    /// (varsayılan "tr") doğru çıkıyor — birden fazla dil işaretlemek yalnızca
    /// hangi dilde konuşacağın BELİRSİZSE anlamlı, çünkü her ek dil ayrı bir
    /// tam çeviri geçişi demek (bkz. Transcriber.transcribe).
    ///
    /// Native `NSMenu` DEĞİL — `LanguageMenu` kartla aynı koyu yüzeyi
    /// paylaşıyor (bkz. Palette.swift) ve her tıklamada kapanmıyor, çoklu
    /// seçimde menüyü tekrar tekrar açmana gerek kalmıyor.
    private var languageMenu: LanguageMenu?

    private func showLanguageMenu() {
        let menu = LanguageMenu(rows: languageMenuRows())
        menu.onSelect = { [weak self] index in self?.handleLanguageMenuSelection(index) }
        menu.show(near: NSEvent.mouseLocation)
        languageMenu = menu
    }

    private func languageMenuRows() -> [LanguageMenu.Row] {
        var rows = [LanguageMenu.Row(title: "Otomatik algıla", isChecked: controller.isAutoLanguage,
                                     isSeparatorAfter: true)]
        for choice in DictationController.LanguageChoice.allCases {
            rows.append(LanguageMenu.Row(title: choice.title, isChecked: controller.isLanguageSelected(choice)))
        }
        return rows
    }

    private func handleLanguageMenuSelection(_ index: Int) {
        if index == 0 {
            controller.setAutoLanguage()
        } else {
            let choice = DictationController.LanguageChoice.allCases[index - 1]
            controller.toggleLanguage(choice)
        }
        // Panel AÇIK kalıyor — checklist gibi, kullanıcı istediği kadar dil
        // işaretleyebilsin. Sadece onay işaretlerini güncelliyoruz.
        languageMenu?.update(rows: languageMenuRows())
    }

    private func hideHUD() {
        hud?.orderOut(nil)
        hud = nil
    }

    private func pickHotkey(_ choice: HotkeyChoice) {
        HotkeyChoice.current = choice
        hotkey.start()   // yeni tuşla yeniden bağlan
        Trace.log("kısayol değiştirildi: \(choice.title)")
    }

    /// Canlı: açık Transcriber'a hemen iletiliyor, yeniden başlatma gerekmiyor
    /// (menüdeki bir anahtar "yeniden başlat" isteseydi bozuk hissettirirdi).
    @objc private func toggleGlossary() {
        Transcriber.glossaryEnabled.toggle()
        controller.setGlossaryEnabled(Transcriber.glossaryEnabled)
        Trace.log("sözlük yönlendirmesi: \(Transcriber.glossaryEnabled ? "açık" : "kapalı")")
    }

    @objc private func openGlossary() {
        _ = Glossary.load()
        NSWorkspace.shared.open(Glossary.fileURL)
    }

    @objc private func openReplacements() {
        _ = Replacements.load()
        NSWorkspace.shared.open(Replacements.fileURL)
    }

    @objc private func openAppProfiles() {
        AppProfiles.ensureFileExists()
        NSWorkspace.shared.open(AppProfiles.fileURL)
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
        if Permissions.isInputMonitoringDenied {
            // requestInputMonitoring() reddedilmiş durumda hiçbir şey yapmaz
            // (sistem istemi bir daha çıkmaz) — direkt Ayarlar'a yönlendir.
            Permissions.openSettings(.inputMonitoring)
            flash("Reddedilmiş — listede Katip'i kapat/aç, sonra menüden yeniden başlat")
            return
        }
        promptForInputMonitoring()
    }

    /// "İzin verdim ama HER AÇILIŞTA yine soruyor" şikâyetinin gerçek dünyada
    /// bildirilen sebebi: uygulama Uygulamalar klasörüne taşınmadan (zip'ten
    /// çıkarıldığı yerden — Masaüstü/İndirilenler) çalıştırılıyorsa Gatekeeper
    /// onu "App Translocation" ile her seferinde farklı, gizli/geçici bir
    /// yoldan başlatır. TCC izinleri konuma bağlı olduğu için, yol her açılışta
    /// değişince izin de hiç kalıcı olmuyor — Ayarlar'da "açık" görünse bile.
    /// Bu, tek seferlik "izin verildi ama görünmüyor" (relaunch ile çözülen,
    /// bkz. `relaunchApp()`) durumundan FARKLI bir hata sınıfı: relaunch bunu
    /// çözmez, çünkü sorun süreç önbelleği değil, konumun kendisi.
    private func checkInstallLocation() {
        let path = Bundle.main.bundlePath
        let translocated = path.contains("AppTranslocation")
        let wrongPlace = !path.hasPrefix("/Applications/")
        guard translocated || wrongPlace else { return }

        let reason = translocated
            ? "Gatekeeper onu geçici/gizli bir konumdan çalıştırıyor"
            : "Uygulamalar klasöründe değil"
        Trace.log("KURULUM SORUNU — \(reason): \(path)")

        // Uzaktaki kullanıcı Finder'da sürüklemeyi bilmiyor/yapmıyor olabilir —
        // önce KENDİMİZ taşımayı dene, kullanıcıdan hiçbir şey istemeden.
        // KATIP_NO_AUTORELOCATE: geliştirme sırasında scratch dizinlerden test
        // ederken gerçek /Applications/Katip.app'in üstüne yazılmasını engeller.
        if ProcessInfo.processInfo.environment["KATIP_NO_AUTORELOCATE"] == nil,
           attemptAutoRelocate() {
            return   // yeni süreç açılıyor, bu süreç birazdan kendini kapatacak
        }

        let message = "⚠️ Katip'i Uygulamalar'a taşı — yoksa izinler her açılışta sıfırlanır"
        installLocationWarning = message
        if let hud, HUDPanel.isEnabled {
            hud.present(notice: message)   // flash() değil — kalıcı, kendiliğinden kapanmaz
        }
    }

    /// Kendini `/Applications/Katip.app`'e kopyalayıp oradan yeniden başlatır.
    /// Başarısızsa (yazma izni yok, disk dolu vb.) `false` döner — çağıran
    /// yerine manuel uyarıya düşer. Translocated bir yoldan OKUMAK sorunsuz
    /// çalışır (translocation sadece taşımayı/yeniden adlandırmayı kısıtlıyor,
    /// okumayı değil), bu yüzden kopyalama translocated durumda da işe yarar.
    private func attemptAutoRelocate() -> Bool {
        let dest = "/Applications/Katip.app"
        let source = Bundle.main.bundlePath
        guard source != dest else { return false }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: dest) { try fm.removeItem(atPath: dest) }
            try fm.copyItem(atPath: source, toPath: dest)
        } catch {
            Trace.log("otomatik taşıma başarısız: \(error.localizedDescription)")
            return false
        }
        Trace.log("otomatik taşındı → \(dest), yeniden başlatılıyor")
        let safeDest = dest.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; open '\(safeDest)'"]
        try? task.run()
        NSApp.terminate(nil)
        return true
    }

    /// Translocation'da bile Finder'da göstermek işe yarar: kullanıcı oradan
    /// Uygulamalar'a sürükleyince macOS gerçek dosyayı doğru taşıyor.
    @objc private func revealForInstallFix() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Bundle.main.bundlePath)])
    }

    @objc private func fixAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openSettings(.accessibility)
        flash("İzni verdikten sonra menüden \"Katip'i yeniden başlat\"ı seç")
    }

    /// Erişilebilirlik durumu SÜREÇ BAŞINA önbelleklenir — Ayarlar'da "açık"
    /// görünse bile ÇALIŞAN sürece hiç yansımayabilir, sadece yeniden başlatma
    /// bunu düzeltiyor. Bu, uzaktaki bir kullanıcıda "izin verdim ama hâlâ
    /// çalışmıyor" şikâyetiyle gerçek dünyada doğrulandı (2026-08-26) — kullanıcı
    /// Terminal'e "tccutil reset" yazmayı bilmiyor, ama menüden tek tıkla
    /// yeniden başlatabilir.
    @objc private func relaunchApp() {
        Trace.log("kullanıcı yeniden başlatmayı seçti")
        // `open <path>` HÂLÂ ÇALIŞAN bir uygulamayı yeni bir süreç olarak
        // BAŞLATMAZ, sadece öne getirir — bu yüzden doğrudan `open` çağırıp
        // hemen terminate etmek YENİDEN BAŞLATMAZ, sadece kapatır (ölçüldü:
        // manuel simülasyonda ikinci pid hiç oluşmadı). Ayrı bir kabuk süreci
        // önce Katip'in ölmesini bekleyip SONRA `open` çağırıyor.
        let path = Bundle.main.bundlePath
        let safePath = path.replacingOccurrences(of: "'", with: "'\\''")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; open '\(safePath)'"]
        try? task.run()
        NSApp.terminate(nil)
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
                segments.append((consumed, consumed + length, cut.silenceBefore))
                consumed += length
                buffer.removeFirst(cut.index)
            }
            index = end
        }

        print("\n\(segments.count) parça:")
        for (number, span) in segments.enumerated() {
            // Süre artık dikiş kararını VERMİYOR (ölçüldü, ayıramıyor —
            // bkz. Stitcher). Yine de yazdırıyoruz: VAD'in nerede kestiğini
            // ve duraklama dağılımını görmenin tek yolu bu.
            print(String(format: "  %2d) %5.1f–%5.1f sn  (%.1f sn)  öncesinde %.1f sn duraklama",
                         number + 1, span.0, span.1, span.1 - span.0, span.2))
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

    private func runRecordingProbe() {
        // Gerçek kayıt klasörüne DOKUNMA. Sonda budamayı da sınıyor; gerçek
        // klasörde çalışsaydı kullanıcının kayıtlarını siler.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("katip-recordingprobe-\(UUID().uuidString)")
        Recordings.overrideDirectory = sandbox
        print("sonda klasörü: \(sandbox.lastPathComponent)")

        // `defer` İŞE YARAMAZ: exit() onu atlar. Çıkış tek kapıdan geçmeli.
        func finish(_ code: Int32, _ message: String) -> Never {
            print(message)
            try? FileManager.default.removeItem(at: sandbox)
            exit(code)
        }

        // 3 sn, 440 Hz sinüs — deterministik, kulakla değil sayıyla doğrulanır.
        let count = 48_000
        var original = [Float](repeating: 0, count: count)
        for index in 0..<count {
            original[index] = 0.5 * sinf(2 * .pi * 440 * Float(index) / 16_000)
        }

        let id = UUID()
        guard let name = Recordings.save(original, id: id) else { finish(1, "✗ kayıt yazılamadı") }
        let url = Recordings.directory.appendingPathComponent(name)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        print("yazıldı: \(name) — \(bytes) bayt (\(String(format: "%.1f", Double(bytes) / Double(count))) bayt/örnek)")

        guard let loaded = try? Recordings.load(name) else { finish(1, "✗ okunamadı") }
        print("okundu : \(loaded.count) örnek (beklenen \(count))")
        guard loaded.count == count else { finish(1, "✗ örnek sayısı tutmuyor") }

        // 16-bit'e yuvarlama kaybı var; sıfır değil, KÜÇÜK olmalı.
        var worst: Float = 0
        for index in 0..<count { worst = max(worst, abs(loaded[index] - original[index])) }
        let limit: Float = 1.0 / 32_767 * 2
        print("en büyük sapma: \(String(format: "%.6f", worst)) (sınır \(String(format: "%.6f", limit)))")
        guard worst <= limit else { finish(1, "✗ sapma çok büyük") }
        print("✔ kaydet/oku turu sağlam")

        try? FileManager.default.removeItem(at: url)

        // Budama: sınırın üstüne çık, sınırda kalması gerekiyor. Bu sessizce
        // bozulursa ses klasörü sınırsız büyür — disk ve gizlilik sorunu.
        let short = [Float](repeating: 0.1, count: 1600)   // 0,1 sn
        for _ in 0..<(Recordings.limit + 5) { _ = Recordings.save(short, id: UUID()) }
        let after = (try? FileManager.default.contentsOfDirectory(
            at: Recordings.directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "wav" }.count ?? 0
        print("budama: \(Recordings.limit + 5) kayda çıkıldı → \(after) kaldı (sınır \(Recordings.limit))")
        finish(after <= Recordings.limit ? 0 : 1,
               after <= Recordings.limit ? "✔ budama sınırda tutuyor" : "✗ budama tutmadı")
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
                    let selection: Transcriber.LanguageSelection = lang == "auto"
                        ? .auto : .fixed(lang.split(separator: ",").map(String.init))
                    await transcriber.setLanguages(selection)
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
        button.toolTip = installLocationWarning ?? "Katip — \(state.label)"

        // Menü çubuğu ikonu: her durum kendi hareketiyle (bkz. StatusIcon.swift).
        button.contentTintColor = nil
        switch state {
        case .recording, .locked:
            lastIconTick = CACurrentMediaTime()
            startAnimation()   // tick() gövdeyi gerçek ses seviyesiyle dolduruyor
            button.image = StatusIcon.recording(level: 0, color: state == .locked ? .systemOrange : .systemRed)
        case .transcribing:
            startAnimation()   // tick() çubukları akıtıyor
            button.image = StatusIcon.transcribing(time: CACurrentMediaTime())
        case .loadingModel(let progress?) where progress > 0 && progress < 1:
            button.image = StatusIcon.downloading(progress: progress)
        default:
            // Kart açıkken animasyon döngüsü sürsün: dalgalar yumuşakça sönümlensin
            // ve durum metni canlı kalsın.
            if hud == nil { stopAnimation() }
            button.image = icon(for: state)
            button.image?.isTemplate = true
        }
        statusMenu?.reload()

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
        iconMeter.reset()
    }

    /// Hem yüzen kartın dalgasını hem menü çubuğu ikonunun karelerini besler.
    private func tick() {
        hud?.update(state: controller.state, level: controller.inputLevel)

        switch controller.state {
        case .recording, .locked:
            // Uyarlanır: normal konuşma gövdeyi neredeyse doldurur, sessizlikte
            // boş kalır (bkz. LevelMeter). Eskiden sabit ×6 kazançtı — sessiz
            // odada da kısık konuşmada da gövde neredeyse boş görünüyordu.
            let now = CACurrentMediaTime()
            iconMeter.step(level: CGFloat(controller.inputLevel), dt: CGFloat(min(0.1, now - lastIconTick)))
            lastIconTick = now
            statusItem.button?.image = StatusIcon.recording(
                level: iconMeter.punch, color: controller.state == .locked ? .systemOrange : .systemRed)
        case .transcribing:
            statusItem.button?.image = StatusIcon.transcribing(time: CACurrentMediaTime())
        default:
            // Boşta kart sönümlenince döngüyü kes: menü çubuğu yardımcısı gün boyu
            // açık duruyor, sürekli çizim pil yakar (%9 CPU ölçüldü).
            if hud?.isSettled ?? true { stopAnimation() }
        }
    }

    private func icon(for state: DictationController.State) -> NSImage? {
        let image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: "Katip")
        return image
    }
}
