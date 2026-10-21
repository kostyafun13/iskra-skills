import Foundation

/// Словарик автозамен под твою лексику: распознавание коверкает термины и названия,
/// словарик чинит их сразу после распознавания — ещё до ИИ-правки и истории. Файл: ~/Library/Application Support/Diktovka/words.txt, формат
/// построчно «как_распозналось=как_надо» (регистр не важен, # — комментарий).
/// Замены только ЦЕЛЫХ слов; заглавная первого символа сохраняется.
///
/// Строка с префиксом `~` — ПРАВИЛО-ОБРАЗЕЦ: «~регулярка=замена$1» (правка 18.09.2026).
/// Понадобилось, когда одно слово «кастдев» распознавалось тринадцатью способами подряд
/// («каз-деф», «астедэф», «Каz-def»): перечислять такое списком бесполезно — ловится только
/// образец корня, а `$1` возвращает на место падежное окончание («каз-девов» → «кастдевов»).
enum WordFixes {

    private static let defaultRules = """
        # Словарик Диктовки: слева — как распознаётся, справа — как надо.
        # Только целые слова. Строки с # — комментарии. Дополняй смело.
        # Пример: название компании, которое распознаётся криво:
        # мойа компания=МояКомпания
        гиперсыл=гиперссылка
        гиперсылка=гиперссылка
        # правила-образцы (префикс ~) ловят все формы слова разом, $1 — окончание:
        ~(?:(?:[кk][аa][зсzs]?|[аa][зсzs])т?[её]?[\\s-]?[дd][еэe]{1,2}[фвfv])((?:ами|ах|ам|ов|ом|ить|ишь|им|ит|ят|ила|или|ил|лю|а|е|у|ы|))=кастдев$1
        ~(?:[сcs]{1,2}к[иi]л{1,2})((?:ами|ах|ам|ов|ом|а|е|у|ы|и|))=скил$1
        """

    static var fileURL: URL { Transcriber.appSupportDir.appendingPathComponent("words.txt") }

    /// Правила перечитываются при каждом вызове — файл маленький, зато правки
    /// подхватываются без перезапуска приложения
    private static func rules() -> [(from: String, to: String, isRegex: Bool)] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? defaultRules.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return nil }
            var from = String(t[..<eq]).trimmingCharacters(in: .whitespaces)
            let to = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            let isRegex = from.hasPrefix("~")
            if isRegex { from.removeFirst() }
            guard !from.isEmpty, !to.isEmpty else { return nil }
            return (from, to, isRegex)
        }
    }

    // MARK: - Копилка терминов (кнопка Ю)
    // terms.txt — твои термины и имена, по одному на строку. Их знает
    // ИИ-корректор (чинит искажения к ним сам), пополняются жестом Ю.

    static var termsURL: URL { Transcriber.appSupportDir.appendingPathComponent("terms.txt") }

    static func terms() -> [String] {
        guard let text = try? String(contentsOf: termsURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Дописать новые термины (без дублей, регистр не важен); вернуть реально добавленные
    static func rememberTerms(_ incoming: [String]) -> [String] {
        let known = Set(terms().map { $0.lowercased() })
        var added: [String] = []
        for raw in incoming {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...40).contains(t.count), !known.contains(t.lowercased()),
                  !added.contains(where: { $0.lowercased() == t.lowercased() }) else { continue }
            added.append(t)
        }
        guard !added.isEmpty else { return [] }
        let existing = (try? String(contentsOf: termsURL, encoding: .utf8)) ?? ""
        let joined = existing.hasSuffix("\n") || existing.isEmpty
            ? existing + added.joined(separator: "\n") + "\n"
            : existing + "\n" + added.joined(separator: "\n") + "\n"
        try? joined.write(to: termsURL, atomically: true, encoding: .utf8)
        return added
    }

    static func apply(_ text: String) -> String {
        var s = text
        for rule in rules() {
            // образец границы слова задаёт сам; плоское правило экранируем и обкладываем
            // границами — иначе «дек» чинился бы внутри «декабря»
            let body = rule.isRegex ? rule.from : NSRegularExpression.escapedPattern(for: rule.from)
            let pattern = rule.isRegex ? body : "(?<![а-яёa-z0-9-])\(body)(?![а-яёa-z0-9-])"
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = r.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for m in matches.reversed() {
                guard let range = Range(m.range, in: s) else { continue }
                var repl = rule.to
                // $1 → захваченное окончание: «каз-девов» → «кастдев» + «ов»
                if rule.isRegex {
                    repl = r.replacementString(for: m, in: s, offset: 0, template: rule.to)
                }
                // «Матчбейс» в начале предложения → замена тоже с заглавной
                if let first = s[range].first, first.isUppercase, let rf = repl.first, rf.isLowercase {
                    repl = repl.prefix(1).uppercased() + repl.dropFirst()
                }
                s.replaceSubrange(range, with: repl)
            }
        }
        return s
    }
}
