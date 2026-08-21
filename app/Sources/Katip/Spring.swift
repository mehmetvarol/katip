import Foundation

/// Tek eksenli yay. Kartın hareketini sabit süreli eğrilerin yerine bu sürüyor.
///
/// Neden yay: sabit süreli bir animasyon (`NSAnimationContext` + `easeOut`)
/// yeni girdiye cevap veremez. Kullanıcı hareket hâlindeki kartı yakalayıp
/// ters yöne çekmek istediğinde eski animasyon ya bitmeyi bekletiyor ya da
/// zıplayarak kesiliyor. Yayın hedefi değiştirmek yeterli — değer ve hız
/// korunduğu için hareket sürekli kalıyor.
///
/// Parametreler fizik üçlüsü (kütle/sertlik/sönüm) yerine Apple'ın iki
/// tasarımcı-dostu değeri:
///
/// - `damping`: aşma miktarı. `1.0` = kritik sönüm, hiç zıplamaz.
///   `< 1.0` aşar ve salınır.
/// - `response`: hedefe varış hızı, saniye. SÜRE DEĞİL — yayın sabit bir
///   süresi yoktur, oturma zamanı parametrelerden çıkar.
struct Spring {
    var damping: CGFloat
    var response: TimeInterval

    var value: CGFloat
    var target: CGFloat
    var velocity: CGFloat = 0

    /// Yarım pikselin altına inen fark gözle görünmez; orada durup hedefe
    /// oturtuyoruz, yoksa yay sonsuza kadar mikroskobik adımlar atar.
    private static let settleDistance: CGFloat = 0.5
    private static let settleVelocity: CGFloat = 0.5

    var isSettled: Bool {
        abs(value - target) < Self.settleDistance && abs(velocity) < Self.settleVelocity
    }

    /// Sönümlü harmonik salınıcının KAPALI-FORM çözümü. Adım boyutundan
    /// bağımsız olarak kesin.
    ///
    /// Önce yarı-örtük Euler kullanıldı ve ÖLÇÜM ÇÜRÜTTÜ: entegrasyon hatası
    /// sönümü şişiriyor ve aşmayı yutuyordu. `damping 0.8` için teorik aşma
    /// %1.52 iken ölçülen —
    ///
    ///       60 Hz → %0.11     240 Hz → %1.07
    ///      120 Hz → %0.68    1000 Hz → %1.41
    ///
    /// — yani ekranın gerçek kare hızında `0.8` ile `1.0` ayırt edilemiyordu.
    /// Zıplama parametrede vardı, pikselde yoktu. Kapalı form bu bağımlılığı
    /// tamamen kaldırıyor: her kare hızında %1.52.
    ///
    /// `damping` (0, 1] aralığında; 1.0 kritik sönüm (ayrı formül, aşağıdaki
    /// salınım biçimi ζ=1'de sıfıra bölünür).
    mutating func step(_ dt: TimeInterval) {
        guard !isSettled else { value = target; velocity = 0; return }

        let dt = CGFloat(min(dt, 1.0 / 30))
        let omega = 2 * .pi / CGFloat(response)
        let zeta = min(max(damping, 0.01), 1.0)

        let x0 = value - target          // hedefe göre yer değiştirme
        let v0 = velocity
        let decay = exp(-zeta * omega * dt)

        if zeta < 1 {
            let omegaD = omega * sqrt(1 - zeta * zeta)
            let a = x0
            let b = (v0 + zeta * omega * x0) / omegaD
            let cosD = cos(omegaD * dt), sinD = sin(omegaD * dt)
            value = target + decay * (a * cosD + b * sinD)
            velocity = decay * ((b * omegaD - zeta * omega * a) * cosD
                                - (a * omegaD + zeta * omega * b) * sinD)
        } else {
            // Kritik sönüm: x(t) = (A + Bt)·e^(-ωt)
            let a = x0
            let b = v0 + omega * x0
            value = target + decay * (a + b * dt)
            velocity = decay * (b - omega * a - omega * b * dt)
        }

        if isSettled { value = target; velocity = 0 }
    }

    /// Hareketi kesmeden yeni hedefe yönlendir. Hız KORUNUR — sıfırlamak
    /// yön değiştirmede "duvara çarpma" hissi yaratıyor.
    mutating func retarget(_ new: CGFloat, damping: CGFloat? = nil, response: TimeInterval? = nil) {
        target = new
        if let damping { self.damping = damping }
        if let response { self.response = response }
    }
}

/// Bırakma anındaki hızdan varış noktasını kestirir — kaydırma yavaşlamasının
/// aynısı. Bir fiske kartı gerçekten "fırlatıyormuş" gibi hissettiren şey bu:
/// en yakın kenarı BIRAKMA noktasından değil, gidilecek noktadan seçiyoruz.
///
/// Ders kitabındaki `v²/(2a)` DEĞİL — Apple'ın kullandığı üstel sönüm biçimi.
enum Momentum {
    /// `0.998` normal kaydırma hissi; küçültmek daha çabuk durdurur.
    static let decelerationRate: CGFloat = 0.998

    static func projection(of velocity: CGFloat) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }
}
