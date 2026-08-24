import AppKit

/// Katip'in görsel dili — TEK kaynak. Kart (`HUDPanel`) ve karttan bağımsız
/// ama kartla aynı yüzeyde görünmesi gereken diğer pencereler (ör. dil
/// seçim menüsü) buradan çekiyor. İkisi kendi kopyasını tutsaydı, biri
/// güncellenip diğeri unutulduğunda sessizce birbirinden sapan iki "koyu
/// yüzey" ortaya çıkardı.
///
/// Referans koyu yüzeye SABİTLENMİŞ — sistemin açık/koyu temasından
/// bağımsız. Kart hep koyu, dolayısıyla ondan açılan her şey de hep koyu.
enum Palette {
    static let surface   = NSColor(white: 0.10, alpha: 0.94)
    static let control   = NSColor(white: 1.0, alpha: 0.13)
    static let controlUp = NSColor(white: 1.0, alpha: 0.22)   // fare üstündeyken
    static let primary   = NSColor(white: 1.0, alpha: 0.96)
    static let glyph     = NSColor(white: 1.0, alpha: 0.92)
    static let muted     = NSColor(white: 1.0, alpha: 0.42)
    static let wave      = NSColor(white: 1.0, alpha: 0.62)
}
