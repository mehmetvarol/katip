import AppKit
import QuartzCore

/// Masaüstünde yüzen gösterge — tek bir "ada" gibi davranır: duruma göre şekil
/// değiştirir, yer değiştirmez.
///
/// Dört biçim:
///   collapsed → boşta duran ince çubuk (neredeyse görünmez)
///   expanded  → fare üstüne gelince: kısayol etiketi + üç yuvarlak düğme
///   listening → konuşurken: ✕ · ses dalgası · ✓
///   result    → metin imlece yazılamadıysa: kart + metin + Kopyala
///
/// **En kritik kural: odağı ASLA çalmamalı.** `.nonactivatingPanel` olmadan
/// göründüğü an yazdığın uygulama imleç konumunu kaybeder, metin yanlış yere gider.
@MainActor
final class HUDPanel: NSPanel {

    /// Karttan çıkan kullanıcı eylemleri. Panel hiçbirini kendi yorumlamaz —
    /// karar tek durum makinesinde (DictationController) kalsın.
    enum Action { case dictate, finish, cancel, language, copyText, dismiss }

    enum Mode: Equatable {
        case collapsed
        case expanded
        case listening
        case transcribing
        case notice(String)
        case result(String)
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hudEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hudEnabled") }
    }

    /// Kenara yapışma: bu mesafeye kadar yaklaşınca yapışır.
    static let snapDistance: CGFloat = 140
    static let snapMargin: CGFloat = 14

    var onAction: ((Action) -> Void)?

    private let card = CardView()
    private var mode: Mode = .collapsed

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: CardView.size(for: .collapsed)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        // KAPALI: sürüklemeyi kendimiz yapıyoruz (CardView.mouseDragged).
        // AppKit'in sürüklemesi kendi olay döngüsünü çalıştırıyor ve pencere
        // hareketini bize hiç bildirmiyor — bırakma hızını ölçmek imkânsız,
        // dolayısıyla fiske hiç algılanamıyordu. Ayrıca kendi sürüklememiz
        // kavrama noktasını koruyor: kart parmağın altından kaymıyor.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true   // düğme üstü vurgusu için
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        card.onAction = { [weak self] action in self?.onAction?(action) }
        card.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }
        contentView = card

        restorePosition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() { orderFrontRegardless() }

    /// Durum makinesinden gelen her tik. Biçim kararını burada veriyoruz:
    /// kayıt/çeviri sürerken fare nerede olursa olsun listening kazanır, yoksa
    /// kart konuşurken fareyle oynanıp kapanabilirdi.
    func update(state: DictationController.State, level: Float) {
        defer { if card.wantsFrames { startTicking() } }
        card.apply(state: state, level: level)
        setMode(naturalMode(for: state))
    }

    /// Metin imlece yazılamadığında kartı büyütüp metni göster — dikte kaybolmasın.
    func present(result text: String) { setMode(.result(text)) }
    func present(notice text: String) { setMode(.notice(text)) }

    func dismissOverlay() { setMode(hovering ? .expanded : .collapsed) }

    var isSettled: Bool { mode == .collapsed && card.isSettled }

    // MARK: - Biçim

    private var hovering = false
    private var pinnedMode: Mode?   // result/notice — kullanıcı kapatana kadar kalır

    private func naturalMode(for state: DictationController.State) -> Mode {
        switch state {
        case .recording, .locked:
            // Yeni dikte başladıysa eski sonuç kartı kalkmalı — yoksa konuşurken
            // ekranda bir önceki metin duruyor.
            return .listening
        case .transcribing:
            // Kayıt bitti, ✕/✓ düğmeleri artık anlamsız (iptal edecek/bitirecek
            // bir kayıt yok) — ayrı bir biçim, "donmuş" hissi vermesin diye
            // açıkça "çevriliyor" diyor.
            return .transcribing
        default:
            if let pinnedMode { return pinnedMode }
            return hovering ? .expanded : .collapsed
        }
    }

    private var exitCheck: Task<Void, Never>?

    /// AppKit, pencere boyutu her değiştiğinde tracking area'yı yeniden kuruyor ve
    /// bu **sahte `mouseExited`** üretiyor. Naif bağlarsak kart titriyor:
    /// açılıyor → sahte çıkış → kapanıyor → giriş → açılıyor. Bu yüzden çıkışa
    /// hemen inanmıyoruz; kısa bir gecikmeden sonra **gerçek fare konumuna**
    /// bakıp doğruluyoruz.
    private func hoverChanged(_ inside: Bool) {
        exitCheck?.cancel()
        if inside {
            hovering = true
            applyHover()
            return
        }
        exitCheck = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self, !self.pointerInside else { return }
            self.hovering = false
            self.applyHover()
        }
    }

    /// Fare gerçekten kartın üstünde mi? Ekran koordinatlarında sorulur —
    /// tracking area'nın ne dediğinden bağımsız tek doğru kaynak.
    private var pointerInside: Bool { frame.contains(NSEvent.mouseLocation) }

    private func applyHover() {
        guard pinnedMode == nil else { return }
        switch mode {
        case .listening, .transcribing: return        // kayıt/çeviri sürerken karışma
        default: setMode(hovering ? .expanded : .collapsed)
        }
    }

    /// Sürüklerken biçim değişmemeli: her biçim değişimi `setFrame` çağırıyor ve
    /// bu, kullanıcının taşıdığı pencereyi geri konumlandırıp sürüklemeyi
    /// imkânsız kılıyor.
    private(set) var dragging = false

    func setDragging(_ on: Bool) {
        dragging = on
        if on {
            // Hareket hâlindeki kart yakalandı: yayı ANINDA bırak. Kullanıcıyla
            // yarışan bir animasyon, akıcılığı bozan tek şeydir.
            stopAnimating()
        } else {
            grabOffset = nil
            let velocity = releaseVelocity()
            dragSamples.removeAll()
            hovering = pointerInside
            applyHover()
            snapToNearestEdge(velocity: velocity)
        }
    }

    private func setMode(_ new: Mode) {
        guard !dragging else { return }
        switch new {
        case .result, .notice: pinnedMode = new
        default: pinnedMode = nil
        }
        guard new != mode else { return }
        mode = new
        card.mode = new
        resize(to: CardView.size(for: new))
    }

    /// Boyut değişirken ALT-ORTA sabit kalır: kart olduğu yerden büyür, kaymaz.
    /// Kenara yapışıksa ekran dışına taşmasın diye kırpıyoruz.
    private func resize(to size: NSSize) {
        var origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY)
        if let visible = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        // Biçim değişimi çekmece hissi: hafif aşma, çünkü kart bir yerden
        // "açılıyor". Hız devri yok — bunu bir jest başlatmadı.
        animate(to: NSRect(origin: origin, size: size), damping: 0.8, response: 0.3)
    }

    // MARK: - Yay motoru

    /// Kartın çerçevesini süren dört bağımsız yay.
    ///
    /// Dört ayrı yay, tek bir 2B yay değil: X ve Y farklı hızlarda hareket
    /// ettiğinde tek yay ikisini birbirine kilitleyip yolu büker. Genişlik ve
    /// yükseklik de aynı sebeple ayrı — kart hem taşınırken hem biçim
    /// değiştirirken ikisi çakışabiliyor.
    private var springs: (x: Spring, y: Spring, w: Spring, h: Spring)?
    private var displayLink: CADisplayLink?
    private var lastTick: CFTimeInterval = 0

    /// Sürükleme hızını ölçmek için son konumlar. Pencereyi AppKit taşıyor
    /// (`isMovableByWindowBackground`), yani hareket geri çağrısı yok —
    /// çerçeveyi kare kare örneklemekten başka yol yok.
    private var dragSamples: [(point: NSPoint, time: CFTimeInterval)] = []

    /// Sistemde hareket azaltma açıksa yay yok: kart hedefe doğrudan gider.
    /// Azaltılmış hareket "geri bildirim yok" demek değil — kart yine yeni
    /// yerinde beliriyor, sadece yolculuk kaldırılıyor.
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Sürükleme başlıyor: kavrama noktasını sakla, yayı bırak.
    func beginDrag(at screenPoint: NSPoint) {
        stopAnimating()
        dragSamples.removeAll()
        grabOffset = NSPoint(x: screenPoint.x - frame.minX, y: screenPoint.y - frame.minY)
        setDragging(true)
    }

    /// 1:1 takip. Kartın kavrandığı NOKTA korunuyor — merkeze zıplatmak
    /// yanılsamayı anında bozar.
    ///
    /// Kenarda LASTİK BANT var, sert duvar değil. Sert durdurmak "dondu" gibi
    /// okunuyor; artan direnç "cevap veriyor ama burada bir şey yok" diyor.
    func continueDrag(to screenPoint: NSPoint) {
        guard dragging, let grab = grabOffset else { return }
        let wanted = NSPoint(x: screenPoint.x - grab.x, y: screenPoint.y - grab.y)
        let shown = NSScreen.main.map {
            Self.resist(wanted, size: frame.size, within: $0.visibleFrame)
        } ?? wanted
        setFrameOrigin(shown)

        // Hız, KISITLANMAMIŞ konumdan ölçülüyor. Kartın gittiği yerden ölçmek
        // yanlış: lastik bant örnekleri sıkıştırdığı için kenara doğru atılan
        // bir fiske olduğundan yavaş görünüyor. Ölçmek istediğimiz şey elin
        // hareketi, kartın kısıtlanmış cevabı değil. (`--dragprobe` bu
        // regresyonu düzeltmeden önce yakaladı.)
        dragSamples.append((wanted, CACurrentMediaTime()))
        if dragSamples.count > 10 { dragSamples.removeFirst() }
    }

    /// Kenarın ötesinde ne kadar ilerlenebileceğinin tavanı. Formül sonsuz
    /// aşımda bu değere yakınsıyor, yani kart ekran kenarını en fazla bu kadar
    /// geçebilir.
    private static let resistLimit: CGFloat = 60

    /// Sınırın ötesinde ilerlemeye artan direnç uygular.
    ///
    /// SADECE estetik değil, kartın kaybolmasını önleyen ŞART: kart ekranın
    /// tamamen dışına çıkarsa `NSView.displayLink` ateşlenmeyi bırakıyor
    /// (bağlı olduğu ekran kalmıyor) ve onu geri getirecek yay HİÇ ÇALIŞAMIYOR.
    /// Kart orada kilitli kalıyordu — kullanıcı "köşeye savurunca kayboluyor"
    /// diye bildirdi, `--cornerprobe` ile (1512, 1049) konumunda, ekranın
    /// tamamen dışında donmuş hâlde yakalandı.
    static func resist(_ origin: NSPoint, size: NSSize, within visible: NSRect) -> NSPoint {
        func band(_ overshoot: CGFloat) -> CGFloat {
            let d = resistLimit
            return (overshoot * d * 0.55) / (d + 0.55 * abs(overshoot))
        }
        func axis(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            if value < low { return low - band(low - value) }
            if value > high { return high + band(value - high) }
            return value
        }
        return NSPoint(
            x: axis(origin.x, visible.minX, visible.maxX - size.width),
            y: axis(origin.y, visible.minY, visible.maxY - size.height))
    }

    private var grabOffset: NSPoint?

    private func animate(to target: NSRect, damping: CGFloat, response: TimeInterval,
                         velocity: NSPoint = .zero) {
        // Pencere hiçbir ekranla kesişmiyorsa display link ateşlenmez ve yay
        // hiç adım atamaz — animasyonla kurtarmak imkânsız. Doğrudan yerleştir.
        let offScreen = !NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        guard !reduceMotion, !offScreen else {
            if offScreen { Trace.log("kart ekran dışındaydı — animasyonsuz geri alındı") }
            setFrame(target, display: true)
            invalidateShadow()
            savePosition()
            return
        }
        // Yay her zaman EKRANDAKİ değerden başlar, hedef değerden değil.
        // Hedeften başlatmak, kesintiye uğrayan bir animasyonda görünür bir
        // sıçrama demek.
        let now = frame
        springs = (
            Spring(damping: damping, response: response,
                   value: now.minX, target: target.minX, velocity: velocity.x),
            Spring(damping: damping, response: response,
                   value: now.minY, target: target.minY, velocity: velocity.y),
            Spring(damping: damping, response: response,
                   value: now.width, target: target.width),
            Spring(damping: damping, response: response,
                   value: now.height, target: target.height))
        startTicking()
    }

    private func stopAnimating() { springs = nil }

    private func startTicking() {
        if displayLink == nil {
            let link = card.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        lastTick = CACurrentMediaTime()
        displayLink?.isPaused = false
    }

    /// Kare temposu ölçümü (`--jankprobe`). Takılma şikâyetini gözle değil
    /// sayıyla teşhis etmenin tek yolu.
    var frameLog: [(dt: Double, work: Double)]?

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now

        // Sürüklerken çerçeveyi fare sürüyor; yay karışmaz.
        if dragging { return }

        if card.wantsFrames { card.advance(dt) }

        guard var s = springs else {
            // İş yokken 120 Hz'de dönmenin anlamı yok.
            link.isPaused = !card.wantsFrames
            return
        }
        s.x.step(dt); s.y.step(dt); s.w.step(dt); s.h.step(dt)
        springs = s

        let workStart = CACurrentMediaTime()
        setFrame(NSRect(x: s.x.value, y: s.y.value, width: s.w.value, height: s.h.value),
                 display: true)
        if frameLog != nil { frameLog?.append((dt, CACurrentMediaTime() - workStart)) }

        if s.x.isSettled && s.y.isSettled && s.w.isSettled && s.h.isSettled {
            springs = nil
            // KOŞULSUZ `true` hataydı: yay (resize/taşıma) bittiğinde ekran
            // döngüsünü her zaman durduruyordu — kart hâlâ kare istese bile
            // (ör. .transcribing'in dönen göstergesi). .listening'den farklı
            // boyutta olan yeni .transcribing biçimi bunu ortaya çıkardı: kart
            // .listening→.transcribing resize'ı biter bitmez döngü duruyor,
            // gösterge "bir tur atıp" donuyordu. Aynı satırdaki doğru mantık
            // (338. satır) burada da geçerli.
            link.isPaused = !card.wantsFrames
            invalidateShadow()
            savePosition()
        }
    }

    /// Son örneklerden bırakma hızı (piksel/saniye).
    ///
    /// Tek bir kareye bakmak gürültülü — parmak/fare titremesi hızı savuruyor.
    /// En az 30 ms'lik bir pencereye yayılan örnekleri kullanıyoruz; o kadar
    /// veri yoksa hız yok sayılıyor (yavaş bırakma zaten momentum taşımaz).
    func releaseVelocity() -> NSPoint {
        guard let last = dragSamples.last else { return .zero }
        guard let first = dragSamples.first(where: { last.time - $0.time <= 0.12 }),
              last.time - first.time >= 0.03 else { return .zero }

        let dt = CGFloat(last.time - first.time)
        return NSPoint(x: (last.point.x - first.point.x) / dt,
                       y: (last.point.y - first.point.y) / dt)
    }

    /// Sonda için: kartı verilen hızla fırlat.
    func debugFling(to origin: NSPoint, velocity: NSPoint) {
        animate(to: NSRect(origin: origin, size: frame.size),
                damping: 0.8, response: 0.4, velocity: velocity)
    }

    // MARK: - Kenara yapışma

    /// Bırakma anındaki hızla kartı FIRLATIR.
    ///
    /// Eskiden en yakın kenar BIRAKMA noktasından seçiliyordu, yani fiske ile
    /// yavaşça bırakma arasında hiçbir fark yoktu — hız bilgisi çöpe gidiyordu.
    /// Artık önce hızın kartı nereye götüreceği kestiriliyor (kaydırma
    /// yavaşlamasının aynısı), kenar ORADAN seçiliyor ve yay bırakma hızıyla
    /// başlatılıyor. Böylece sürükleme ile animasyon arasında dikiş kalmıyor.
    private func snapToNearestEdge(velocity: NSPoint) {
        guard let visible = NSScreen.main?.visibleFrame else { return }

        // `frame.size` DEĞİL: bu, tıklamanın (ör. ✓ ile bitirme) AYNI mouseUp
        // içinde tetiklediği bir mod değişikliğinden (`.listening` →
        // `.transcribing`) hemen SONRA çağrılıyor. O mod değişikliği kendi
        // `animate(to:)` çağrısını YAPMIŞTI ama springs henüz hiç adım
        // atmadığı için `frame` hâlâ ESKİ boyutta — `frame.size` kullanmak bu
        // yeni yayı geçersiz kılıp kartı YANLIŞ (eski) boyuta geri
        // hedefliyordu. Gerçek dünyada bulundu: karta tıklayınca "yazıya
        // çevriliyor" hiç görünmüyordu, sadece kısayolda görünüyordu — çünkü
        // kısayol bu kod yolundan (mouseUp/snapToNearestEdge) hiç geçmiyor.
        let size = CardView.size(for: card.mode)
        let origin = Self.landingOrigin(frame: NSRect(origin: frame.origin, size: size),
                                        visible: visible, velocity: velocity)

        // Fiske varsa hafif aşma (fiziksel his), yavaş bırakmada yok — hareketi
        // başlatan jest momentum taşımıyorsa zıplamak yapay duruyor.
        let flicked = hypot(velocity.x, velocity.y) > Self.flickVelocity
        Trace.log("bırakma hızı \(Int(hypot(velocity.x, velocity.y))) px/sn — \(flicked ? "FİSKE" : "yavaş")")
        animate(to: NSRect(origin: origin, size: size),
                damping: flicked ? 0.8 : 1.0, response: 0.4, velocity: velocity)
    }

    static let flickVelocity: CGFloat = 200

    /// Kartın nereye ineceği. Saf fonksiyon — ekransız test edilebilsin diye
    /// ayrı (`Katip --flicktest`), `SpeechSegmenter`/`Stitcher` ile aynı gerekçe.
    static func landingOrigin(frame: NSRect, visible: NSRect, velocity: NSPoint) -> NSPoint {
        let projected = NSPoint(x: frame.minX + Momentum.projection(of: velocity.x),
                                y: frame.minY + Momentum.projection(of: velocity.y))
        let projectedRect = NSRect(origin: projected, size: frame.size)

        let toLeft = projectedRect.minX - visible.minX
        let toRight = visible.maxX - projectedRect.maxX
        let toBottom = projectedRect.minY - visible.minY
        let toTop = visible.maxY - projectedRect.maxY

        var origin = projected
        let nearest = min(toLeft, toRight, toBottom, toTop)
        if nearest < snapDistance {
            switch nearest {
            case toLeft:   origin.x = visible.minX + snapMargin
            case toRight:  origin.x = visible.maxX - frame.width - snapMargin
            case toBottom: origin.y = visible.minY + snapMargin
            default:       origin.y = visible.maxY - frame.height - snapMargin
            }
        }

        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)
        return origin
    }

    // MARK: - Konum hatırlama (alt-orta — boyut değiştiği için)

    private static let positionKey = "hudCenter"

    func savePosition() {
        UserDefaults.standard.set(["x": frame.midX, "y": frame.minY], forKey: Self.positionKey)
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.positionKey),
           let x = saved["x"] as? CGFloat, let y = saved["y"] as? CGFloat {
            setFrameOrigin(NSPoint(x: x - frame.width / 2, y: y))
            return
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2,
                                   y: visible.minY + 64))
        }
    }

    // NOT: yapışma burada DEĞİL, `setDragging(false)` içinde. Sıra önemli —
    // CardView bırakışta önce setDragging(false), sonra super.mouseUp çağırıyor;
    // hız örnekleri o ilk çağrıda hâlâ taze.

    /// Kart kaybolduysa (ekran değişti, kenara sıkıştı) geri çağır.
    func recenter() {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.minY + 64))
        savePosition()
        peek()
    }

    /// Kapalı biçim bilerek neredeyse görünmez — ilk açılışta kısa süre açık
    /// dur ki kullanıcı nerede olduğunu görsün.
    func peek() {
        hovering = true
        applyHover()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, !self.pointerInside else { return }
            self.hovering = false
            self.applyHover()
        }
    }

    /// Bir ses kaydını dalga animasyonunun KENDİ kodundan geçirir.
    ///
    /// `renderSample` tek tek seviyeleri gösteriyor; burada ölçtüğümüz şey
    /// zaman içindeki davranış — uyarlanır kazanç ancak böyle sınanabilir.
    static func waveTrace(samples: [Float]) -> [(level: CGFloat, height: CGFloat)] {
        let card = CardView(frame: NSRect(x: 0, y: 0, width: 112, height: 26))
        card.mode = .listening

        let window = 1365            // 4096 kare @48kHz ≈ 85 ms
        let framesPerBuffer = 10     // 85 ms ≈ 10 kare @120 Hz
        var out: [(CGFloat, CGFloat)] = []

        var i = 0
        while i + window < samples.count {
            var peak: Float = 0
            for j in i..<(i + window) { peak = max(peak, abs(samples[j])) }
            card.apply(state: .recording, level: peak)
            for _ in 0..<framesPerBuffer { card.advance(1.0 / 120) }
            out.append((CGFloat(peak), card.currentLevels[card.currentLevels.count / 2]))
            i += window
        }
        return out
    }

    /// Geliştirme yardımcısı: bir biçimi PNG'ye render eder.
    /// Ekran görüntüsü izni olmadan görünümü doğrulamak için — kartın bomboş
    /// çıktığı hatayı bir kez ancak böyle yakalayabildik.
    /// `ticks` > 0 ise sahte ses seviyesiyle animasyon o kadar kare ilerletilir —
    /// durağan bir kare, akan dalganın gerçekten aktığını göstermiyor.
    static func renderSample(mode: Mode, levels: [CGFloat], to path: String,
                             ticks: Int = 0, level: Float = 0.06) {
        let view = CardView(frame: NSRect(origin: .zero, size: CardView.size(for: mode)))
        view.mode = mode
        if ticks > 0 {
            let state: DictationController.State = mode == .listening ? .recording : .transcribing
            view.apply(state: state, level: level)
            // Kareyi ELLE ilerlet: artık ekran saatiyle sürülüyor, burada ekran yok.
            for _ in 0..<ticks { view.advance(1.0 / 60) }
        } else {
            view.debugLevels = levels
            view.apply(state: mode == .listening ? .recording : .idle, level: 0)
        }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Kart görünümü

/// Referans tasarım her duvar kâğıdının üstünde AYNI koyulukta duruyor — yani
/// vibrancy değil, opak bir yüzey. Bu yüzden `NSVisualEffectView` yok: her şeyi
/// kendimiz çiziyoruz. Yan faydası, `expanded` biçiminde üç ayrı yüzeyi
/// (etiket + üç daire) tek pencerede çizebilmek; blur'lu tek dikdörtgenle bu
/// mümkün değildi.
@MainActor
private final class CardView: NSView, NSViewToolTipOwner {
    var onAction: ((HUDPanel.Action) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    var mode: HUDPanel.Mode = .collapsed {
        didSet { hovered = nil; painter.needsDisplay = true }
    }

    private var state: DictationController.State = .loadingModel()
    private var levels: [CGFloat] = Array(repeating: 0.05, count: 16)
    private var phase: CGFloat = 0
    private var hovered: HUDPanel.Action?
    private var dragOrigin: NSPoint?

    /// Yumuşatılmış canlı ses enerjisi (0...1).
    private var energy: CGFloat = 0

    /// Hedef yüksekliği hesaplayıp mevcut değerleri ona doğru yumuşatır.
    /// `x` çubuğun 0...1 aralığındaki konumu.
    private func shape(_ target: (Int, CGFloat) -> CGFloat) {
        let last = CGFloat(max(1, levels.count - 1))
        for index in levels.indices {
            let x = CGFloat(index) / last
            levels[index] += (target(index, x) - levels[index]) * 0.42
        }
    }

    private static let floor: CGFloat = 0.05
    private(set) var isSettled = false
    var debugLevels: [CGFloat]?

    private let painter = PainterView()

    // MARK: Ölçüler

    static func size(for mode: HUDPanel.Mode) -> NSSize {
        // Kapalı biçim SABİT — kullanıcının referans aldığı görünüm o.
        // Diğerleri ~%20 küçültüldü ve iç boşlukları kısıldı: kart masaüstünde
        // duran bir çubuk, açıldığında pencere gibi büyümemeli.
        switch mode {
        case .collapsed: NSSize(width: 58, height: 18)
        case .expanded:  NSSize(width: 88, height: 58)
        case .listening: NSSize(width: 112, height: 26)
        case .transcribing: NSSize(width: textWidth(Self.transcribingText, 10) + 46, height: 26)
        case .notice(let text): NSSize(width: min(280, max(132, textWidth(text, 10) + 62)), height: 26)
        case .result:    NSSize(width: 224, height: 116)
        }
    }

    static let transcribingText = "Yazıya çevriliyor…"

    private static func textWidth(_ text: String, _ points: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: points)]).width
    }

    // MARK: Palet — referans koyu yüzeye sabitlenmiş

    // Renkler artık Palette.swift'te — CardView'in KENDİSİ `private`, yani
    // bu sabitler burada kalsaydı dosya dışından erişilemezdi. LanguageMenu
    // gibi kartla AYNI yüzeyde görünmesi gereken diğer pencereler oradan
    // çekiyor; burada da kısayol olarak duruyor ki mevcut çizim kodu
    // değişmesin.
    private static let surface   = Palette.surface
    private static let control   = Palette.control
    private static let controlUp = Palette.controlUp
    private static let primary   = Palette.primary
    private static let glyph     = Palette.glyph
    private static let muted     = Palette.muted
    private static let wave      = Palette.wave

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // AppKit bir view'ın kendi draw()'unu alt view'lardan ÖNCE çizer. Çizimi
        // ayrı bir üst katmanda tutmak bu tuzağı tamamen kapatıyor.
        painter.owner = self
        painter.autoresizingMask = [.width, .height]
        painter.frame = bounds
        addSubview(painter)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Fare takibi

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self))
        updateToolTips()
    }

    /// Her düğme için gerçek (sistemin kendi) araç ipucu. Çizim/tıklama/ipucu
    /// AYNI `plan()` çağrısından besleniyor — üçü ayrı hesaplansa, biri
    /// güncellenip diğeri unutulduğunda sessizce birbirinden sapar.
    ///
    /// Doğrudan neden: "kilit" düğmesinin ikonu hiç değişmiyordu ve
    /// kullanıcı ne işe yaradığını anlayamadı. İkon düzeltmesi yeterli
    /// olabilirdi ama Katip zaten çok az kelimeyle çalışan bir arayüz —
    /// gerçek bir tooltip şüpheye hiç yer bırakmıyor.
    private var toolTipText: [NSView.ToolTipTag: String] = [:]

    private func updateToolTips() {
        removeAllToolTips()
        toolTipText.removeAll()
        for (action, rect) in plan().buttons {
            let tag = addToolTip(rect, owner: self, userData: nil)
            toolTipText[tag] = toolTip(for: action)
        }
    }

    private func toolTip(for action: HUDPanel.Action) -> String {
        switch action {
        case .language: "Dikte dili"
        // Tıkla → başlar, elini çek, tekrar tıkla → biter. Aynı jestin
        // klavye karşılığı için ayrı bir ipucu gerekmiyor; kısayol
        // etiketi zaten karttaki "Dikte ⌥" satırında görünüyor.
        case .dictate:  "Tıkla — elini çekmeden dikte, tekrar tıkla → bitir"
        case .cancel:   "İptal et"
        case .finish:   "Bitir ve yaz"
        case .copyText: "Kopyala"
        case .dismiss:  "Kapat"
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
             userData: UnsafeMutableRawPointer?) -> String {
        toolTipText[tag] ?? ""
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        painter.needsDisplay = true
        onHoverChange?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = plan().hitTest(point)
        guard hit != hovered else { return }
        hovered = hit
        painter.needsDisplay = true
    }

    // Sürükleme ile tıklamayı ayır: kart taşınabilir olduğu için her mouseUp
    // tıklama sayılamaz.
    override func mouseDown(with event: NSEvent) {
        dragOrigin = window?.frame.origin
        (window as? HUDPanel)?.beginDrag(at: NSEvent.mouseLocation)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        (window as? HUDPanel)?.continueDrag(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        let panel = window as? HUDPanel
        defer { super.mouseUp(with: event) }
        guard let start = dragOrigin, let now = window?.frame.origin,
              hypot(now.x - start.x, now.y - start.y) < 4 else {
            panel?.setDragging(false)
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        // `setDragging(false)` (dragging=false yapıp kenara yapıştırır)
        // ÖNCE çalışmalı: `onAction` bir mod değişikliğine yol açabilir
        // (ör. ✓ ile bitirme → .transcribing) ve `setMode()` sürüklerken
        // hiçbir şey yapmıyor (`guard !dragging`). `mouseDown` HER basışta
        // `dragging = true` yapıyor — gerçek bir sürükleme olmasa bile
        // (salt tıklama). Sıra ters olsaydı `onAction` HÂLÂ dragging=true
        // iken ateşlenir, mod değişikliği sessizce YOK SAYILIRDI.
        // Gerçek dünyada bulundu: karttaki ✓'a tıklayınca "çevriliyor"
        // hiç görünmüyordu, kısayolda görünüyordu (o yol mouseUp'tan
        // hiç geçmiyor, dragging hiç true olmuyor).
        panel?.setDragging(false)
        // Boş alana tıklamak sadece kapalı çubukta iş yapar; açık biçimde
        // düğmelerin arası taşıma tutamağıdır.
        if let hit = plan().hitTest(point) { onAction?(hit) }
        else if mode == .collapsed { onAction?(.dictate) }
    }

    // MARK: Seviye

    /// Ses seviyesini ve durumu al. ANİMASYONU İLERLETMEZ.
    ///
    /// Ayrım şart: bu 30 Hz'lik bir zamanlayıcıdan geliyor (mikrofon seviyesi
    /// için fazlasıyla yeterli), animasyon ise ekranla senkron ilerlemeli.
    /// İkisi birleşikken dalga 30 Hz'de takılıyordu — 120 Hz ekranda dörtte
    /// bir çözünürlük, üstelik `Timer` ekranla senkron olmadığı için düzensiz.
    func apply(state: DictationController.State, level: Float) {
        self.state = state
        self.inputLevel = level
        if let debugLevels { levels = debugLevels; painter.needsDisplay = true }
    }

    /// Ekranın kendi saatiyle bir kare ilerlet. `HUDPanel`'in display link'i
    /// çağırıyor.
    ///
    /// Bütün hızlar SANİYE cinsinden — kare hızından bağımsız. Eskiden kare
    /// başına sabit artışlardı (`phase += 0.34`), yani animasyonun hızı ekranın
    /// kare hızına bağlıydı: 120 Hz'de dört kat hızlı akacaktı.
    func advance(_ dt: TimeInterval) {
        guard debugLevels == nil else { return }
        let dt = CGFloat(min(dt, 1.0 / 30))

        switch state {
        case .recording, .locked:
            isSettled = false
            // Ataklı zarf: sese HIZLI yüksel, yavaş in. Simetrik yumuşatma
            // konuşmanın vuruşunu ezip animasyonu cansız gösteriyordu.
            // Zaman sabitleri saniye: yükselişte 20 ms, inişte 110 ms.
            // UYARLANIR kazanç. Sabit kazanç çalışmıyor çünkü oturumlar
            // arasında 3 KAT fark var — gerçek kayıtlardan ölçüldü (tampon
            // başına tepe, konuşma anları):
            //
            //     kısık oturum   p50 0.045   p90 0.067   max 0.095
            //     yüksek oturum  p50 0.143   p90 0.235   max 0.438
            //
            // Sabit 2.5 kazançla kısık oturum kapının hemen üstünde kalıyor ve
            // dalga konuşurken bile DÜMDÜZ görünüyordu (kullanıcı bildirdi).
            // Referansı son saniyelerin tepesinden alıyoruz: mikrofon uzak da
            // olsa yakın da olsa konuşma tam yüksekliğe çıkıyor.
            let level = CGFloat(inputLevel)
            loudest = max(level, loudest * exp(-Self.referenceDecay * dt))

            // MUTLAK kapı — VAD'in konuşma eşiğiyle aynı. Uyarlanır kazancın
            // tek riski sessizlikte gürültüyü şişirmek; bunu engelleyen bu.
            let speaking = level > Self.speechFloor
            let reference = max(loudest, Self.minimumReference)
            let raw = speaking ? min(1, level / reference) : 0

            let tau: CGFloat = raw > energy ? 0.020 : 0.110
            energy += (raw - energy) * (1 - exp(-dt / tau))
            phase += Self.waveSpeed * dt

            // Kapı zaten sessizliği hallediyor; buradaki eğri konuşmanın alt
            // yarısını yukarı çekiyor (üs 1'in ALTINDA — 1.3 denendi ve gerçek
            // kısık konuşmayı dümdüz bıraktığı render'da görüldü).
            let punch = pow(energy, 0.7)

            shape { index, x in
                // Ortada yüksek, uçlarda sönen siluet × soldan sağa akan dalga.
                let envelope = 0.22 + 0.78 * sin(.pi * x)
                let travel = 0.35 + 0.65 * sin(self.phase - CGFloat(index) * 0.55)
                return max(0.04, punch * envelope * travel)
            }

        case .transcribing:
            isSettled = false
            phase += Self.pulseSpeed * dt
            // Soldan sağa geçen tek bir kabarcık — "çalışıyor" der, seviye taklidi
            // yapmaz. Mikrofon kapalıyken sahte ses dalgası göstermek yalan olurdu.
            let head = (phase * 0.09).truncatingRemainder(dividingBy: 1.5) - 0.25
            shape { _, x in
                let distance = abs(x - head)
                return 0.10 + 0.75 * exp(-pow(distance / 0.16, 2))
            }

        default:
            energy = 0
            // Sönme de zaman tabanlı: saniyede ~e^-9, eski 30 Hz'deki 0.74/kare
            // ile aynı his.
            let decay = exp(-9 * dt)
            for index in levels.indices {
                levels[index] = max(Self.floor, levels[index] * decay)
            }
            isSettled = levels.allSatisfy { $0 <= Self.floor + 0.001 }
        }
        painter.needsDisplay = true
    }

    /// Dalganın akış hızı, radyan/saniye. Eski 30 Hz × 0.34 rad/kare ile aynı.
    /// Referansın sönme hızı (1/sn). ~3 saniyede yarıya iner: konuşmanın
    /// tepesini hatırlayacak kadar uzun, sesini alçalttığında uyum sağlayacak
    /// kadar kısa.
    private static let referenceDecay: CGFloat = 0.231

    /// Referansın alt sınırı. Bu olmasaydı tamamen sessiz bir odada uyarlanır
    /// kazanç mikrofon gürültüsünü tavana çıkarırdı.
    private static let minimumReference: CGFloat = 0.05

    /// Bunun altı konuşma sayılmaz — `SpeechSegmenter.speechPeak` ile aynı
    /// değer. İki yer aynı eşiği kullanmalı: VAD'in "konuşma yok" dediği anda
    /// dalganın kıpırdaması yalan olur.
    private static let speechFloor: CGFloat = 0.03

    private static let waveSpeed: CGFloat = 0.34 * 30
    private static let pulseSpeed: CGFloat = 0.22 * 30

    private var inputLevel: Float = 0

    /// Son saniyelerin en yüksek seviyesi — uyarlanır kazancın referansı.
    private var loudest: CGFloat = 0

    /// Sonda için: çubukların anlık yüksekliği (0-1).
    var currentLevels: [CGFloat] { levels }

    /// Ekran karesi istiyor mu? Yalnızca hareketli durumlarda — boşta display
    /// link'i döndürmenin anlamı yok.
    var wantsFrames: Bool {
        switch state {
        case .recording, .locked, .transcribing: true
        default: !isSettled
        }
    }

    // MARK: - Yerleşim
    //
    // Çizim ve tıklama AYNI hesaptan besleniyor. Ayrı hesaplarsak düğmenin
    // göründüğü yer ile tıklanan yer sessizce ayrışır.

    private struct Layout {
        var buttons: [(HUDPanel.Action, NSRect)] = []
        var label = NSRect.zero
        var wave = NSRect.zero
        var line = NSRect.zero
        var body = NSRect.zero
        var hint = NSRect.zero
        var mark = NSRect.zero

        func hitTest(_ point: NSPoint) -> HUDPanel.Action? {
            buttons.first { $0.1.insetBy(dx: -2, dy: -2).contains(point) }?.0
        }
    }

    private func plan() -> Layout {
        var l = Layout()
        switch mode {
        case .collapsed:
            l.line = NSRect(x: bounds.midX - 13, y: bounds.midY - 2, width: 26, height: 4)

        case .expanded:
            // Düğme sırası ALTTA, etiket ÜSTTE — fare çubuğun olduğu yerde kalsın
            // diye kart yukarı doğru açılıyor.
            //
            // ÜÇÜNCÜ bir "kilit" düğmesi VARDI, kaldırıldı: fare tıklaması
            // klavyenin "basılı tut"u gibi ÇALIŞAMIYOR (tıklama an be an,
            // basılı kalmıyor), yani mikrofona tıklamak zaten "elini çek,
            // tekrar tıklayana kadar dinle" demekti — kilit modunun tanımının
            // AYNISI. Kullanıcı ikisinin de aynı işi yaptığını fark etti;
            // ikisi GERÇEKTEN aynı işi yapıyordu. Kilit artık sadece
            // klavyenin çift-bas jestinde yaşıyor.
            let cy: CGFloat = 17
            l.buttons = [
                (.language, circle(x: bounds.midX - 21, y: cy, d: 24)),
                (.dictate,  circle(x: bounds.midX + 18, y: cy, d: 30)),
            ]
            let width = min(bounds.width - 6, Self.textWidth(hintTitle, 10) + 18)
            l.label = NSRect(x: bounds.midX - width / 2, y: 37, width: width, height: 20)

        case .listening:
            let d: CGFloat = 18
            let inset: CGFloat = 4
            l.buttons = [
                (.cancel,  circle(x: inset + d / 2, y: bounds.midY, d: d)),
                (.finish,  circle(x: bounds.maxX - inset - d / 2, y: bounds.midY, d: d)),
            ]
            // Düğme ile dalga arası 5 pt: daha fazlası kartı boş gösteriyor,
            // daha azı dalgayı düğmeye yapıştırıyor.
            let gap = inset + d + 5
            l.wave = NSRect(x: gap, y: bounds.minY + 4,
                            width: bounds.width - 2 * gap, height: bounds.height - 8)

        case .transcribing:
            // Düğme yok — kayıt bitti, iptal/bitir edilecek bir şey kalmadı.
            l.mark = NSRect(x: 12, y: bounds.midY - 6, width: 12, height: 12)
            l.body = NSRect(x: 30, y: bounds.midY - 7, width: bounds.width - 30 - 10, height: 15)

        case .notice:
            l.mark = NSRect(x: 9, y: bounds.midY - 5, width: 11, height: 11)
            l.body = NSRect(x: 25, y: bounds.midY - 7, width: bounds.width - 25 - 27, height: 15)
            l.buttons = [(.dismiss, circle(x: bounds.maxX - 15, y: bounds.midY, d: 17))]

        case .result:
            l.mark = NSRect(x: 14, y: bounds.maxY - 28, width: 12, height: 12)
            l.hint = NSRect(x: 32, y: bounds.maxY - 29, width: bounds.width - 32 - 38, height: 14)
            l.buttons = [
                (.dismiss,  circle(x: bounds.maxX - 21, y: bounds.maxY - 22, d: 19)),
                (.copyText, NSRect(x: bounds.maxX - 14 - 58, y: 13, width: 58, height: 22)),
            ]
            l.body = NSRect(x: 14, y: 42, width: bounds.width - 28, height: bounds.height - 42 - 34)
        }
        return l
    }

    private func circle(x: CGFloat, y: CGFloat, d: CGFloat) -> NSRect {
        NSRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
    }

    // MARK: - Çizim

    private var hintTitle: String {
        let glyph = HotkeyChoice.current.glyph
        return glyph.isEmpty ? "Dikte" : "Dikte  \(glyph)"
    }

    /// Modele hazır mı? Referanstaki yeşil nokta buradan besleniyor — sadece
    /// süs değil, "şimdi konuşabilirsin" sinyali.
    private var statusDot: NSColor? {
        switch state {
        case .idle:         .systemGreen
        case .loadingModel: .systemOrange
        case .error:        .systemRed
        default:            nil
        }
    }

    fileprivate func render() {
        let l = plan()
        switch mode {
        case .collapsed:
            fillSurface(bounds, radius: bounds.height / 2)
            NSColor(white: 1.0, alpha: 0.28).setFill()
            NSBezierPath(roundedRect: l.line, xRadius: 3, yRadius: 3).fill()

        case .expanded:
            // Tek yüzey YOK: etiket ve daireler ayrı ayrı, aralarından duvar
            // kâğıdı görünüyor — referanstaki asıl karakter bu.
            fillSurface(l.label, radius: l.label.height / 2)
            drawHint(in: l.label)
            for (action, rect) in l.buttons { drawCircle(action, rect, standalone: true) }

        case .listening:
            fillSurface(bounds, radius: bounds.height / 2)
            for (action, rect) in l.buttons { drawCircle(action, rect) }
            drawWave(in: l.wave)

        case .transcribing:
            fillSurface(bounds, radius: bounds.height / 2)
            drawSpinner(in: l.mark, phase: phase, color: Self.primary)
            draw(Self.transcribingText, in: l.body, points: 11, weight: .regular,
                color: Self.glyph, align: .left)

        case .notice(let text):
            fillSurface(bounds, radius: bounds.height / 2)
            drawSymbol("exclamationmark.triangle.fill", in: l.mark, points: 11,
                       color: .systemOrange)
            draw(text, in: l.body, points: 11, weight: .regular, color: Self.glyph, align: .left)
            for (action, rect) in l.buttons { drawCircle(action, rect) }

        case .result(let text):
            fillSurface(bounds, radius: 20)
            drawSymbol("waveform", in: l.mark, points: 12, color: Self.glyph)
            draw("İmlece yazılamadı — kopyalayabilirsin", in: l.hint,
                 points: 10.5, weight: .regular, color: Self.muted, align: .center)
            draw(text, in: l.body, points: 13.5, weight: .regular, color: Self.glyph,
                 align: .left, wraps: true)
            for (action, rect) in l.buttons { drawCircle(action, rect) }
        }
    }

    private func fillSurface(_ rect: NSRect, radius: CGFloat) {
        Self.surface.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    /// "Dikte" normal, kısayol tuşu kalın — referanstaki "Dictate ^ Ctrl" ritmi.
    private func drawHint(in rect: NSRect) {
        let text = NSMutableAttributedString(
            string: "Dikte", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Self.muted])
        let glyph = HotkeyChoice.current.glyph
        if !glyph.isEmpty {
            text.append(NSAttributedString(string: "  \(glyph)", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: Self.glyph]))
        }
        let size = text.size()
        text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// `standalone` = düğme kendi başına duvar kâğıdının üstünde (expanded biçim).
    /// O zaman kendi koyu zeminini çizmesi gerekiyor; kartın üstündeki düğmeler
    /// ise sadece yarı saydam bir vurgu. Bu ayrımı atlayınca daireler duvar
    /// kâğıdının üstünde soluk lekelere dönüşüyor.
    private func drawCircle(_ action: HUDPanel.Action, _ rect: NSRect,
                            standalone: Bool = false) {
        let isPrimary = (action == .finish)
        let isPill = (action == .copyText)
        let up = hovered == action
        let radius = isPill ? rect.height / 2 : rect.width / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        if isPrimary {
            Self.primary.setFill()
            path.fill()
        } else if standalone {
            Self.surface.setFill()
            path.fill()
            // Ortadaki mikrofon kardeşlerinden bir ton açık — hiyerarşi böyle kuruluyor.
            let lift: CGFloat = (action == .dictate ? 0.10 : 0) + (up ? 0.08 : 0)
            if lift > 0 {
                NSColor(white: 1.0, alpha: lift).setFill()
                path.fill()
            }
        } else {
            (up ? Self.controlUp : Self.control).setFill()
            path.fill()
        }

        if isPill {
            draw("Kopyala", in: NSRect(x: rect.minX, y: rect.midY - 7, width: rect.width, height: 15),
                 points: 11, weight: .medium, color: Self.glyph, align: .center)
            return
        }

        let tint: NSColor = isPrimary ? NSColor(white: 0.08, alpha: 1) : Self.glyph
        let points = rect.width * 0.44
        drawSymbol(symbolName(action), in: rect, points: points, color: tint)

        // Yeşil nokta: mikrofon düğmesinin sağ üstünde, modelin hazır olduğunu söyler.
        if action == .dictate, let dot = statusDot {
            let d: CGFloat = 7
            let spot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            Self.surface.setFill()
            NSBezierPath(ovalIn: spot.insetBy(dx: -1.2, dy: -1.2)).fill()
            dot.setFill()
            NSBezierPath(ovalIn: spot).fill()
        }
    }

    private func symbolName(_ action: HUDPanel.Action) -> String {
        switch action {
        case .language: "globe"
        case .dictate:  "mic.fill"
        case .cancel:   "xmark"
        case .finish:   "checkmark"
        case .dismiss:  "xmark"
        case .copyText: "doc.on.doc"
        }
    }

    /// Ses dalgası. Boştayken çubuklar taban seviyesinde durur — sürekli animasyon
    /// boşta %9 CPU yakıyordu, o yüzden hareket sadece iş varken.
    private func drawWave(in area: NSRect) {
        guard area.width > 10 else { return }
        let spacing: CGFloat = 2
        let minBar: CGFloat = 2
        let fits = Int((area.width + spacing) / (minBar + spacing))
        let count = max(3, min(levels.count, fits))
        let barWidth = (area.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let shown = levels.prefix(count)   // desen artık geçmiş değil, akan dalga

        (state == .locked ? NSColor.systemOrange : Self.wave).setFill()
        for (index, value) in shown.enumerated() {
            let height = max(barWidth, value * area.height)
            let x = area.minX + CGFloat(index) * (barWidth + spacing)
            let rect = NSRect(x: x, y: area.midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    /// Klasik döner yükleniyor göstergesi — 270° yay, `phase` arttıkça döner.
    /// SF Symbol animasyonuna gerek yok, tek bir çizgi çizip döndürmek yeterli.
    private func drawSpinner(in rect: NSRect, phase: CGFloat, color: NSColor) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        let start = (phase * 90).truncatingRemainder(dividingBy: 360)
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: start, endAngle: start + 270, clockwise: false)
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawSymbol(_ name: String, in rect: NSRect, points: CGFloat, color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }

        // Şablon olarak boyayıp istediğimiz renge çeviriyoruz.
        let image = NSImage(size: base.size, flipped: false) { r in
            color.set()
            base.draw(in: r)
            r.fill(using: .sourceAtop)
            return true
        }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    private func draw(_ text: String, in rect: NSRect, points: CGFloat,
                      weight: NSFont.Weight, color: NSColor,
                      align: NSTextAlignment, wraps: Bool = false) {
        let style = NSMutableParagraphStyle()
        style.alignment = align
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        style.lineSpacing = wraps ? 3 : 0
        (text as NSString).draw(in: rect, withAttributes: [
            .font: NSFont.systemFont(ofSize: points, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style])
    }

    /// Şeffaf üst katman: tüm çizim burada. Tıklamaları yakalamaz, alttaki
    /// karta geçirir.
    @MainActor
    fileprivate final class PainterView: NSView {
        weak var owner: CardView?
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { owner?.render() }
    }
}
