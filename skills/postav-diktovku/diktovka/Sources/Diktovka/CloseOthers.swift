import AppKit

/// Кнопка «Закрыть всё лишнее»: оставить Клода, Кодекса, Хром, Зум и Телеграм,
/// остальные окна-программы закрыть, чтобы мак не грузился.
/// Закрываем вежливо (`terminate`, как ⌘Q): программа с несохранённым документом сама
/// спросит, сохранить ли. Трогаем только программы с иконкой в Доке — значки в строке
/// меню (Диктовка, сторожа, VPN) живут отдельно и не закрываются.
/// Свои программы, которые тоже надо оставлять, — файл `ostavit.txt` в папке Диктовки:
/// по строке на программу, часть имени («Заметки», «Notion») или начало бандла («com.apple.Notes»).
enum CloseOthers {
    /// Кого оставляем всегда: по началу идентификатора бандла.
    /// Кодекс живёт внутри ChatGPT.app, и у того бандл `com.openai.codex`.
    private static let keepBundles = [
        "com.anthropic.",          // Клод
        "com.openai.",             // Кодекс (ChatGPT.app) и сам ChatGPT
        "com.google.Chrome",       // Хром и его приложения-ярлыки
        "us.zoom.",                // Зум
        "ru.keepcoder.Telegram",   // Телеграм (Telegram.app, Telegram 2.app)
        "org.telegram.",           // Telegram Desktop
        "com.apple.finder",        // Finder закрыть нельзя — перезапускается сам
    ]
    /// Запасная сетка по имени — если бандл у программы окажется другим.
    /// VPN не закрываем никогда: оборванный туннель рвёт звонок и сессии ИИ.
    private static let keepNames = ["claude", "codex", "chatgpt", "chrome", "zoom",
                                    "telegram", "vpn", "wireguard"]

    static var listURL: URL { Transcriber.appSupportDir.appendingPathComponent("ostavit.txt") }

    private static let listTemplate = """
        # Что ещё НЕ закрывать кнопкой «🧹 Закрыть всё…» — по строке на программу.
        # Клод, Кодекс, Хром, Зум, Телеграм и VPN остаются всегда.
        # Пиши часть имени программы («Заметки», «Notion») или начало бандла («com.apple.Notes»).
        """

    /// Свои строки из ostavit.txt; файла нет — создаём с подсказкой
    static func extraKeep() -> [String] {
        if !FileManager.default.fileExists(atPath: listURL.path) {
            try? FileManager.default.createDirectory(at: Transcriber.appSupportDir, withIntermediateDirectories: true)
            try? listTemplate.write(to: listURL, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: listURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func shouldKeep(_ app: NSRunningApplication, extra: [String] = []) -> Bool {
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        let bundle = app.bundleIdentifier ?? ""
        if keepBundles.contains(where: { bundle.hasPrefix($0) }) { return true }
        let name = (app.localizedName ?? "").lowercased()
        if keepNames.contains(where: { name.contains($0) }) { return true }
        return extra.contains { e in
            let low = e.lowercased()
            return bundle.lowercased().hasPrefix(low) || name.contains(low)
        }
    }

    /// Возвращает имена программ, которым отправили «закрыться».
    @discardableResult
    static func run() -> [String] {
        let extra = extraKeep()
        var closed: [String] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && !app.isTerminated && !shouldKeep(app, extra: extra) {
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            if app.terminate() { closed.append(name) }
        }
        AppLog.log("МЕНЮ: закрыть лишнее — \(closed.isEmpty ? "нечего" : closed.joined(separator: ", "))")
        return closed
    }

    /// Сухой прогон для проверки без закрытия: что закрылось бы сейчас
    static func dryRun() -> [String] {
        let extra = extraKeep()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated && !shouldKeep($0, extra: extra) }
            .map { $0.localizedName ?? $0.bundleIdentifier ?? "?" }
    }
}
