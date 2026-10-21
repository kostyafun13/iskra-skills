import Foundation

/// Чистка надиктованного текста ПРАВИЛАМИ, полностью локально (без ИИ и сети):
/// слова-паразиты («э-э», «ну», «вот», «типа», «как бы»…), повторы-запинки
/// («я я думаю»), лишние запятые/пробелы, заглавные после точки.
/// Правила сознательно консервативные: лучше оставить спорное слово, чем
/// исказить смысл («как бы это сделать?» — «как бы» тут значимое, не трогаем:
/// вводные режем только между запятыми или в начале предложения).
enum TextCleaner {

    /// Вводные-паразиты; «короче/собственно говоря», «в общем-то» — с хвостами
    private static let fillers =
        "ну|вот|типа|как бы|короче(?: говоря)?|в общем(?:-то)?|это самое|" +
        "так сказать|скажем так|значит|собственно(?: говоря)?|получается|слушай"

    static func clean(_ text: String) -> String {
        var s = text

        // междометия-мычание как отдельные слова: э, э-э, ээ, эм, м-м, мммм, ыы, а-а, ме-е
        // (одиночные «а»/«м»/«ы» и «мм» = миллиметры — не трогаем)
        s = re(s, "(?<![а-яёa-z0-9-])(?:э+(?:-э+)?|эм+|м-м+|м{3,}|ы{2,}|а{2,}|а-а+|ме-е+)(?![а-яёa-z0-9-])", "")

        // вводные: между запятыми и в начале предложения — до стабилизации,
        // потому что они любят идти пачкой («Ну, короче, я…»)
        for _ in 0..<4 {
            let before = s
            s = re(s, ",\\s*(?:\(fillers))\\s*,", ",")                      // «привет, ну, как» → «привет, как»
            s = re(s, "(^[ \\t]*|[.!?…]\\s+)(?:\(fillers)),\\s*", "$1", multiline: true) // «Короче, я…» → «я…»
            s = re(s, "(^[ \\t]*|[.!?…]\\s+)ну\\s+", "$1", multiline: true) // «Ну я думаю» → «я думаю»
            s = re(s, "(^[ \\t]*|[.!?…]\\s+)(?:ну|вот|короче|в общем)[.!?]\\s*", "$1", multiline: true) // «Вот.» целиком
            if s == before { break }
        }

        // повторы-запинки: «я я думаю», «что что это» → одно слово
        s = re(s, "(?<![а-яёa-z0-9])([а-яёa-z0-9]+)(?:\\s+\\1)+(?![а-яёa-z0-9])", "$1")

        // косметика пунктуации после вырезаний
        s = re(s, "[ \\t]+([,.!?;:])", "$1")            // пробел перед знаком
        s = re(s, ",(\\s*,)+", ",")                     // дубли запятых
        s = re(s, ",\\s*([.!?])", "$1")                 // запятая перед точкой
        s = re(s, "(^|[.!?]\\s)[,;:\\s]+", "$1", multiline: true) // предложение не начинается с запятой
        s = re(s, "([,;:])(?=[а-яёА-ЯЁa-zA-Z0-9«(])", "$1 ")      // после запятой — пробел
        s = re(s, "([а-яё]{2,}[.!?])(?=[А-ЯЁ])", "$1 ")           // «подумает.Ответ» → «подумает. Ответ»
        s = re(s, "[ \\t]{2,}", " ")                    // двойные пробелы (переносы строк живут)
        s = re(s, "[ \\t]+$", "", multiline: true)      // хвостовые пробелы строк

        s = capitalizeSentences(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Кусок — продолжение речи (правка 13.09.2026): движок и корректор ставят заглавную
    /// в начале КАЖДОГО куска, и посреди предложения вырастало «…в этот раз она Говорила».
    /// Если предыдущий кусок кончился буквой, цифрой или запятой — первое слово со строчной;
    /// не трогаем аббревиатуры (две заглавные), латиницу и термины из словаря (имена там же).
    static func continueCase(_ text: String, after prev: String?) -> String {
        guard let prev, let lastCh = prev.last(where: { !$0.isWhitespace }),
              lastCh.isLetter || lastCh.isNumber || lastCh == "," else { return text }
        guard let first = text.first, first.isUppercase,
              let sc = first.unicodeScalars.first, (0x400...0x4FF).contains(Int(sc.value))
        else { return text }
        let word = String(text.prefix { $0.isLetter || $0 == "-" })
        if word.dropFirst().contains(where: { $0.isUppercase }) { return text }   // аббревиатура
        let isTerm = WordFixes.terms().contains {
            $0.first?.isUppercase == true && $0.caseInsensitiveCompare(word) == .orderedSame
        }
        if isTerm { return text }
        return first.lowercased() + text.dropFirst()
    }

    // MARK: - Внутренности

    private static func re(_ s: String, _ pattern: String, _ template: String,
                           multiline: Bool = false) -> String {
        var opts: NSRegularExpression.Options = [.caseInsensitive]
        if multiline { opts.insert(.anchorsMatchLines) }
        guard let r = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        return r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                          withTemplate: template)
    }

    /// Заглавная в начале текста и после конца предложения. После точки — только
    /// если перед ней ≥2 буквенных символа: «т.е. слово» не превращаем в «Т.е. Слово»
    private static func capitalizeSentences(_ text: String) -> String {
        var s = text
        if let r = try? NSRegularExpression(pattern: "[а-яёa-z0-9»)]{2}[.!?…]\\s+([а-яё])",
                                            options: []) {
            let matches = r.matches(in: s, range: NSRange(s.startIndex..., in: s))
            for m in matches.reversed() {
                guard let range = Range(m.range(at: 1), in: s) else { continue }
                s.replaceSubrange(range, with: s[range].uppercased())
            }
        }
        if let first = s.firstIndex(where: { !$0.isWhitespace }), s[first].isLowercase {
            s.replaceSubrange(first...first, with: s[first...first].uppercased())
        }
        return s
    }
}
