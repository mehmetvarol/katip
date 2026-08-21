import AppKit
import SwiftUI

/// Geçmiş penceresi. Uygulama `LSUIElement` olduğu için normalde penceresi yok;
/// bu pencere yalnızca kullanıcı açıkça istediğinde görünür.
///
/// Burada odağı almak SORUN DEĞİL — dikte anında değil, kullanıcı bilerek açıyor.
/// (Yüzen kapsül tam tersi: o asla odak almamalı.)
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    /// Yeniden çeviriyi yapan taraf `DictationController`, ama pencere onu
    /// tanımıyor — bağlantıyı AppDelegate kuruyor. Pencerenin modele doğrudan
    /// erişmesi, geçmişi salt-okunur bir görüntüleyici olmaktan çıkarırdı.
    var retranscribe: ((HistoryEntry) async -> Result<String, Error>)?

    func show() {
        if window == nil {
            let view = HistoryView()
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Katip — Geçmiş"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 520, height: 480))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct HistoryView: View {
    @State private var query = ""
    @State private var entries: [HistoryEntry] = History.shared.entries
    @State private var copied: UUID?
    @State private var working: UUID?
    @State private var problem: String?

    @State private var audioBytes = 0

    private var results: [HistoryEntry] { History.shared.search(query) }

    private func retry(_ entry: HistoryEntry) {
        guard let retranscribe = HistoryWindowController.shared.retranscribe else { return }
        working = entry.id
        problem = nil
        Task {
            let result = await retranscribe(entry)
            working = nil
            switch result {
            case .success:
                entries = History.shared.entries
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Geçmişte ara", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            Divider()

            if results.isEmpty {
                Spacer()
                Text(entries.isEmpty ? "Henüz dikte yok" : "Eşleşme yok")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(results) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 6) {
                            Text(entry.date, style: .relative) + Text(" önce")
                            if let app = entry.app { Text("· \(app)") }
                            if let s = entry.seconds {
                                Text(String(format: "· %.1f sn", s))
                            }
                            if entry.retranscribed == true { Text("· yeniden çevrildi") }
                            Spacer()
                            if entry.audio.map(Recordings.exists) == true {
                                if working == entry.id {
                                    Text("Çevriliyor…")
                                } else {
                                    Button("Yeniden çevir") { retry(entry) }
                                        .buttonStyle(.link)
                                        .disabled(working != nil)
                                }
                            }
                            Button(copied == entry.id ? "Kopyalandı ✓" : "Kopyala") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                                copied = entry.id
                            }
                            .buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }

            Divider()
            if let problem {
                Text(problem)
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 8).padding(.top, 6)
            }
            HStack {
                Text("\(results.count) kayıt").font(.caption).foregroundStyle(.secondary)
                // Ses metinden daha hassas — ne kadar biriktiği görünür olmalı.
                if audioBytes > 0 {
                    Text("· \(ByteCountFormatter.string(fromByteCount: Int64(audioBytes), countStyle: .file)) ses")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sesleri sil") {
                        Recordings.clear()
                        audioBytes = 0
                        entries = History.shared.entries
                    }
                    .font(.caption)
                }
                Spacer()
                Button("Geçmişi temizle", role: .destructive) {
                    History.shared.clear()
                    entries = []
                    audioBytes = 0
                }
                .font(.caption)
            }
            .padding(8)
        }
        .frame(minWidth: 380, minHeight: 300)
        .onAppear {
            entries = History.shared.entries
            audioBytes = Recordings.totalBytes
        }
        .onReceive(NotificationCenter.default.publisher(for: .katipHistoryChanged)) { _ in
            entries = History.shared.entries
        }
    }
}

extension Notification.Name {
    static let katipHistoryChanged = Notification.Name("katipHistoryChanged")
}
