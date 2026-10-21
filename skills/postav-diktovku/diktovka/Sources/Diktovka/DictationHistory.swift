import Foundation

/// Предохранитель (правка автора 26.07.2026): каждая завершённая диктовка
/// сохраняется локально в history.txt — если фокус улетел в другое окно и текст
/// «пропал», его всегда можно достать из меню. Никуда не отправляется.
enum DictationHistory {
    static let url = Transcriber.appSupportDir.appendingPathComponent("history.txt")
    /// Чёрный ящик (правка автора 06.08.2026, после потери диктовки): КАЖДЫЙ
    /// распознанный кусок падает сюда СРАЗУ, до вставки/склейки/ИИ-правки. Даже
    /// если сессия отменится как «шорткат» или чат закроется — сырьё останется.
    static let rawURL = Transcriber.appSupportDir.appendingPathComponent("raw_dictation.log")
    private static let queue = DispatchQueue(label: "diktovka.history")
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Сырой кусок в чёрный ящик — предохранитель от потери (никуда не отправляется)
    static func appendRaw(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        queue.async {
            let entry = "[\(df.string(from: Date()))] \(t)\n"
            guard let data = entry.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: Transcriber.appSupportDir,
                                                     withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: rawURL.path) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: rawURL)
            }
        }
    }

    /// `audio` — имя файла в архиве звука (zapisi/…): по нему находят запись, а не
    /// распознают заново (правило автора 13.09.2026). Живёт в строке-заголовке блока.
    static func append(_ text: String, audio: String? = nil) {
        queue.async {
            let head = "--- \(df.string(from: Date()))" + (audio.map { " · запись \($0)" } ?? "")
            let entry = "\(head)\n\(text)\n\n"
            guard let data = entry.data(using: .utf8) else { return }
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

    /// Последняя запись (переживает перезапуск приложения)
    static func lastEntry() -> String? {
        lastEntries(1).first
    }

    /// Последние n диктовок, свежая — первой
    static func lastEntries(_ n: Int) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let blocks = ("\n" + s).components(separatedBy: "\n--- ").filter { !$0.isEmpty }
        return blocks.suffix(n).reversed().compactMap { block in
            let text = block.split(separator: "\n", omittingEmptySubsequences: false)
                .dropFirst() // строка с датой
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }
}
