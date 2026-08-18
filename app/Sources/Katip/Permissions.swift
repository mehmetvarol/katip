import AVFoundation
import AppKit
import ApplicationServices
import IOKit.hid

enum Permissions {
    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Global klavye kısayolu için ŞART. macOS'ta olayları *dinlemek*
    /// Erişilebilirlik'ten ayrı bir izin: Giriş İzleme.
    /// Erişilebilirlik sentetik olay GÖNDERMEYE yetiyor ama CGEventTap ile
    /// tuş dinlemeye yetmiyor — ikisi de gerekli.
    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Ham değeri de göster: "denied" ile "unknown" ayrımı teşhis için kritik.
    /// denied ise sistem istem penceresi BİR DAHA çıkmaz, kaydı sıfırlamak gerekir.
    static var inputMonitoringDescription: String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: "var"
        case kIOHIDAccessTypeDenied:  "REDDEDİLMİŞ (istem çıkmaz, tccutil reset gerek)"
        default:                      "henüz sorulmadı"
        }
    }

    @discardableResult
    static func requestMicrophone() async -> Bool {
        if hasMicrophone { return true }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Sistem penceresini açar. İzin verilkatipn sonra **uygulamanın yeniden
    /// başlatılması gerekebilir** — TCC kaydı süreç başına önbelleklenir.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings(_ pane: Pane) {
        guard let url = URL(string: pane.urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    enum Pane {
        case microphone
        case accessibility
        case inputMonitoring

        var urlString: String {
            switch self {
            case .microphone:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            case .accessibility:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            case .inputMonitoring:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            }
        }
    }
}
