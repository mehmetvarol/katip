import AppKit

/// Menü çubuğu menüsü — native `NSMenu` DEĞİL (tasarım: "Katip Menü Çubuğu
/// Menüsü" tuvali).
///
/// Neden kendi panelimiz:
/// - `NSMenu` sistemin temasını alıyor, Katip'in yüzeyi ise HER ZAMAN koyu
///   (`Palette`) — kart ve dil menüsüyle aynı dil.
/// - Tasarımın istediği şeyler native menüde yok: durum çipi ve canlı logo,
///   aç/kapa anahtarları, satır içinde açılan gruplar, ikonlar, animasyon.
/// - Native menü her tıklamada kapanıyor; burada anahtarlar ve dil/kısayol
///   seçimi menüyü kapatmadan değişiyor.
///
/// Menü kendi kararını vermiyor: modeli (`[Element]`) AppDelegate kuruyor,
/// her tıklamadan ve her durum değişikliğinden sonra `reload()` ile yeniden
/// soruyor — tek doğruluk kaynağı yine AppDelegate/DictationController.
@MainActor
final class StatusMenu: NSPanel {

    // MARK: - Model

    struct Header {
        var version: String
        var status: Status
        var hint: Hint
        var progress: Double? = nil
    }

    enum Status: Equatable {
        case ready, recording, locked, transcribing, loading, error
        case downloading(Double)
        case permissions(Int)
    }

    enum Hint {
        case idle(String)       // kısayol glifi
        case recording(String)
        case locked(String)
        case text(String)
        case none
    }

    enum Accessory {
        case none
        case disclosure(String?)     // değer + dönen ok (grup açar)
        case shortcut(String)
        case toggle(Bool)
        case check(Bool)
        case link(String)
        case pill(String, NSColor)
        case badges([String])        // izinlerin yeşil rozetleri
        case hoverSymbol(String)     // yalnızca fare üstündeyken görünür
    }

    enum Tone { case normal, soft, dim, warning, danger, primary }

    struct Row {
        var id: String
        var symbol: String?
        var title: String
        var caption: String? = nil
        var accessory: Accessory = .none
        var tone: Tone = .normal
        var expands: String? = nil
        var closes: Bool = true
        var action: (() -> Void)? = nil
    }

    enum Element {
        case header(Header)
        case separator
        case section(String)
        case row(Row)
        case group(String, [Row])
    }

    // MARK: - Panel

    static let width: CGFloat = 300

    private let menuView: StatusMenuView
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var ticker: Timer?
    private var lastTick = CACurrentMediaTime()
    private var closing = false

    /// Menüyü açan düğmenin penceresi — oraya tıklamak "dışarı tıklama"
    /// sayılmamalı, yoksa sağ tık menüyü kapatıp hemen yeniden açar.
    var anchorWindow: NSWindow?
    var onClose: (() -> Void)?

    init(builder: @escaping () -> [Element], level: @escaping () -> CGFloat) {
        menuView = StatusMenuView(builder: builder, level: level)
        let size = NSSize(width: Self.width, height: menuView.contentHeight())
        menuView.frame = NSRect(origin: .zero, size: size)

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        self.level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        acceptsMouseMovedEvents = true
        // Panel her zaman koyu: sistem renkleri (systemGreen vb.) koyu
        // varyantlarıyla çözülsün.
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient]
        contentView = menuView

        menuView.onDismiss = { [weak self] in self?.dismiss() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }   // Esc ve ⌘ kısayolları için

    /// Durum değiştiğinde (kayıt başladı, izin verildi...) açık menü canlı güncellensin.
    func reload() { menuView.reload() }

    /// `anchor` ekran koordinatında menü çubuğu düğmesinin çerçevesi —
    /// panel onun hemen altına, sol kenarı hizalı açılıyor.
    func show(below anchor: NSRect) {
        let height = menuView.contentHeight()
        var origin = NSPoint(x: anchor.minX - 6, y: anchor.minY - 4 - height)
        if let visible = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - Self.width - 4)
            origin.y = max(origin.y, visible.minY + 4)
        }
        let final = NSRect(origin: origin, size: NSSize(width: Self.width, height: height))

        // Açılış: hafifçe yukarıdan düşer + belirir (tasarımdaki menuIn).
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        setFrame(reduce ? final : final.offsetBy(dx: 0, dy: 6), display: true)
        alphaValue = reduce ? 1 : 0
        orderFrontRegardless()
        makeKey()
        if !reduce {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                animator().alphaValue = 1
                animator().setFrame(final, display: true)
            }
        }

        // Başka uygulamaya tıklama: global. Kendi pencerelerimize (kart)
        // tıklama: local — ikisi de menüyü kapatmalı.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self, event.window !== self.anchorWindow { self.dismiss() }
            return event
        }

        lastTick = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(0.05, now - lastTick)
        lastTick = now
        menuView.step(dt)

        // Grup açılıp kapanırken yükseklik değişiyor: üst kenar SABİT kalsın
        // (menü çubuğundan sarkıyor), alt kenar hareket etsin.
        let height = menuView.contentHeight()
        if abs(height - frame.height) > 0.5 {
            let top = frame.maxY
            setFrame(NSRect(x: frame.minX, y: top - height, width: Self.width, height: height), display: true)
            menuView.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
            invalidateShadow()
        }
        menuView.needsDisplay = true
    }

    func dismiss() {
        guard !closing else { return }
        closing = true
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        localClickMonitor = nil

        let finish = { [weak self] in
            guard let self else { return }
            self.ticker?.invalidate()
            self.ticker = nil
            self.orderOut(nil)
            self.onClose?()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                animator().alphaValue = 0
            }, completionHandler: { MainActor.assumeIsolated { finish() } })
        }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }   // Esc

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let key = event.charactersIgnoringModifiers?.uppercased(),
           menuView.performShortcut("⌘" + key) {
            return
        }
        super.keyDown(with: event)
    }

    /// Geliştirme yardımcısı: menüyü ekran/izin olmadan PNG'ye çizer
    /// (`Katip --rendermenu <dizin>`), `HUDPanel.renderSample` ile aynı gerekçe.
    static func renderSample(_ elements: [Element], expanded: String? = nil,
                             time: CFTimeInterval = 0.4, level: CGFloat = 0.5, to path: String) {
        let view = StatusMenuView(builder: { elements }, level: { level })
        view.snapshotSetup(expanded: expanded, time: time)
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.contentHeight())
        view.appearance = NSAppearance(named: .darkAqua)
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

// MARK: - Çizim

@MainActor
private final class StatusMenuView: NSView {
    typealias Element = StatusMenu.Element
    typealias Row = StatusMenu.Row

    private let builder: () -> [Element]
    private let level: () -> CGFloat
    private var elements: [Element]
    var onDismiss: (() -> Void)?

    /// Açık olan tek grup (akordeon) — aynı anda iki liste açılıp menü
    /// ekranı taşmasın.
    private var expanded: String?
    private var hovered: String?
    private var anim: [String: CGFloat] = [:]
    private var time: CFTimeInterval = 0
    private var smoothedLevel: CGFloat = 0
    private var hits: [(rect: NSRect, row: Row)] = []
    private var tracking: NSTrackingArea?
    private var symbolCache: [String: NSImage] = [:]
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    // Ölçüler — tasarımdaki px değerleriyle birebir.
    private let pad: CGFloat = 6
    private let rowHeight: CGFloat = 30
    private let tallRowHeight: CGFloat = 40
    private let subRowHeight: CGFloat = 28
    private let subTallRowHeight: CGFloat = 38
    private let sectionHeight: CGFloat = 25
    private let separatorHeight: CGFloat = 11
    private let subIndent: CGFloat = 16

    // Renkler — Palette'le aynı aile, tasarımdaki opaklıklar.
    private let textPrimary = NSColor(white: 1, alpha: 0.92)
    private let textSecondary = NSColor(white: 1, alpha: 0.55)
    private let textTertiary = NSColor(white: 1, alpha: 0.5)
    private let iconColor = NSColor(white: 1, alpha: 0.66)
    private let hairline = NSColor(white: 1, alpha: 0.08)
    private let linkColor = NSColor(srgbRed: 0.39, green: 0.71, blue: 1, alpha: 1)
    private let warningText = NSColor(srgbRed: 1, green: 0.70, blue: 0.25, alpha: 1)
    private let dangerText = NSColor(srgbRed: 1, green: 0.42, blue: 0.38, alpha: 1)
    private let primaryText = NSColor(srgbRed: 0.62, green: 0.82, blue: 1, alpha: 1)

    init(builder: @escaping () -> [Element], level: @escaping () -> CGFloat) {
        self.builder = builder
        self.level = level
        self.elements = builder()
        super.init(frame: .zero)
        wantsLayer = true
        seedAnimations()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func reload() {
        elements = builder()
        needsDisplay = true
    }

    func snapshotSetup(expanded: String?, time: CFTimeInterval) {
        self.expanded = expanded
        self.time = time
        smoothedLevel = min(1, level() * 6)   // step()'teki ölçekle aynı
        if let expanded { anim["g:" + expanded] = 1 }
    }

    /// Anahtarlar menü açılırken animasyonsuz doğru yerde başlasın.
    private func seedAnimations() {
        for row in allRows() {
            if case .toggle(let on) = row.accessory { anim["t:" + row.id] = on ? 1 : 0 }
        }
    }

    private func allRows() -> [Row] {
        elements.flatMap { element -> [Row] in
            switch element {
            case .row(let row): [row]
            case .group(_, let rows): rows
            default: []
            }
        }
    }

    // MARK: Animasyon

    func step(_ dt: CFTimeInterval) {
        time += dt
        let raw = min(1, level() * 6)
        smoothedLevel += (raw - smoothedLevel) * 0.3

        func ease(_ key: String, to target: CGFloat, rate: CGFloat) {
            let current = anim[key] ?? target
            anim[key] = reduceMotion ? target
                : current + (target - current) * (1 - exp(-rate * CGFloat(dt)))
        }
        for element in elements {
            if case .group(let id, _) = element { ease("g:" + id, to: expanded == id ? 1 : 0, rate: 16) }
        }
        for row in allRows() {
            if case .toggle(let on) = row.accessory { ease("t:" + row.id, to: on ? 1 : 0, rate: 20) }
            ease("h:" + row.id, to: hovered == row.id ? 1 : 0, rate: 30)
        }
    }

    // MARK: Yerleşim

    private func height(of row: Row, sub: Bool) -> CGFloat {
        if sub { return row.caption == nil ? subRowHeight : subTallRowHeight }
        return row.caption == nil ? rowHeight : tallRowHeight
    }

    private func headerHeight(_ header: StatusMenu.Header) -> CGFloat {
        var h: CGFloat = 10 + 18 + 8
        if header.progress != nil { h += 4 + 9 }
        if case .none = header.hint {} else { h += 9 + 18 }
        return h
    }

    func contentHeight() -> CGFloat {
        var y = pad
        for element in elements {
            switch element {
            case .header(let header): y += headerHeight(header)
            case .separator: y += separatorHeight
            case .section: y += sectionHeight
            case .row(let row): y += height(of: row, sub: false)
            case .group(let id, let rows):
                let full = rows.reduce(0) { $0 + height(of: $1, sub: true) }
                y += full * (anim["g:" + id] ?? 0)
            }
        }
        return ceil(y + pad)
    }

    // MARK: Çizim

    override func draw(_ dirtyRect: NSRect) {
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 14, yRadius: 14)
        Palette.surface.setFill()
        panel.fill()
        hairline.setStroke()
        panel.lineWidth = 1
        panel.stroke()

        hits.removeAll()
        var y = pad
        let x = pad
        let w = bounds.width - 2 * pad

        for element in elements {
            switch element {
            case .header(let header):
                let h = headerHeight(header)
                drawHeader(header, in: NSRect(x: x, y: y, width: w, height: h))
                y += h

            case .separator:
                hairline.setFill()
                NSRect(x: x + 10, y: y + 5, width: w - 20, height: 1).fill()
                y += separatorHeight

            case .section(let title):
                text(title, 11, .medium, textTertiary).draw(at: NSPoint(x: x + 10, y: y + 8))
                y += sectionHeight

            case .row(let row):
                let rect = NSRect(x: x, y: y, width: w, height: height(of: row, sub: false))
                drawRow(row, in: rect, indent: 0)
                if row.action != nil || row.expands != nil { hits.append((rect, row)) }
                y += rect.height

            case .group(let id, let rows):
                let factor = anim["g:" + id] ?? 0
                let full = rows.reduce(0) { $0 + height(of: $1, sub: true) }
                let visible = full * factor
                guard visible > 0.5 else { continue }
                let clip = NSRect(x: x, y: y, width: w, height: visible)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: clip).addClip()
                NSGraphicsContext.current?.cgContext.setAlpha(min(1, factor * 1.4))
                var ry = y
                for row in rows {
                    let rect = NSRect(x: x, y: ry, width: w, height: height(of: row, sub: true))
                    drawRow(row, in: rect, indent: subIndent)
                    if factor > 0.98, row.action != nil { hits.append((rect, row)) }
                    ry += rect.height
                }
                NSGraphicsContext.restoreGraphicsState()
                y += visible
            }
        }
    }

    // MARK: Başlık

    private func drawHeader(_ header: StatusMenu.Header, in rect: NSRect) {
        let left = rect.minX + 10
        let topCenter = rect.minY + 10 + 9

        // Logo: üç çubuk + imleç. Kayıtta çubuklar canlı ses göstergesine dönüşüyor.
        let live: NSColor? = switch header.status {
        case .recording: .systemRed
        case .locked: .systemOrange
        default: nil
        }
        let dim: Bool = switch header.status {
        case .transcribing, .loading, .downloading: true
        default: false
        }
        drawLogo(origin: NSPoint(x: left, y: topCenter - 9), live: live, dim: dim)

        let title = text("Katip", 13, .semibold, NSColor(white: 1, alpha: 0.96))
        let titleSize = title.size()
        title.draw(at: NSPoint(x: left + 26, y: topCenter - titleSize.height / 2))
        let version = NSAttributedString(string: header.version, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(white: 1, alpha: 0.52)])
        let versionSize = version.size()
        version.draw(at: NSPoint(x: left + 26 + titleSize.width + 6, y: topCenter - versionSize.height / 2 + 0.5))

        drawChip(header.status, rightEdge: rect.maxX - 10, centerY: topCenter)

        var y = rect.minY + 10 + 18
        if let progress = header.progress {
            y += 9
            let track = NSRect(x: left, y: y, width: rect.width - 20, height: 4)
            NSColor(white: 1, alpha: 0.1).setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            NSColor.systemBlue.setFill()
            var fill = track
            fill.size.width = max(4, track.width * CGFloat(min(1, max(0, progress))))
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            y += 4
        }
        if case .none = header.hint { return }
        drawHint(header.hint, x: left, centerY: y + 9 + 9, maxX: rect.maxX - 10)
    }

    private func drawLogo(origin: NSPoint, live: NSColor?, dim: Bool) {
        let color = live ?? NSColor(white: 1, alpha: dim ? 0.5 : 1)
        color.setFill()
        let bars: [(x: CGFloat, h: CGFloat)] = [(1.5, 6), (5.5, 12), (9.5, 8)]
        for (index, bar) in bars.enumerated() {
            var h = bar.h
            if live != nil {
                let wave = 0.6 + 0.4 * sin(time * 9 - Double(index) * 1.9)
                let amp = reduceMotion ? 0.7 : max(0.25, smoothedLevel)
                h = max(2.4, bar.h * (0.3 + 0.7 * amp * CGFloat(wave)))
            }
            NSBezierPath(roundedRect: NSRect(x: origin.x + bar.x, y: origin.y + 9 - h / 2, width: 2.4, height: h),
                         xRadius: 1.2, yRadius: 1.2).fill()
        }
        if live == nil {
            color.withAlphaComponent(color.alphaComponent * 0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.x + 14.2, y: origin.y + 2.5, width: 1.6, height: 13),
                         xRadius: 0.8, yRadius: 0.8).fill()
        }
    }

    private func drawChip(_ status: StatusMenu.Status, rightEdge: CGFloat, centerY: CGFloat) {
        let label: String
        let background: NSColor
        let foreground: NSColor
        enum Indicator { case dot(NSColor, pulse: Bool), spinner, symbol(String, NSColor), none }
        let indicator: Indicator
        switch status {
        case .ready:
            (label, background, foreground) = ("Hazır", NSColor(white: 1, alpha: 0.06), NSColor(white: 1, alpha: 0.8))
            indicator = .dot(.systemGreen, pulse: true)
        case .permissions(let count):
            (label, background, foreground) = ("\(count) izin gerekli", NSColor.systemOrange.withAlphaComponent(0.14), warningText)
            indicator = .dot(.systemOrange, pulse: true)
        case .recording:
            (label, background, foreground) = ("Dinliyor", NSColor.systemRed.withAlphaComponent(0.14), dangerText)
            indicator = .dot(.systemRed, pulse: true)
        case .locked:
            (label, background, foreground) = ("Kilitli", NSColor.systemOrange.withAlphaComponent(0.14), warningText)
            indicator = .symbol("lock.fill", warningText)
        case .transcribing:
            (label, background, foreground) = ("Yazıya çevriliyor", NSColor(white: 1, alpha: 0.06), NSColor(white: 1, alpha: 0.82))
            indicator = .spinner
        case .loading:
            (label, background, foreground) = ("Model yükleniyor", NSColor(white: 1, alpha: 0.06), NSColor(white: 1, alpha: 0.82))
            indicator = .spinner
        case .downloading(let progress):
            (label, background, foreground) = ("Model iniyor · %\(Int((progress * 100).rounded()))",
                                               NSColor(white: 1, alpha: 0.06), NSColor(white: 1, alpha: 0.82))
            indicator = .none
        case .error:
            (label, background, foreground) = ("Hata", NSColor.systemRed.withAlphaComponent(0.14), dangerText)
            indicator = .symbol("exclamationmark.triangle.fill", dangerText)
        }

        let attributed = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: foreground])
        let textSize = attributed.size()
        let indicatorWidth: CGFloat = if case .none = indicator { 0 } else { 10 }
        let gap: CGFloat = indicatorWidth > 0 ? 6 : 0
        let chipWidth = 8 + indicatorWidth + gap + textSize.width + 8
        let chip = NSRect(x: rightEdge - chipWidth, y: centerY - 10, width: chipWidth, height: 20)
        background.setFill()
        NSBezierPath(roundedRect: chip, xRadius: 10, yRadius: 10).fill()

        let center = NSPoint(x: chip.minX + 8 + 5, y: centerY)
        switch indicator {
        case .dot(let color, let pulse):
            if pulse, !reduceMotion {
                let phase = CGFloat((time.truncatingRemainder(dividingBy: 2.0)) / 2.0)
                let radius = 3.5 + 5 * phase
                color.withAlphaComponent(0.45 * (1 - phase)).setFill()
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)).fill()
        case .spinner:
            let start = CGFloat(reduceMotion ? 0 : (time * 400).truncatingRemainder(dividingBy: 360))
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: 4.2, startAngle: start, endAngle: start + 270, clockwise: false)
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            foreground.setStroke()
            arc.stroke()
        case .symbol(let name, let color):
            drawSymbol(name, center: center, points: 8.5, weight: .semibold, color: color)
        case .none:
            break
        }
        attributed.draw(at: NSPoint(x: chip.minX + 8 + indicatorWidth + gap, y: centerY - textSize.height / 2))
    }

    private func drawHint(_ hint: StatusMenu.Hint, x: CGFloat, centerY: CGFloat, maxX: CGFloat) {
        var cursor = x
        func key(_ glyph: String) {
            let label = text(glyph, 11, .medium, NSColor(white: 1, alpha: 0.88))
            let size = label.size()
            let box = NSRect(x: cursor, y: centerY - 9, width: max(18, size.width + 8), height: 18)
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            NSColor(white: 1, alpha: 0.09).setFill(); path.fill()
            NSColor(white: 1, alpha: 0.14).setStroke(); path.lineWidth = 1; path.stroke()
            label.draw(at: NSPoint(x: box.midX - size.width / 2, y: centerY - size.height / 2))
            cursor = box.maxX + 2
        }
        func words(_ string: String) {
            cursor += 4
            let label = text(string, 11, .regular, textSecondary)
            let size = label.size()
            label.draw(at: NSPoint(x: cursor, y: centerY - size.height / 2))
            cursor += size.width
        }
        switch hint {
        case .idle(let glyph):
            key(glyph); words("basılı tut · konuş")
            cursor += 9
            NSColor(white: 1, alpha: 0.3).setFill()
            NSBezierPath(ovalIn: NSRect(x: cursor - 1.5, y: centerY - 1.5, width: 3, height: 3)).fill()
            cursor += 8
            key(glyph); key(glyph); words("çift bas · kilitle")
        case .recording(let glyph):
            key(glyph); words("bırak ya da tıkla · yazıya çevir")
        case .locked(let glyph):
            key(glyph); words("bas · bitir ve yaz")
        case .text(let string):
            let label = text(string, 11, .regular, textSecondary, truncating: true)
            label.draw(with: NSRect(x: x, y: centerY - 7, width: maxX - x, height: 14),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        case .none:
            break
        }
    }

    // MARK: Satır

    private func drawRow(_ row: Row, in rect: NSRect, indent: CGFloat) {
        let hover = anim["h:" + row.id] ?? 0
        let interactive = row.action != nil || row.expands != nil
        // İç grup satırlarının vurgusu da girintiden başlıyor (tasarımda
        // grup kabı 16 pt içeride).
        var pill = rect.insetBy(dx: 0, dy: row.tone == .primary ? 2 : 0)
        pill.origin.x += indent
        pill.size.width -= indent
        if row.tone == .primary {
            NSColor.systemBlue.withAlphaComponent(0.16 + 0.1 * hover).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        } else if interactive, hover > 0.01 {
            NSColor(white: 1, alpha: 0.08 * hover).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8).fill()
        }

        var x = rect.minX + 10 + indent
        if let symbol = row.symbol {
            let tint: NSColor = switch row.tone {
            case .warning: warningText
            case .danger: dangerText
            case .primary: linkColor
            case .dim: NSColor(white: 1, alpha: 0.3)
            default: iconColor
            }
            // Yeniden başlat ikonu fare üstündeyken yarım tur döner (tasarımdaki ipucu).
            let spin = row.tone == .primary ? -200 * hover : 0
            drawSymbol(symbol, center: NSPoint(x: x + 8, y: rect.midY), points: 12.5, weight: .regular,
                       color: tint, rotation: spin)
            x += 16 + 10
        } else if indent > 0 {
            x += 10   // ikonsuz alt satır (dil, kısayol) üst satırın başlığıyla hizalansın
        }

        let accessoryMinX = drawAccessory(row, in: rect, hover: hover)

        let titleColor: NSColor = switch row.tone {
        case .primary: primaryText
        case .soft: NSColor(white: 1, alpha: 0.8)
        case .dim: NSColor(white: 1, alpha: 0.35)
        default: indent > 0 ? NSColor(white: 1, alpha: 0.84) : textPrimary
        }
        let available = max(20, accessoryMinX - 8 - x)
        let title = text(row.title, 13, .regular, titleColor, truncating: true)
        if let caption = row.caption {
            title.draw(with: NSRect(x: x, y: rect.midY - 16, width: available, height: 17),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            let captionColor = row.tone == .primary ? primaryText.withAlphaComponent(0.72) : NSColor(white: 1, alpha: 0.52)
            text(caption, 11, .regular, captionColor, truncating: true)
                .draw(with: NSRect(x: x, y: rect.midY + 1.5, width: available, height: 14),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        } else {
            title.draw(with: NSRect(x: x, y: rect.midY - 8.5, width: available, height: 17),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// Sağdaki aksesuarı çizer, başlığın taşmaması için sol kenarını döndürür.
    private func drawAccessory(_ row: Row, in rect: NSRect, hover: CGFloat) -> CGFloat {
        let right = rect.maxX - 10
        switch row.accessory {
        case .none:
            return right

        case .shortcut(let keys):
            let label = text(keys, 12, .regular, textTertiary)
            let size = label.size()
            label.draw(at: NSPoint(x: right - size.width, y: rect.midY - size.height / 2))
            return right - size.width

        case .disclosure(let value):
            let open = row.expands.map { anim["g:" + $0] ?? 0 } ?? 0
            drawSymbol("chevron.right", center: NSPoint(x: right - 5, y: rect.midY), points: 9, weight: .semibold,
                       color: NSColor(white: 1, alpha: 0.45), rotation: 90 * open)
            var minX = right - 12
            if let value {
                let label = text(value, 12, .regular, textSecondary)
                let size = label.size()
                minX -= 6 + size.width
                label.draw(at: NSPoint(x: minX, y: rect.midY - size.height / 2))
            }
            return minX

        case .toggle:
            let t = anim["t:" + row.id] ?? 0
            let track = NSRect(x: right - 26, y: rect.midY - 8, width: 26, height: 16)
            let off = NSColor(white: 1, alpha: 0.18).usingColorSpace(.sRGB)!
            let on = NSColor.systemBlue.usingColorSpace(.sRGB)!
            (off.blended(withFraction: t, of: on) ?? on).setFill()
            NSBezierPath(roundedRect: track, xRadius: 8, yRadius: 8).fill()
            let knob = NSRect(x: track.minX + 2 + 10 * t, y: track.minY + 2, width: 12, height: 12)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
            shadow.shadowBlurRadius = 2
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
            NSGraphicsContext.restoreGraphicsState()
            return track.minX

        case .check(let on):
            if on {
                drawSymbol("checkmark", center: NSPoint(x: right - 6, y: rect.midY), points: 11, weight: .semibold,
                           color: textPrimary)
            }
            return right - 14

        case .link(let label):
            drawSymbol("arrow.up.right", center: NSPoint(x: right - 4, y: rect.midY), points: 8, weight: .semibold,
                       color: linkColor)
            let attributed = text(label, 12, .regular, linkColor)
            let size = attributed.size()
            attributed.draw(at: NSPoint(x: right - 11 - size.width, y: rect.midY - size.height / 2))
            return right - 11 - size.width

        case .pill(let label, let color):
            let attributed = text(label, 11, .regular, color)
            let size = attributed.size()
            let box = NSRect(x: right - size.width - 16, y: rect.midY - 9, width: size.width + 16, height: 18)
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
            attributed.draw(at: NSPoint(x: box.minX + 8, y: rect.midY - size.height / 2))
            return box.minX

        case .badges(let symbols):
            var minX = right
            for symbol in symbols.reversed() {
                let circle = NSRect(x: minX - 18, y: rect.midY - 9, width: 18, height: 18)
                NSColor.systemGreen.withAlphaComponent(0.16).setFill()
                NSBezierPath(ovalIn: circle).fill()
                drawSymbol(symbol, center: NSPoint(x: circle.midX, y: circle.midY), points: 8.5, weight: .medium,
                           color: .systemGreen)
                minX = circle.minX - 4
            }
            return minX

        case .hoverSymbol(let name):
            if hover > 0.01 {
                drawSymbol(name, center: NSPoint(x: right - 8, y: rect.midY), points: 11.5, weight: .regular,
                           color: iconColor.withAlphaComponent(0.66 * hover))
            }
            return right - 16
        }
    }

    // MARK: Yardımcılar

    private func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
                      truncating: Bool = false) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncating ? .byTruncatingTail : .byClipping
        return NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style])
    }

    /// SF Symbol'ü istenen renge boyar ve (isteğe bağlı) döndürerek çizer.
    /// Boyanmış görüntüler önbellekte — menü 60 fps'te yeniden çiziliyor.
    private func drawSymbol(_ name: String, center: NSPoint, points: CGFloat, weight: NSFont.Weight,
                            color: NSColor, rotation: CGFloat = 0) {
        let key = "\(name)|\(points)|\(weight.rawValue)|\(color)"
        let image: NSImage
        if let cached = symbolCache[key] {
            image = cached
        } else {
            let config = NSImage.SymbolConfiguration(pointSize: points, weight: weight)
            guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            image = NSImage(size: base.size, flipped: false) { r in
                base.draw(in: r)
                color.set()
                r.fill(using: .sourceAtop)
                return true
            }
            symbolCache[key] = image
        }
        let size = image.size
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: center.x, yBy: center.y)
        if rotation != 0 { transform.rotate(byDegrees: rotation) }
        transform.concat()
        image.draw(in: NSRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Etkileşim

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hovered = hits.first { $0.rect.contains(point) }?.row.id
    }

    override func mouseExited(with event: NSEvent) { hovered = nil }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = hits.first(where: { $0.rect.contains(point) })?.row else { return }
        perform(row)
    }

    private func perform(_ row: Row) {
        if let group = row.expands {
            expanded = expanded == group ? nil : group
            needsDisplay = true
            return
        }
        guard let action = row.action else { return }
        if row.closes {
            onDismiss?()
            action()
        } else {
            action()
            reload()
        }
    }

    func performShortcut(_ keys: String) -> Bool {
        guard let row = allRows().first(where: {
            if case .shortcut(let s) = $0.accessory { return s == keys }
            return false
        }) else { return false }
        perform(row)
        return true
    }

    // MARK: Erişilebilirlik — çizilmiş satırlar VoiceOver'a menü öğesi olarak

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityRole() -> NSAccessibility.Role? { .menu }

    override func accessibilityChildren() -> [Any]? {
        hits.map { hit in
            let element = RowAccessibility(perform: { [weak self] in self?.perform(hit.row) })
            element.setAccessibilityRole(.menuItem)
            element.setAccessibilityLabel([hit.row.title, hit.row.caption].compactMap { $0 }.joined(separator: ", "))
            if case .toggle(let on) = hit.row.accessory { element.setAccessibilityValue(on ? "açık" : "kapalı") }
            if case .check(let on) = hit.row.accessory { element.setAccessibilityValue(on ? "seçili" : "") }
            element.setAccessibilityFrameInParentSpace(NSRect(x: hit.rect.minX, y: bounds.height - hit.rect.maxY,
                                                               width: hit.rect.width, height: hit.rect.height))
            element.setAccessibilityParent(self)
            return element
        }
    }
}

private final class RowAccessibility: NSAccessibilityElement {
    private let performAction: () -> Void
    init(perform: @escaping () -> Void) { performAction = perform; super.init() }
    override func accessibilityPerformPress() -> Bool { performAction(); return true }
}
