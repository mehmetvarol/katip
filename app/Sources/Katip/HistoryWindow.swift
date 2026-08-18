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

    private var results: [HistoryEntry] { History.shared.search(query) }

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
                            Spacer()
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
            HStack {
                Text("\(results.count) kayıt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Geçmişi temizle", role: .destructive) {
                    History.shared.clear()
                    entries = []
                }
                .font(.caption)
            }
            .padding(8)
        }
        .frame(minWidth: 380, minHeight: 300)
        .onAppear { entries = History.shared.entries }
        .onReceive(NotificationCenter.default.publisher(for: .katipHistoryChanged)) { _ in
            entries = History.shared.entries
        }
    }
}

extension Notification.Name {
    static let katipHistoryChanged = Notification.Name("katipHistoryChanged")
}
