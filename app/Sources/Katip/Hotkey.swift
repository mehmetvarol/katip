import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Kısayol tuşu seçenekleri. Menüden değiştirilebilir, UserDefaults'ta saklanır.
enum HotkeyChoice: String, CaseIterable {
    // "Sağ Control" ve F13-F19 bilerek YOK.
    // Sağ Control: standart Apple klavyelerinde (MacBook, Magic Keyboard)
    // fiziksel sağ Control tuşu yok — kVK_RightControl hiçbir gerçek tuş
    // basışıyla gelmiyor, seçenek sessizce hiçbir şey yapmıyordu.
    // F13-F19: Mac'te yaygın kullanılan tuşlar değil (kullanıcı isteği,
    // 2026-08-27) — sol taraf seçenekleri daha kullanışlı bir alternatif.
    case leftOption, leftCommand, leftControl, leftShift
    case rightOption, rightCommand, rightShift
    case disabled

    var title: String {
        switch self {
        case .leftOption:   "Sol Option (⌥)"
        case .leftCommand:  "Sol Command (⌘)"
        case .leftControl:  "Sol Control (⌃)"
        case .leftShift:    "Sol Shift (⇧)"
        case .rightOption:  "Sağ Option (⌥)"
        case .rightCommand: "Sağ Command (⌘)"
        case .rightShift:   "Sağ Shift (⇧)"
        case .disabled: "Kapalı"
        }
    }

    /// Yüzen karttaki kısa gösterim — "Sağ Option (⌥)" oraya sığmıyor.
    var glyph: String {
        switch self {
        case .leftOption, .rightOption:   "⌥"
        case .leftCommand, .rightCommand: "⌘"
        case .leftControl:                "⌃"
        case .leftShift, .rightShift:     "⇧"
        case .disabled:                   ""
        }
    }

    /// Sağ/sol ayrımı için ham sanal tuş kodu (flagsChanged.keyCode).
    var keyCode: CGKeyCode? {
        switch self {
        case .leftOption:   CGKeyCode(kVK_Option)
        case .leftCommand:  CGKeyCode(kVK_Command)
        case .leftControl:  CGKeyCode(kVK_Control)
        case .leftShift:    CGKeyCode(kVK_Shift)
        case .rightOption:  CGKeyCode(kVK_RightOption)
        case .rightCommand: CGKeyCode(kVK_RightCommand)
        case .rightShift:   CGKeyCode(kVK_RightShift)
        case .disabled: nil
        }
    }

    /// Modifier'ın basılı olup olmadığını anlamak için bayrak maskesi.
    var flag: CGEventFlags? {
        switch self {
        case .leftOption, .rightOption:   .maskAlternate
        case .leftCommand, .rightCommand: .maskCommand
        case .leftControl:                .maskControl
        case .leftShift, .rightShift:     .maskShift
        case .disabled: nil
        }
    }

    static var current: HotkeyChoice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "hotkey"),
                  let choice = HotkeyChoice(rawValue: raw) else { return .rightOption }
            return choice
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "hotkey") }
    }
}

/// Global tuş dinleyici.
///
/// Fn/🌐 bilerek listede yok: macOS'un kendi katip kısayolu (çift Fn) onu sistem
/// seviyesinde kapıyor, uygulama seviyesinde güvenilir şekilde yakalanamıyor.
@MainActor
final class HotkeyMonitor {
    /// `pressed`: tuşa basıldı · `released`: bırakıldı
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Giriş İzleme izni yoksa haber ver — kısayol bu izin olmadan ÇALIŞMAZ.
    var onNeedsPermission: (() -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isDown = false

    func start() {
        stop()
        guard HotkeyChoice.current != .disabled else { return }

        // Tüm seçenekler modifier (F-tuşu seçeneği kaldırıldı) — sadece
        // flagsChanged yeterli, her tuş vuruşunu dinlemeye gerek yok.
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // olayı tüketmiyoruz, sadece dinliyoruz
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // Değerleri SENKRON oku: CGEvent, callback döndükten sonra
                // geçersizleşebiliyor. Asenkron blokta okumak sessiz hataya yol açar.
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                let flags = event.flags
                DispatchQueue.main.async {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context)
        else {
            Trace.log("CGEventTap kurulamadı — Giriş İzleme izni yok olabilir")
            onNeedsPermission?()
            return
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Trace.log("kısayol dinleniyor: \(HotkeyChoice.current.title) · Giriş İzleme: \(Permissions.inputMonitoringDescription)")
        if !Permissions.hasInputMonitoring { onNeedsPermission?() }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        tap = nil
        source = nil
        isDown = false
    }

    /// Tap sistem tarafından kapatılabiliyor (zaman aşımı, uyku). Yeniden aç,
    /// yoksa "bir süre sonra kısayolum çalışmıyor" hatası çıkar.
    private func handle(type: CGEventType, keyCode: CGKeyCode, flags: CGEventFlags) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Trace.log("event tap yeniden etkinleştirildi")
            return
        }

        let choice = HotkeyChoice.current
        guard let wanted = choice.keyCode,
              type == .flagsChanged, keyCode == wanted, let flag = choice.flag else { return }
        let down = flags.contains(flag)
        guard down != isDown else { return }
        isDown = down
        Trace.log(down ? "kısayol BASILDI" : "kısayol BIRAKILDI")
        down ? onPress?() : onRelease?()
    }
}
