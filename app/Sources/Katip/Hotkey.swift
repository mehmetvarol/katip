import AppKit
import Carbon.HIToolbox
import IOKit.hid

/// Kısayol tuşu seçenekleri. Menüden değiştirilebilir, UserDefaults'ta saklanır.
enum HotkeyChoice: String, CaseIterable {
    case rightOption, rightCommand, rightControl, rightShift
    case f13, f14, f15, f16, f17, f18, f19
    case disabled

    var title: String {
        switch self {
        case .rightOption:  "Sağ Option (⌥)"
        case .rightCommand: "Sağ Command (⌘)"
        case .rightControl: "Sağ Control (⌃)"
        case .rightShift:   "Sağ Shift (⇧)"
        case .f13: "F13"
        case .f14: "F14"
        case .f15: "F15"
        case .f16: "F16"
        case .f17: "F17"
        case .f18: "F18"
        case .f19: "F19"
        case .disabled: "Kapalı"
        }
    }

    /// Yüzen karttaki kısa gösterim — "Sağ Option (⌥)" oraya sığmıyor.
    var glyph: String {
        switch self {
        case .rightOption:  "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        case .rightShift:   "⇧"
        case .disabled:     ""
        default:            title
        }
    }

    /// Modifier tuşları `flagsChanged` ile, F-tuşları `keyDown/keyUp` ile gelir.
    var isModifier: Bool {
        switch self {
        case .rightOption, .rightCommand, .rightControl, .rightShift: true
        default: false
        }
    }

    /// Sağ/sol ayrımı için ham sanal tuş kodu (modifier'larda flagsChanged.keyCode).
    var keyCode: CGKeyCode? {
        switch self {
        case .rightOption:  CGKeyCode(kVK_RightOption)
        case .rightCommand: CGKeyCode(kVK_RightCommand)
        case .rightControl: CGKeyCode(kVK_RightControl)
        case .rightShift:   CGKeyCode(kVK_RightShift)
        case .f13: CGKeyCode(kVK_F13)
        case .f14: CGKeyCode(kVK_F14)
        case .f15: CGKeyCode(kVK_F15)
        case .f16: CGKeyCode(kVK_F16)
        case .f17: CGKeyCode(kVK_F17)
        case .f18: CGKeyCode(kVK_F18)
        case .f19: CGKeyCode(kVK_F19)
        case .disabled: nil
        }
    }

    /// Modifier'ın basılı olup olmadığını anlamak için bayrak maskesi.
    var flag: CGEventFlags? {
        switch self {
        case .rightOption:  .maskAlternate
        case .rightCommand: .maskCommand
        case .rightControl: .maskControl
        case .rightShift:   .maskShift
        default: nil
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

        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,          // olayı tüketmiyoruz, sadece dinliyoruz
            eventsOfInterest: CGEventMask(mask),
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
        guard let wanted = choice.keyCode else { return }

        if choice.isModifier {
            guard type == .flagsChanged, keyCode == wanted, let flag = choice.flag else { return }
            let down = flags.contains(flag)
            guard down != isDown else { return }
            isDown = down
            Trace.log(down ? "kısayol BASILDI" : "kısayol BIRAKILDI")
            down ? onPress?() : onRelease?()
        } else {
            guard keyCode == wanted else { return }
            if type == .keyDown, !isDown { isDown = true; Trace.log("kısayol BASILDI"); onPress?() }
            if type == .keyUp, isDown { isDown = false; Trace.log("kısayol BIRAKILDI"); onRelease?() }
        }
    }
}
