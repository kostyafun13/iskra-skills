import Foundation

/// Голосовые заготовки (заказ автора 01.08.2026): диктовка «шаблон <имя>» или
/// «заготовка <имя>» вставляет готовый текст вместо распознанных слов.
/// Хранение: ~/Library/Application Support/Diktovka/templates/<имя>.txt —
/// имя файла = голосовое имя, содержимое = что вставлять. Пополняется просто
/// созданием файла; подхватывается сразу, без перезапуска.
enum Templates {

    private static let triggers = ["шаблон", "заготовка"]

    static var dirURL: URL { Transcriber.appSupportDir.appendingPathComponent("templates") }

    /// Что запрошено после триггер-слова («шаблон для встречи» → «для встречи»);
    /// nil = это не запрос заготовки
    static func requestedName(_ spoken: String) -> String? {
        let norm = normalize(spoken)
        for trigger in triggers where norm.hasPrefix(trigger + " ") {
            let wanted = String(norm.dropFirst(trigger.count + 1))
            if !wanted.isEmpty { return wanted }
        }
        return nil
    }

    static func available() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: dirURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "txt" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    /// «Шаблон, для встречи.» → («до встречи», текст): сначала точное имя, потом
    /// мягкое — предлоги не считаются (ASR путает «до/для», автор 01.08). Если
    /// мягко подходят НЕСКОЛЬКО заготовок — nil (звать точнее)
    static func lookup(_ spoken: String) -> (name: String, text: String)? {
        guard let wanted = requestedName(spoken) else { return nil }
        let entries = available()
        if let hit = entries.first(where: { normalize($0) == wanted }) {
            return read(hit)
        }
        let core = stripStopWords(wanted)
        guard !core.isEmpty else { return nil }
        let loose = entries.filter { stripStopWords(normalize($0)) == core }
        return loose.count == 1 ? read(loose[0]) : nil
    }

    private static func read(_ name: String) -> (name: String, text: String)? {
        let url = dirURL.appendingPathComponent(name + ".txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (name, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let stopWords: Set<String> =
        ["до", "для", "на", "в", "во", "с", "со", "о", "об", "по", "за", "к", "ко", "у", "и"]

    private static func stripStopWords(_ s: String) -> String {
        s.split(separator: " ").filter { !stopWords.contains(String($0)) }
            .joined(separator: " ")
    }

    private static func normalize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "ё", with: "е")
        let cleaned = lowered.map { $0.isLetter || $0.isNumber || $0.isWhitespace ? $0 : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}
