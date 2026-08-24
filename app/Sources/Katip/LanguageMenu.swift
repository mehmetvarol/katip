import AppKit

/// Dil seçim açılır paneli — native `NSMenu` DEĞİL.
///
/// Neden: `NSMenu` sistemin temasını alıyor, kart ise HER ZAMAN koyu
/// (`Palette`, açık/koyu temadan bağımsız). Native menüyü açınca kartın
/// yanında ışık rengi bir kutu beliriyordu — tasarım dili çatlıyordu.
///
/// Ayrıca `NSMenu` her tıklamada kapanıyor: çoklu seçimde her dil için
/// menüyü yeniden açman gerekirdi. Bu panel açık kalıyor, dışına
/// tıklayana veya Esc'e kadar — bir checklist gibi.
final class LanguageMenu: NSPanel {
    struct Row {
        var title: String
        var isChecked: Bool
        var isSeparatorAfter: Bool = false
    }

    fileprivate static let rowHeight: CGFloat = 26
    private static let width: CGFloat = 190
    fileprivate static let radius: CGFloat = 14

    private let listView: RowsView
    private var outsideClickMonitor: Any?
    var onSelect: ((Int) -> Void)?

    init(rows: [Row]) {
        let height = Self.contentHeight(for: rows)
        let size = NSSize(width: Self.width, height: height)
        listView = RowsView(rows: rows, frame: NSRect(origin: .zero, size: size))

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle]
        contentView = listView

        listView.onClick = { [weak self] index in self?.onSelect?(index) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var canBecomeKey: Bool { true }   // Esc'i alabilmek için

    func update(rows: [Row]) {
        listView.rows = rows
        setContentSize(NSSize(width: Self.width, height: Self.contentHeight(for: rows)))
    }

    private static func contentHeight(for rows: [Row]) -> CGFloat {
        let separators = rows.filter(\.isSeparatorAfter).count
        return CGFloat(rows.count) * rowHeight + CGFloat(separators) * 9 + 12
    }

    /// `point` ekran koordinatında, panelin SOL-ÜST köşesinin hedef nokta
    /// olmasını istiyoruz (tıklanan yerin hemen altına açılsın). Ekran
    /// kenarına taşarsa içeri kırpılıyor — `HUDPanel.resize`'daki kırpma
    /// mantığının aynısı.
    func show(near point: NSPoint) {
        var origin = NSPoint(x: point.x, y: point.y - frame.height)
        if let visible = NSScreen.main?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - frame.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - frame.height - 4)
        }
        setFrameOrigin(origin)
        orderFrontRegardless()
        makeKey()

        // Dışına tıklayınca kapanmasını GLOBAL bir event monitor sağlıyor —
        // panel `.nonactivatingPanel` olduğu için normal `resignKey` bunu
        // yakalamıyor.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    override func close() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
        super.close()
    }

    override func cancelOperation(_ sender: Any?) { close() }   // Esc

    override func resignKey() {
        super.resignKey()
        close()
    }

    /// Geliştirme yardımcısı: fare olmadan görünümü PNG'ye render eder.
    /// `HUDPanel.renderSample`'la aynı gerekçe — ekran görüntüsü izni
    /// olmadan çizimi gözle doğrulamanın tek yolu.
    static func renderSample(to path: String) {
        let rows = [
            Row(title: "Otomatik algıla", isChecked: false, isSeparatorAfter: true),
            Row(title: "Türkçe", isChecked: true),
            Row(title: "İngilizce", isChecked: true),
            Row(title: "Almanca", isChecked: false),
            Row(title: "Fransızca", isChecked: false),
        ]
        let height = contentHeight(for: rows)
        let view = RowsView(rows: rows, frame: NSRect(x: 0, y: 0, width: width, height: height))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// Satırları çizen görünüm. Kartın kendi çizim üslubuyla aynı: yuvarlak
/// yüzey, fare üstünde ince bir vurgu, seçili olan `Palette.primary`
/// tonunda bir onay işareti.
private final class RowsView: NSView {
    var rows: [LanguageMenu.Row] { didSet { needsDisplay = true } }
    var onClick: ((Int) -> Void)?
    private var hoveredIndex: Int?
    private var tracking: NSTrackingArea?

    init(rows: [LanguageMenu.Row], frame: NSRect) {
        self.rows = rows
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = rowIndex(at: point)
        guard index != hoveredIndex else { return }
        hoveredIndex = index
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point) else { return }
        onClick?(index)
    }

    /// Satır dikdörtgenlerini çizimle AYNI yerden hesaplıyoruz — `HUDPanel`
    /// çizim/tıklamayı ayrı hesaplarsa sessizce ayrışır diye bilerek tek
    /// fonksiyondan besliyor; burada da aynı disiplin.
    private func rowFrames() -> [(index: Int, rect: NSRect)] {
        var y = bounds.maxY - 6
        var out: [(Int, NSRect)] = []
        for (index, row) in rows.enumerated() {
            y -= LanguageMenu.rowHeight
            out.append((index, NSRect(x: 6, y: y, width: bounds.width - 12, height: LanguageMenu.rowHeight)))
            if row.isSeparatorAfter { y -= 9 }
        }
        return out
    }

    private func rowIndex(at point: NSPoint) -> Int? {
        rowFrames().first { $0.rect.contains(point) }?.index
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: LanguageMenu.radius, yRadius: LanguageMenu.radius).fill()

        for (index, rect) in rowFrames() {
            let row = rows[index]

            if index == hoveredIndex {
                Palette.control.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 1), xRadius: 6, yRadius: 6).fill()
            }

            let checkWidth: CGFloat = 22
            if row.isChecked {
                let mark = NSAttributedString(string: "✓", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: Palette.primary])
                let size = mark.size()
                mark.draw(at: NSPoint(x: rect.minX + 8, y: rect.midY - size.height / 2))
            }

            let label = NSAttributedString(string: row.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: Palette.glyph])
            let labelSize = label.size()
            label.draw(at: NSPoint(x: rect.minX + checkWidth, y: rect.midY - labelSize.height / 2))

            if row.isSeparatorAfter {
                Palette.muted.withAlphaComponent(0.18).setFill()
                let lineY = rect.minY - 5
                NSRect(x: rect.minX + 2, y: lineY, width: rect.width - 4, height: 1).fill()
            }
        }
    }
}
