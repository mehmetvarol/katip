import CoreGraphics
import Foundation

/// Mikrofon seviyesini 0–1 arası bir "enerji"ye çeviren uyarlanır ölçer.
///
/// TEK kaynak: yüzen kartın dalgası (`HUDPanel`) ve menü çubuğu ikonunun
/// dolumu (`StatusIcon.recording`) aynı hesabı kullanıyor. İkisi ayrı ayrı
/// tutsaydı biri ayarlanıp diğeri unutulduğunda sessizce saparlardı —
/// kart konuşmaya tepki verirken ikon vermezdi (tam da bu yaşandı: ikon sabit
/// kazançla neredeyse boş kalıyordu, kullanıcı "kodlamadın" dedi).
///
/// UYARLANIR kazanç. Sabit kazanç çalışmıyor çünkü oturumlar arasında 3 KAT
/// fark var — gerçek kayıtlardan ölçüldü (tampon başına tepe, konuşma anları):
///
///     kısık oturum   p50 0.045   p90 0.067   max 0.095
///     yüksek oturum  p50 0.143   p90 0.235   max 0.438
///
/// Sabit kazançla kısık oturum kapının hemen üstünde kalıyor, gösterge konuşurken
/// bile dümdüz görünüyordu. Referans son saniyelerin tepesinden alınıyor:
/// mikrofon uzak da olsa yakın da olsa konuşma tam yüksekliğe çıkıyor.
struct LevelMeter {
    /// Referansın sönme hızı (1/sn). ~3 saniyede yarıya iner: konuşmanın
    /// tepesini hatırlayacak kadar uzun, sesini alçalttığında uyum sağlayacak
    /// kadar kısa.
    static let referenceDecay: CGFloat = 0.231

    /// Referansın alt sınırı. Bu olmasaydı tamamen sessiz bir odada uyarlanır
    /// kazanç mikrofon gürültüsünü tavana çıkarırdı.
    static let minimumReference: CGFloat = 0.05

    /// Bunun altı konuşma sayılmaz — `SpeechSegmenter.speechPeak` ile aynı
    /// değer. İki yer aynı eşiği kullanmalı: VAD'in "konuşma yok" dediği anda
    /// göstergenin kıpırdaması yalan olur. Sessizlikte gösterge BOŞ kalır.
    static let speechFloor: CGFloat = 0.03

    private(set) var energy: CGFloat = 0
    private var loudest: CGFloat = 0

    /// Konuşmanın alt yarısını yukarı çeken eğri (üs 1'in ALTINDA — 1.3
    /// denendi ve gerçek kısık konuşmayı dümdüz bıraktığı render'da görüldü).
    var punch: CGFloat { pow(energy, 0.7) }

    /// Ataklı zarf: sese HIZLI yüksel (20 ms), yavaş in (110 ms). Simetrik
    /// yumuşatma konuşmanın vuruşunu ezip göstergeyi cansız gösteriyordu.
    mutating func step(level: CGFloat, dt: CGFloat) {
        loudest = max(level, loudest * exp(-Self.referenceDecay * dt))
        let speaking = level > Self.speechFloor
        let reference = max(loudest, Self.minimumReference)
        let raw = speaking ? min(1, level / reference) : 0
        let tau: CGFloat = raw > energy ? 0.020 : 0.110
        energy += (raw - energy) * (1 - exp(-dt / tau))
    }

    /// Kayıt bitti: gösterge sıfırlanır, referans (son tepeler) korunur.
    mutating func reset() { energy = 0 }
}
