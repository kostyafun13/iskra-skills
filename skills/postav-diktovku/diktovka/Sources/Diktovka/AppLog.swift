import Foundation

/// Лог действий приложения (диагностика «куда делся текст»):
/// ~/Library/Application Support/Diktovka/app.log
enum AppLog {
    static let url = Transcriber.appSupportDir.appendingPathComponent("app.log")
    private static let queue = DispatchQueue(label: "diktovka.applog")
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let pid = ProcessInfo.processInfo.processIdentifier

    /// В строке лога стоит только время — за 31 день истории это значит, что
    /// «сколько было вчера» не посчитать вообще (разбор 19.09.2026). Дату пишем
    /// раз в день отдельной строкой: дёшево, файл не раздувает, аналитика возможна.
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static var lastDay = ""

    static func log(_ msg: String) {
        queue.async {
            let today = dayFmt.string(from: Date())
            var line = ""
            if today != lastDay {
                lastDay = today
                line += "=== день \(today)\n"
            }
            line += "\(df.string(from: Date())) [\(pid)] \(msg)\n"
            guard let data = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: Transcriber.appSupportDir,
                                                     withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: url.path) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
