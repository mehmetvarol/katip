import AppKit

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
    enum Action { case dictate, finish, cancel, lock, language, copyText, dismiss }

    enum Mode: Equatable {
        case collapsed
        case expanded
        case listening
        case notice(String)
        case result(String)
    }

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hudEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hudEnabled") }
    }

    /// Kenara yapışma: bu mesafeye kadar yaklaşınca yapışır.
    private static let snapDistance: CGFloat = 140
    private static let snapMargin: CGFloat = 14

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
        isMovableByWindowBackground = true
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
        case .recording, .locked, .transcribing:
            // Yeni dikte başladıysa eski sonuç kartı kalkmalı — yoksa konuşurken
            // ekranda bir önceki metin duruyor.
            return .listening
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
        case .listening: return                      // kayıt sürerken karışma
        default: setMode(hovering ? .expanded : .collapsed)
        }
    }

    /// Sürüklerken biçim değişmemeli: her biçim değişimi `setFrame` çağırıyor ve
    /// bu, kullanıcının taşıdığı pencereyi geri konumlandırıp sürüklemeyi
    /// imkânsız kılıyor.
    private(set) var dragging = false

    func setDragging(_ on: Bool) {
        dragging = on
        if !on {
            hovering = pointerInside
            applyHover()
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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(NSRect(origin: origin, size: size), display: true)
        } completionHandler: { [weak self] in
            self?.invalidateShadow()
        }
    }

    // MARK: - Kenara yapışma

    private func snapToNearestEdge() {
        guard let visible = NSScreen.main?.visibleFrame else { return }

        let toLeft = frame.minX - visible.minX
        let toRight = visible.maxX - frame.maxX
        let toBottom = frame.minY - visible.minY
        let toTop = visible.maxY - frame.maxY

        var origin = frame.origin
        let nearest = min(toLeft, toRight, toBottom, toTop)
        guard nearest < Self.snapDistance else { return }

        switch nearest {
        case toLeft:   origin.x = visible.minX + Self.snapMargin
        case toRight:  origin.x = visible.maxX - frame.width - Self.snapMargin
        case toBottom: origin.y = visible.minY + Self.snapMargin
        default:       origin.y = visible.maxY - frame.height - Self.snapMargin
        }

        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(origin)
        }
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

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        snapToNearestEdge()
        savePosition()
    }

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
            for _ in 0..<ticks { view.apply(state: state, level: level) }
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
private final class CardView: NSView {
    var onAction: ((HUDPanel.Action) -> Void)?
    var onHoverChange: ((Bool) -> Void)?

    var mode: HUDPanel.Mode = .collapsed {
        didSet { hovered = nil; painter.needsDisplay = true }
    }

    private var state: DictationController.State = .loadingModel
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
        switch mode {
        case .collapsed: NSSize(width: 58, height: 18)
        case .expanded:  NSSize(width: 136, height: 74)
        case .listening: NSSize(width: 140, height: 32)
        case .notice(let text): NSSize(width: min(320, max(150, textWidth(text, 11) + 76)), height: 30)
        case .result:    NSSize(width: 280, height: 140)
        }
    }

    private static func textWidth(_ text: String, _ points: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: points)]).width
    }

    // MARK: Palet — referans koyu yüzeye sabitlenmiş

    private static let surface   = NSColor(white: 0.10, alpha: 0.94)
    private static let control   = NSColor(white: 1.0, alpha: 0.13)
    private static let controlUp = NSColor(white: 1.0, alpha: 0.22)   // fare üstündeyken
    private static let primary   = NSColor(white: 1.0, alpha: 0.96)   // ✓ dolu daire
    private static let glyph     = NSColor(white: 1.0, alpha: 0.92)
    private static let muted     = NSColor(white: 1.0, alpha: 0.42)
    private static let wave      = NSColor(white: 1.0, alpha: 0.62)

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
        (window as? HUDPanel)?.setDragging(true)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            (window as? HUDPanel)?.setDragging(false)
            super.mouseUp(with: event)
        }
        guard let start = dragOrigin, let now = window?.frame.origin,
              hypot(now.x - start.x, now.y - start.y) < 4 else { return }

        let point = convert(event.locationInWindow, from: nil)
        // Boş alana tıklamak sadece kapalı çubukta iş yapar; açık biçimde
        // düğmelerin arası taşıma tutamağıdır.
        if let hit = plan().hitTest(point) { onAction?(hit) }
        else if mode == .collapsed { onAction?(.dictate) }
    }

    // MARK: Seviye

    func apply(state: DictationController.State, level: Float) {
        self.state = state
        if let debugLevels { levels = debugLevels; painter.needsDisplay = true; return }

        switch state {
        case .recording, .locked:
            isSettled = false
            // Ataklı zarf: sese HIZLI yüksel, yavaş in. Simetrik yumuşatma
            // konuşmanın vuruşunu ezip animasyonu cansız gösteriyordu.
            let raw = min(1, CGFloat(level) * 7)
            energy += (raw - energy) * (raw > energy ? 0.55 : 0.16)
            phase += 0.34
            shape { index, x in
                // Ortada yüksek, uçlarda sönen siluet × soldan sağa akan dalga.
                let envelope = 0.30 + 0.70 * sin(.pi * x)
                let travel = 0.55 + 0.45 * sin(self.phase - CGFloat(index) * 0.55)
                return max(0.05, self.energy * envelope * travel)
            }

        case .transcribing:
            isSettled = false
            phase += 0.22
            // Soldan sağa geçen tek bir kabarcık — "çalışıyor" der, seviye taklidi
            // yapmaz. Mikrofon kapalıyken sahte ses dalgası göstermek yalan olurdu.
            let head = (phase * 0.09).truncatingRemainder(dividingBy: 1.5) - 0.25
            shape { _, x in
                let distance = abs(x - head)
                return 0.10 + 0.75 * exp(-pow(distance / 0.16, 2))
            }

        default:
            energy = 0
            for index in levels.indices {
                levels[index] = max(Self.floor, levels[index] * 0.74)
            }
            isSettled = levels.allSatisfy { $0 <= Self.floor + 0.001 }
        }
        painter.needsDisplay = true
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
            let cy: CGFloat = 20
            l.buttons = [
                (.language, circle(x: bounds.midX - 39, y: cy, d: 29)),
                (.dictate,  circle(x: bounds.midX,      y: cy, d: 36)),
                (.lock,     circle(x: bounds.midX + 39, y: cy, d: 29)),
            ]
            let width = min(bounds.width - 6, Self.textWidth(hintTitle, 11) + 24)
            l.label = NSRect(x: bounds.midX - width / 2, y: 47, width: width, height: 25)

        case .listening:
            let d: CGFloat = 22
            let inset: CGFloat = 5
            l.buttons = [
                (.cancel,  circle(x: inset + d / 2, y: bounds.midY, d: d)),
                (.finish,  circle(x: bounds.maxX - inset - d / 2, y: bounds.midY, d: d)),
            ]
            let gap = inset + d + 7
            l.wave = NSRect(x: gap, y: bounds.minY + 7,
                            width: bounds.width - 2 * gap, height: bounds.height - 14)

        case .notice:
            l.mark = NSRect(x: 11, y: bounds.midY - 6, width: 13, height: 13)
            l.body = NSRect(x: 30, y: bounds.midY - 7, width: bounds.width - 30 - 32, height: 15)
            l.buttons = [(.dismiss, circle(x: bounds.maxX - 17, y: bounds.midY, d: 19))]

        case .result:
            l.mark = NSRect(x: 18, y: bounds.maxY - 34, width: 14, height: 14)
            l.hint = NSRect(x: 40, y: bounds.maxY - 35, width: bounds.width - 40 - 46, height: 15)
            l.buttons = [
                (.dismiss,  circle(x: bounds.maxX - 26, y: bounds.maxY - 27, d: 22)),
                (.copyText, NSRect(x: bounds.maxX - 18 - 66, y: 16, width: 66, height: 25)),
            ]
            l.body = NSRect(x: 18, y: 50, width: bounds.width - 36, height: bounds.height - 50 - 42)
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
        case .dictate:  state == .locked ? "lock.fill" : "mic.fill"
        case .lock:     "record.circle"
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
