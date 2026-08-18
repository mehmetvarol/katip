import Foundation

/// Basit dosya günlüğü. NSLog, ad-hoc imzalı bir menü çubuğu uygulamasında
/// unified log'a düşmüyor — teşhis için güvenilir tek yol dosya.
///   tail -f ~/Library/Application\ Support/Katip/katip.log
enum Trace {
    private static let queue = DispatchQueue(label: "dev.mvrl.katip.trace")

    static var fileURL: URL { Support.directory.appendingPathComponent("katip.log") }

    static func log(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
