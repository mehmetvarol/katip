import ServiceManagement

/// Girişte başlat. `SMAppService` (macOS 13+) — eski `SMLoginItemSetEnabled`
/// ve LaunchAgent plist'i yazma yöntemlerinin ikisi de artık gereksiz.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Kullanıcı Sistem Ayarları'ndan da kapatabilir; o durumda status
    /// `.requiresApproval` döner ve register() işe yaramaz.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func toggle() -> Bool {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
                Trace.log("girişte başlat: kapatıldı")
            } else {
                try SMAppService.mainApp.register()
                Trace.log("girişte başlat: açıldı")
            }
            return true
        } catch {
            Trace.log("girişte başlat HATA: \(error.localizedDescription)")
            return false
        }
    }
}
