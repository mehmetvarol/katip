import AppKit
import Carbon.HIToolbox

/// Menü çubuğu ikonuna tıklamak uygulamamızı ÖNE GETİRİR ve hedef uygulama
/// odağı kaybeder — metin o zaman yanlış yere gider. Bu yüzden "bizden önceki
/// aktif uygulama" sürekli izlenir ve yapıştırmadan hemen önce geri aktive edilir.
final class FocusTracker {
    static let shared = FocusTracker()

    private(set) var previousApp: NSRunningApplication?

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.previousApp = app
        }
        previousApp = NSWorkspace.shared.frontmostApplication
    }

    func start() {}
}

enum TextInjector {
    enum InjectionError: LocalizedError {
        case secureInput
        case noAccessibility

        var errorDescription: String? {
            switch self {
            case .secureInput:
                "Şifre alanı açık — güvenlik gereği metin yazılmadı."
            case .noAccessibility:
                "Erişilebilirlik izni yok — metin yazılamadı."
            }
        }
    }

    /// Panoya yazıp sentetik ⌘V gönderir.
    ///
    /// Neden AX değil de pano: `kAXSelectedTextAttribute` daha temiz ama Electron
    /// (Cursor/VS Code) ve terminal uygulamalarında güvenilmez. Pano+⌘V her yerde çalışır.
    @MainActor
    static func inject(_ text: String) async throws {
        guard !text.isEmpty else { return }

        Trace.log("enjeksiyon — erişilebilirlik: \(Permissions.hasAccessibility), güvenli giriş: \(IsSecureEventInputEnabled()), hedef: \(FocusTracker.shared.previousApp?.localizedName ?? "yok")")
        guard !IsSecureEventInputEnabled() else { throw InjectionError.secureInput }
        guard Permissions.hasAccessibility else { throw InjectionError.noAccessibility }

        // Odağı geri ver, yoksa ⌘V bize gelir.
        if let previous = FocusTracker.shared.previousApp, !previous.isActive {
            previous.activate()
            try? await Task.sleep(for: .milliseconds(120))
        }

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        paste()

        // Panoyu geri yükle — kullanıcının kopyaladığı şeyi çalmayalım.
        // Gecikme, hedef uygulamanın yapıştırmayı okumasına zaman tanıyor.
        try? await Task.sleep(for: .milliseconds(250))
        if let saved {
            pasteboard.clearContents()
            pasteboard.setString(saved, forType: .string)
        }
    }

    private static func paste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents], state: .eventSuppressionStateSuppressionInterval)

        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }
}
