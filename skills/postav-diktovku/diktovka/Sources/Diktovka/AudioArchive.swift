import AVFoundation

/// Архив звука диктовок (правило автора 13.09.2026): каждая сессия пишется в ОДИН файл
/// zapisi/<дата_время>.m4a (AAC 32 кбит/с, 16 кГц моно ≈ 14 МБ на час речи), живёт
/// `keepDays` дней и удаляется сама. Распознаём один раз: текст лежит в raw_dictation.log
/// и history.txt с именем файла — вернуться к записи значит открыть файл и лог,
/// а не распознавать заново.
enum AudioArchive {
    static let dir = Transcriber.appSupportDir.appendingPathComponent("zapisi")
    static let keepDays = 7
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: "audioArchiveEnabled") as? Bool ?? true
    }
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    static func newFileURL() -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(df.string(from: Date()) + ".m4a")
    }

    /// AAC-файл под поток 16 кГц float32 моно (формат конвертера рекордера).
    /// Не открылся — лог и nil: архив никогда не должен ломать саму диктовку.
    static func open(_ url: URL, format: AVAudioFormat) -> AVAudioFile? {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        do {
            return try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            AppLog.log("архив: не открыл \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    /// Удалить записи старше keepDays; вернуть сколько снёс и сколько осталось (МБ)
    @discardableResult
    static func cleanup() -> (removed: Int, keptMB: Int) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return (0, 0) }
        let limit = Date().addingTimeInterval(-Double(keepDays) * 86_400)
        var removed = 0, bytes = 0
        for u in items where u.pathExtension == "m4a" {
            let rv = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            if let d = rv?.contentModificationDate, d < limit {
                if (try? fm.removeItem(at: u)) != nil { removed += 1 }
            } else {
                bytes += rv?.fileSize ?? 0
            }
        }
        if removed > 0 {
            AppLog.log("архив: удалил \(removed) записей старше \(keepDays) дней, осталось \(bytes / 1_048_576) МБ")
        }
        return (removed, bytes / 1_048_576)
    }
}
