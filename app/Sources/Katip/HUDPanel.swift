import AppKit

/// Masaüstünde yüzen kapsül göstergesi (Wispr Flow'un "Flow Bar"ı gibi).
///
/// Tasarım: boştayken dar, konuşurken genişler. İçinde durum ikonu + ses dalgası.
/// Kenara sürüklenince yapışır ve konumu hatırlanır.
///
/// **En kritik kural: odağı ASLA çalmamalı.** `.nonactivatingPanel` olmadan kapsül
/// göründüğü an yazdığın uygulama imleç konumunu kaybeder, metin yanlış yere gider.
@MainActor
final class HUDPanel: NSPanel {
    private let capsule = CapsuleView()

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "hudEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "hudEnabled") }
    }

    static let height: CGFloat = 32
    static let idleWidth: CGFloat = 84
    static let activeWidth: CGFloat = 148

    /// Kenara yapışma: bu mesafeye kadar yaklaşınca yapışır.
    private static let snapDistance: CGFloat = 140
    private static let snapMargin: CGFloat = 14

    var onClick: (() -> Void)?
    private var currentWidth: CGFloat = HUDPanel.idleWidth

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: HUDPanel.idleWidth, height: HUDPanel.height),
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
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        capsule.onClick = { [weak self] in self?.onClick?() }
        contentView = capsule

        restorePosition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show() { orderFrontRegardless() }

    func update(state: DictationController.State, level: Float) {
        capsule.apply(state: state, level: level)
        resize(for: state)
    }

    var isSettled: Bool {
        capsule.isSettled && abs(currentWidth - Self.idleWidth) < 0.5
    }

    /// Genişliği yumuşat, MERKEZİ sabit tut — kapsül iki yana açılsın.
    /// Kenara yapışıksa o kenarda kalsın, taşmasın.
    private func resize(for state: DictationController.State) {
        let target: CGFloat
        switch state {
        case .recording, .locked, .transcribing: target = Self.activeWidth
        default: target = Self.idleWidth
        }
        guard abs(currentWidth - target) > 0.5 else { return }

        currentWidth += (target - currentWidth) * 0.35
        var x = frame.midX - currentWidth / 2
        let y = frame.minY

        if let visible = NSScreen.main?.visibleFrame {
            x = min(max(x, visible.minX + 4), visible.maxX - currentWidth - 4)
        }
        setFrame(NSRect(x: x, y: y, width: currentWidth, height: Self.height), display: true)
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

        // Ekran dışına taşmasın.
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
        origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrameOrigin(origin)
        }
    }

    // MARK: - Konum hatırlama (merkez — genişlik değiştiği için)

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
                                   y: visible.minY + Self.snapMargin))
        }
    }

    /// Geliştirme yardımcısı: kapsülü PNG'ye render eder.
    /// Ekran görüntüsü izni olmadan görünümü doğrulamak için.
    static func renderSample(state: DictationController.State,
                             levels: [CGFloat],
                             to path: String) {
        let width = state == .idle ? idleWidth : activeWidth
        let view = CapsuleView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.debugLevels = levels
        view.apply(state: state, level: 0)

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        snapToNearestEdge()
        savePosition()
    }
}

// MARK: - Kapsül görünümü

@MainActor
private final class CapsuleView: NSView {
    var onClick: (() -> Void)?

    private var state: DictationController.State = .loadingModel
    private var levels: [CGFloat] = Array(repeating: 0.06, count: 14)
    private var phase: CGFloat = 0
    private var dragOrigin: NSPoint?

    private static let floor: CGFloat = 0.06
    private(set) var isSettled = false
    var debugLevels: [CGFloat]?

    private let blur = NSVisualEffectView()
    private let painter = PainterView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // `.popover` açık/koyu temaya göre uyarlanır; `.hudWindow` her zaman koyudur.
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = HUDPanel.height / 2
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]
        blur.frame = bounds
        addSubview(blur)

        // AppKit'te bir view'ın kendi draw()'u alt view'lardan ÖNCE çizilir.
        // İkon/çubukları burada çizersek blur onları tamamen örter (bir kez düştük:
        // kapsül bomboş görünüyordu). Bu yüzden çizim blur'un ÜSTÜNDE ayrı katmanda.
        painter.owner = self
        painter.autoresizingMask = [.width, .height]
        painter.frame = bounds
        addSubview(painter, positioned: .above, relativeTo: blur)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sistem teması değişince yeniden çiz — semantik renkler yeniden çözülsün.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        painter.needsDisplay = true
    }

    func apply(state: DictationController.State, level: Float) {
        self.state = state
        if let debugLevels { levels = debugLevels; painter.needsDisplay = true; return }

        switch state {
        case .recording, .locked:
            isSettled = false
            levels.removeFirst()
            levels.append(max(0.1, min(1, CGFloat(level) * 6)))
        case .transcribing:
            isSettled = false
            phase += 0.3
            for index in levels.indices {
                levels[index] = 0.18 + 0.45 * abs(sin(phase - CGFloat(index) * 0.45))
            }
        default:
            for index in levels.indices {
                levels[index] = max(Self.floor, levels[index] * 0.78)
            }
            isSettled = levels.allSatisfy { $0 <= Self.floor + 0.001 }
        }
        painter.needsDisplay = true
    }

    // MARK: - Çizim

    private var accent: NSColor {
        switch state {
        case .recording:    .systemRed
        case .locked:       .systemOrange
        case .transcribing: .systemBlue
        case .error:        .systemYellow
        case .loadingModel: .tertiaryLabelColor
        case .idle:         .secondaryLabelColor
        }
    }

    private var glyphName: String {
        switch state {
        case .loadingModel: "arrow.down.circle.fill"
        case .idle:         "mic.fill"
        case .recording:    "mic.fill"
        case .locked:       "lock.fill"
        case .transcribing: "waveform.circle.fill"
        case .error:        "exclamationmark.triangle.fill"
        }
    }

    fileprivate func render() {
        // Kenarlık: semantik renk → hem açık hem koyu temada doğru kontrast.
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.separatorColor.setStroke()
        border.lineWidth = 1
        border.stroke()

        let iconRight = drawGlyph()
        drawWaveform(from: iconRight)
    }

    /// Solda durum ikonu. Geriye çubukların başlayacağı x'i döner.
    private func drawGlyph() -> CGFloat {
        let left: CGFloat = 11
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        guard let base = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return left }

        // Şablon olarak boyayıp accent rengine çeviriyoruz.
        let image = NSImage(size: base.size, flipped: false) { rect in
            self.accent.set()
            base.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }

        let size = image.size
        let rect = NSRect(x: left, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        image.draw(in: rect)
        return rect.maxX + 8
    }

    /// Sağda ses dalgası. Boştayken çubuklar taban seviyesinde durur —
    /// sürekli animasyon boşta %9 CPU yakıyordu, o yüzden hareket sadece iş varken.
    private func drawWaveform(from startX: CGFloat) {
        let area = NSRect(x: startX, y: bounds.minY + 8,
                          width: bounds.maxX - startX - 12, height: bounds.height - 16)
        guard area.width > 10 else { return }

        // Sığan kadar çubuk çiz. Boştaki dar kapsüle 14 çubuk sığmıyor; sabit
        // sayıda çizersek kapsülün dışına taşarlar.
        let spacing: CGFloat = 2.5
        let minBar: CGFloat = 3
        let fits = Int((area.width + spacing) / (minBar + spacing))
        let count = max(3, min(levels.count, fits))
        let barWidth = (area.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let shown = levels.suffix(count)   // en yeni değerler

        let isActive: Bool
        switch state {
        case .recording, .locked, .transcribing: isActive = true
        default: isActive = false
        }
        // Boşta çubuklar soluk: kapsül "boş" görünmesin ama dikkat de çekmesin.
        (isActive ? accent : NSColor.quaternaryLabelColor).setFill()

        for (index, value) in shown.enumerated() {
            let height = max(2.5, value * area.height)
            let x = area.minX + CGFloat(index) * (barWidth + spacing)
            let rect = NSRect(x: x, y: bounds.midY - height / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    // MARK: - Üst çizim katmanı

    /// Blur'un üstünde duran şeffaf katman. Tüm ikon/dalga çizimi burada olur;
    /// tıklamaları yakalamaz, aşağıdaki kapsüle geçirir.
    @MainActor
    fileprivate final class PainterView: NSView {
        weak var owner: CapsuleView?
        override var isOpaque: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { owner?.render() }
    }

    // Sürükleme ile tıklamayı ayır.
    override func mouseDown(with event: NSEvent) {
        dragOrigin = window?.frame.origin
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { super.mouseUp(with: event) }
        guard let start = dragOrigin, let now = window?.frame.origin else { return }
        if hypot(now.x - start.x, now.y - start.y) < 4 { onClick?() }
    }
}
