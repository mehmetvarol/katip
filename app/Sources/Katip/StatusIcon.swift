import AppKit

/// Menü çubuğu ikonları — her durum KENDİ hareketiyle, bakmadan anlaşılsın
/// (tasarım: "İkon ve başlık durumları" artboard'u).
///
/// Neden SF Symbol yerine kendi çizimimiz: kayıttaki mikrofonun gövdesi
/// GERÇEK ses seviyesiyle doluyor, çeviri çubukları sırayla akıyor, indirme
/// halkası yüzdeyle doluyor — bunlar kare kare değişen şekiller, sabit bir
/// sembolle ifade edilemiyor. Koordinatlar tasarımdaki 16'lık viewBox'la
/// birebir; 18 pt'lik menü çubuğu ikonuna ölçekleniyor.
enum StatusIcon {
    static let size = NSSize(width: 18, height: 18)
    private static let scale: CGFloat = 18.0 / 16.0

    /// Kayıt: mikrofonun gövdesi ses seviyesiyle alttan dolar. Renk BİLEREK
    /// gömülü (template değil) — kırmızı/turuncu, menü çubuğu temasından
    /// bağımsız "kayıtta" sinyali. `contentTintColor` bu tür görüntülerde
    /// uygulanmıyordu (v0.2.17'de gerçek kullanımda görüldü).
    static func recording(level: CGFloat, color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            let ctx = NSAffineTransform(); ctx.scale(by: scale); ctx.concat()
            color.setStroke(); color.setFill()

            let body = NSBezierPath(roundedRect: NSRect(x: 6, y: 1.8, width: 4, height: 8.2),
                                    xRadius: 2, yRadius: 2)
            // Tamamen boşken bile bir parmak dolu kalsın — "açık" olduğu belli olsun.
            let fill = max(0.18, min(1, level))
            NSGraphicsContext.saveGraphicsState()
            body.addClip()
            NSRect(x: 6, y: 1.8 + 8.2 * (1 - fill), width: 4, height: 8.2 * fill).fill()
            NSGraphicsContext.restoreGraphicsState()

            body.lineWidth = 1.5
            body.stroke()
            strokeHolder()
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Çeviri: üç çubuk sırayla kabarır. Template — sistemin menü çubuğu
    /// rengine (açık/koyu) kendisi uyar.
    static func transcribing(time: CFTimeInterval) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            let ctx = NSAffineTransform(); ctx.scale(by: scale); ctx.concat()
            NSColor.black.setFill()
            let bars: [(x: CGFloat, h: CGFloat)] = [(2.5, 8), (6.8, 12), (11.1, 8)]
            for (index, bar) in bars.enumerated() {
                let wave = 0.5 + 0.5 * sin(time * 7.0 - Double(index) * 2.1)
                let h = bar.h * CGFloat(0.35 + 0.65 * wave)
                NSBezierPath(roundedRect: NSRect(x: bar.x, y: 8 - h / 2, width: 2.4, height: h),
                             xRadius: 1.2, yRadius: 1.2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// İndirme: halka gerçek yüzdeyle dolar, ortada aşağı ok. Template.
    static func downloading(progress: Double) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            let ctx = NSAffineTransform(); ctx.scale(by: scale); ctx.concat()
            let center = NSPoint(x: 8, y: 8)

            let track = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12))
            track.lineWidth = 1.6
            NSColor.black.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            // Flipped koordinatta -90° TEPE; saat yönünde doluyor.
            arc.appendArc(withCenter: center, radius: 6, startAngle: -90,
                          endAngle: -90 + 360 * CGFloat(max(0.02, min(1, progress))), clockwise: false)
            arc.lineWidth = 1.6
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()

            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: 8, y: 5.2)); arrow.line(to: NSPoint(x: 8, y: 10.2))
            arrow.move(to: NSPoint(x: 6, y: 8.3)); arrow.line(to: NSPoint(x: 8, y: 10.3))
            arrow.line(to: NSPoint(x: 10, y: 8.3))
            arrow.lineWidth = 1.4
            arrow.lineCapStyle = .round
            arrow.lineJoinStyle = .round
            arrow.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Mikrofonun sapı: gövdenin altındaki yay + ayak.
    private static func strokeHolder() {
        let holder = NSBezierPath()
        // Flipped'da 90° AŞAĞI bakar: 180° → 0° saat yönünde yayı alttan geçirir.
        holder.appendArc(withCenter: NSPoint(x: 8, y: 7.8), radius: 4.5,
                         startAngle: 180, endAngle: 0, clockwise: true)
        holder.move(to: NSPoint(x: 8, y: 12.3)); holder.line(to: NSPoint(x: 8, y: 14.2))
        holder.lineWidth = 1.5
        holder.lineCapStyle = .round
        holder.stroke()
    }
}
