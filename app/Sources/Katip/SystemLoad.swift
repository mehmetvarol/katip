import Foundation

/// Bir çevirinin YAVAŞLIĞININ sebebini log'dan okunabilir kılar.
///
/// 2026-08-24'te canlı kullanımda p90 8.88 sn ölçüldü, aynı ses izole
/// `--selftest`'te 3.03 sn çıktı — üç kat fark. `--gpuprobe` ile en olası
/// şüpheli (kartın kendi GPU animasyonu) ÖLÇÜLEREK ÇÜRÜTÜLDÜ (oran 1.00x).
/// Ama olay anı geçtikten sonra sebebi bulmanın yolu yoktu — izole yeniden
/// test etmek koşulları tekrar üretmiyor.
///
/// Bu yüzden ölçüm OLAY ANINDA, her çeviride log'a yazılıyor:
///
///   - **cpu süresi**: bu ÇAĞRI sırasında işlemcinin bizim için harcadığı
///     gerçek süre (`getrusage`). Duvar saati süresiyle (wall) arasındaki
///     FARK, biz çalışmaya HAZIRKEN zamanlayıcının bizi bekletmesi demek —
///     yani başka bir işin CPU'yu/GPU'yu paylaştığının doğrudan kanıtı.
///     `cpu ≈ wall` ise darboğaz bizim kendi hesaplamamızda (ör. WhisperKit'in
///     kendi sıcaklık geri çekilmesi beş kez denemiş olabilir).
///     `cpu ≪ wall` ise darboğaz DIŞARIDA.
///   - **sistem yükü**: `getloadavg()` — o anda makinede kaç iş kuyrukta.
///   - **termal durum**: `ProcessInfo.thermalState` — cihaz kısılmış mı.
///
/// Bir dahaki yavaşlıkta bu üç sayı sebebi tahmin etmeden gösterecek.
enum SystemLoad {
    static func loadAverage() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads[0]
    }

    static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "normal"
        case .fair: "hafif"
        case .serious: "CİDDİ"
        case .critical: "KRİTİK"
        @unknown default: "bilinmiyor"
        }
    }

    /// Bu süreç için harcanan toplam işlemci süresi (kullanıcı + çekirdek).
    /// Kümülatif — bir aralığı ölçmek için ÖNCESİ ve SONRASI okunup farkı
    /// alınmalı.
    static func cpuTime() -> TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }
}
