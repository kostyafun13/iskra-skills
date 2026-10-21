import Foundation

/// Числа → слова ПЕРЕД синтезом речи (заказ автора 18.09.2026: «диктовка должна научиться
/// читать цифры, там 50 — пятьдесят, а не пять ноль»).
///
/// Зачем отдельный проход. Синтезаторы читают цифры каждый по-своему: системный AVSpeech
/// обычно справляется, Vosk и Piper на числах спотыкаются и выдают «пять ноль» вместо
/// «пятьдесят», а «30 000 ₽» превращают в кашу — знак рубля до них вообще не доходит,
/// `Speaker.sanitize` вырезает его как «не букву». Поэтому normalize идёт ДО sanitize:
/// к моменту чистки в тексте уже слова, а не символы.
///
/// Что НЕ покрыто и почему (поймано тестом 18.09.2026, оставлено сознательно):
/// творительный после «с» («с 10 менеджерами» читается «с десять менеджерами») — предлог «с»
/// бывает и родительным («с 61% до 69%», это разбирает growth), различить их без синтаксиса
/// нельзя, а угадывать хуже, чем не склонять. Деньги после предлога («свыше 1 000 000 рублей»)
/// идут именительным: money() срабатывает раньше правила предлогов.
///
/// Падеж. Полного согласования по синтаксису тут нет и не нужно: именительный как база,
/// родительный — там, где конструкция его диктует сама («от пятнадцати до тридцати»,
/// «восемнадцатого сентября»). Это покрывает то, ради чего заказано: суммы, диапазоны,
/// проценты, даты и время в текстах автора.
enum NumberSpeech {

    // MARK: - Публичный вход

    /// Единственная точка входа. Порядок замен — от самых узких конструкций к общим:
    /// узкая (дата) должна забрать свои цифры раньше, чем до них доберётся общее правило.
    static func normalize(_ text: String) -> String {
        var s = text
        s = glueDigitGroups(s)     // «30 000» → «30000», иначе дальше это два числа
        s = dates(s)
        s = times(s)
        s = years(s)
        s = ranges(s)
        s = money(s)
        s = growth(s)              // «с 61% до 69%» — падеж диктует сама конструкция
        s = percents(s)
        s = scaleWords(s)          // «15 млн» без валюты
        s = ordinals(s)            // «3-й», «18-го»
        s = afterGenitivePreposition(s)   // «из 17» → «из семнадцати»
        s = plainNumbers(s)
        return s
    }

    // MARK: - Словари

    private enum Gender { case male, female, neuter }
    private enum GCase { case nom, gen }

    private static let onesNom: [Gender: [String]] = [
        .male:   ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"],
        .female: ["ноль", "одна", "две", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"],
        .neuter: ["ноль", "одно", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"],
    ]
    private static let onesGen = ["нуля", "одного", "двух", "трёх", "четырёх",
                                  "пяти", "шести", "семи", "восьми", "девяти"]

    private static let teensNom = ["десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать",
                                   "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"]
    private static let teensGen = ["десяти", "одиннадцати", "двенадцати", "тринадцати", "четырнадцати",
                                   "пятнадцати", "шестнадцати", "семнадцати", "восемнадцати", "девятнадцати"]

    private static let tensNom = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят",
                                  "шестьдесят", "семьдесят", "восемьдесят", "девяносто"]
    private static let tensGen = ["", "", "двадцати", "тридцати", "сорока", "пятидесяти",
                                  "шестидесяти", "семидесяти", "восьмидесяти", "девяноста"]

    private static let hundredsNom = ["", "сто", "двести", "триста", "четыреста", "пятьсот",
                                      "шестьсот", "семьсот", "восемьсот", "девятьсот"]
    private static let hundredsGen = ["", "ста", "двухсот", "трёхсот", "четырёхсот", "пятисот",
                                      "шестисот", "семисот", "восьмисот", "девятисот"]

    /// Разряд: три формы для 1 / 2–4 / 5+ плюс род единиц внутри разряда
    private struct Scale {
        let one: String, few: String, many: String, gender: Gender
    }
    private static let scales: [Scale] = [
        Scale(one: "тысяча",  few: "тысячи",   many: "тысяч",     gender: .female),
        Scale(one: "миллион", few: "миллиона", many: "миллионов", gender: .male),
        Scale(one: "миллиард", few: "миллиарда", many: "миллиардов", gender: .male),
        Scale(one: "триллион", few: "триллиона", many: "триллионов", gender: .male),
    ]

    private static let monthsGen = ["", "января", "февраля", "марта", "апреля", "мая", "июня",
                                    "июля", "августа", "сентября", "октября", "ноября", "декабря"]

    // MARK: - Числительные

    /// Форма слова по числу: 1 / 2–4 / 5+ с учётом «одиннадцать…четырнадцать»
    private static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let n100 = n % 100, n10 = n % 10
        if n100 >= 11 && n100 <= 14 { return many }
        if n10 == 1 { return one }
        if n10 >= 2 && n10 <= 4 { return few }
        return many
    }

    /// Группа 0…999 словами
    private static func upTo999(_ n: Int, gender: Gender, gcase: GCase) -> [String] {
        var out: [String] = []
        let h = n / 100, t = (n % 100) / 10, o = n % 10
        if h > 0 { out.append(gcase == .gen ? hundredsGen[h] : hundredsNom[h]) }
        if t == 1 {
            out.append(gcase == .gen ? teensGen[o] : teensNom[o])
        } else {
            if t > 1 { out.append(gcase == .gen ? tensGen[t] : tensNom[t]) }
            if o > 0 { out.append(gcase == .gen ? onesGen[o] : (onesNom[gender] ?? onesNom[.male]!)[o]) }
        }
        return out
    }

    /// Целое число словами. Отрицательные и ноль тоже.
    static func spell(_ value: Int, gender: String = "male", genitive: Bool = false) -> String {
        let g: Gender = gender == "female" ? .female : (gender == "neuter" ? .neuter : .male)
        return spell(value, gender: g, gcase: genitive ? .gen : .nom)
    }

    private static func spell(_ value: Int, gender: Gender, gcase: GCase) -> String {
        if value == 0 { return gcase == .gen ? "нуля" : "ноль" }
        var out: [String] = []
        var n = abs(value)
        if value < 0 { out.append("минус") }

        // разбиваем на группы по три, от старшей к младшей
        var groups: [Int] = []
        while n > 0 { groups.append(n % 1000); n /= 1000 }

        for idx in stride(from: groups.count - 1, through: 0, by: -1) {
            let g = groups[idx]
            if g == 0 { continue }
            if idx == 0 {
                out += upTo999(g, gender: gender, gcase: gcase)
            } else {
                let sc = scales[min(idx - 1, scales.count - 1)]
                out += upTo999(g, gender: sc.gender, gcase: gcase)
                let word = plural(g, sc.one, sc.few, sc.many)
                out.append(gcase == .gen ? genitiveOfScale(word, g) : word)
            }
        }
        return out.joined(separator: " ")
    }

    /// Разряд в родительном: «тысячи» → «тысяч», «миллиона» → «миллионов» и т.д.
    private static func genitiveOfScale(_ word: String, _ n: Int) -> String {
        switch word {
        case "тысяча", "тысячи": return "тысяч"
        case "миллион", "миллиона": return "миллионов"
        case "миллиард", "миллиарда": return "миллиардов"
        case "триллион", "триллиона": return "триллионов"
        default: return word
        }
    }

    // MARK: - Порядковые

    private static let ordUnitsGen = ["", "первого", "второго", "третьего", "четвёртого", "пятого",
                                      "шестого", "седьмого", "восьмого", "девятого"]
    // формы именительного по родам держим списком, а не заменой хвоста:
    // «третьего» → «третьий» — ровно та ошибка, что поймал тест 18.09.2026
    private static let ordUnitsM = ["", "первый", "второй", "третий", "четвёртый", "пятый",
                                    "шестой", "седьмой", "восьмой", "девятый"]
    private static let ordUnitsF = ["", "первая", "вторая", "третья", "четвёртая", "пятая",
                                    "шестая", "седьмая", "восьмая", "девятая"]
    private static let ordUnitsN = ["", "первое", "второе", "третье", "четвёртое", "пятое",
                                    "шестое", "седьмое", "восьмое", "девятое"]
    private static let ordTeensM = ["десятый", "одиннадцатый", "двенадцатый", "тринадцатый", "четырнадцатый",
                                    "пятнадцатый", "шестнадцатый", "семнадцатый", "восемнадцатый", "девятнадцатый"]
    private static let ordTensM = ["", "", "двадцатый", "тридцатый", "сороковой", "пятидесятый",
                                   "шестидесятый", "семидесятый", "восьмидесятый", "девяностый"]
    private static let ordTeensGen = ["десятого", "одиннадцатого", "двенадцатого", "тринадцатого",
                                      "четырнадцатого", "пятнадцатого", "шестнадцатого",
                                      "семнадцатого", "восемнадцатого", "девятнадцатого"]
    private static let ordTensGen = ["", "", "двадцатого", "тридцатого", "сорокового", "пятидесятого",
                                     "шестидесятого", "семидесятого", "восьмидесятого", "девяностого"]

    /// Порядковое в родительном для 1…99 («восемнадцатого»), с составным «двадцать первого»
    private static func ordinalGen99(_ n: Int) -> String {
        if n <= 0 { return "" }
        if n >= 10 && n <= 19 { return ordTeensGen[n - 10] }
        let t = n / 10, o = n % 10
        if t == 0 { return ordUnitsGen[o] }
        if o == 0 { return ordTensGen[t] }
        return tensNom[t] + " " + ordUnitsGen[o]
    }

    /// Порядковое в именительном для 1…99 с родом: «третий», «третья», «двадцать первый»
    private static func ordinalNom99(_ n: Int, _ g: Gender) -> String {
        if n <= 0 { return "" }
        let units = g == .female ? ordUnitsF : (g == .neuter ? ordUnitsN : ordUnitsM)
        if n >= 10 && n <= 19 {
            let base = ordTeensM[n - 10]
            return g == .male ? base : rodOt(base, g)
        }
        let t = n / 10, o = n % 10
        if t == 0 { return units[o] }
        if o == 0 {
            let base = ordTensM[t]
            return g == .male ? base : rodOt(base, g)
        }
        return tensNom[t] + " " + units[o]
    }

    /// Мужское порядковое на «-ый/-ой» → женское/среднее. Работает только на этих
    /// правильных хвостах, поэтому «третий» и родня берутся из словарей выше, а не отсюда.
    private static func rodOt(_ base: String, _ g: Gender) -> String {
        guard base.count > 2 else { return base }
        let stem = String(base.dropLast(2))
        switch g {
        case .female: return stem + "ая"
        case .neuter: return stem + "ое"
        case .male:   return base
        }
    }

    /// Год в родительном: 2026 → «две тысячи двадцать шестого»
    private static func yearGen(_ y: Int) -> String {
        let head = y / 100 * 100                       // 2000
        let tail = y % 100                             // 26
        var parts: [String] = []
        if tail == 0 {
            // ровная сотня — редкий случай, читаем целиком количественным + «года» снаружи
            return spell(y, gender: .male, gcase: .nom)
        }
        parts.append(spell(head, gender: .male, gcase: .nom))
        parts.append(ordinalGen99(tail))
        return parts.joined(separator: " ")
    }

    // MARK: - Замены по тексту

    private static func replace(_ s: String, _ pattern: String,
                                _ body: (NSTextCheckingResult, NSString) -> String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            guard let rep = body(m, ns) else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += rep
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String? {
        guard i < m.numberOfRanges, m.range(at: i).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: i))
    }

    /// «30 000» и «30 000» (неразрывный пробел) → «30000». Иначе дальше это два числа подряд.
    private static func glueDigitGroups(_ s: String) -> String {
        var t = s
        for _ in 0..<3 {
            // \u00A0 — неразрывный, \u202F — узкий неразрывный. Формат ICU (\uXXXX),
            // а НЕ swift-овский \u{XXXX}: с фигурными скобками правило молча не срабатывало,
            // и «30 000 ₽» читалось как «тридцать ноль рублей» (поймано тестом 18.09.2026).
            t = t.replacingOccurrences(of: "(\\d)[ \\u00A0\\u202F](\\d{3})(?!\\d)",
                                       with: "$1$2", options: .regularExpression)
        }
        return t
    }

    /// «18.09.2026» и «16.09» → «восемнадцатого сентября две тысячи двадцать шестого года»
    private static func dates(_ s: String) -> String {
        var t = replace(s, "\\b(\\d{1,2})\\.(\\d{1,2})\\.(\\d{4})\\b") { m, ns in
            guard let d = group(m, 1, ns).flatMap(Int.init),
                  let mo = group(m, 2, ns).flatMap(Int.init),
                  let y = group(m, 3, ns).flatMap(Int.init),
                  (1...31).contains(d), (1...12).contains(mo) else { return nil }
            return "\(ordinalGen99(d)) \(monthsGen[mo]) \(yearGen(y)) года"
        }
        t = replace(t, "\\b(\\d{1,2})\\.(\\d{1,2})\\b(?!\\.\\d)(?!\\d)") { m, ns in
            guard let d = group(m, 1, ns).flatMap(Int.init),
                  let mo = group(m, 2, ns).flatMap(Int.init),
                  (1...31).contains(d), (1...12).contains(mo) else { return nil }
            return "\(ordinalGen99(d)) \(monthsGen[mo])"
        }
        return t
    }

    /// «2026 года», «в 2026 году» → «две тысячи двадцать шестого года». Без слова-маркера
    /// год не трогаем: «2026» в середине фразы чаще число, чем год.
    private static func years(_ s: String) -> String {
        replace(s, "\\b(1[5-9]\\d{2}|20\\d{2})\\s+(года|году|годом)\\b") { m, ns in
            guard let y = group(m, 1, ns).flatMap(Int.init), let w = group(m, 2, ns) else { return nil }
            // «года»/«годом» — родительный, «году» — предложный: «в две тысячи двадцать шестом году»
            let num = w.lowercased() == "году" ? predlozhnyy(yearGen(y)) : yearGen(y)
            return "\(num) \(w)"
        }
    }

    /// Порядковое из родительного в предложный: «двадцать шестого» → «двадцать шестом»
    private static func predlozhnyy(_ s: String) -> String {
        if s.hasSuffix("ого") { return String(s.dropLast(3)) + "ом" }
        if s.hasSuffix("его") { return String(s.dropLast(3)) + "ем" }
        return s
    }

    /// «с 61% до 69%», «с 5 до 12» — оба числа в родительном, как требует конструкция
    private static func growth(_ s: String) -> String {
        replace(s, "\\bс\\s+(\\d+)\\s*(%?)\\s+до\\s+(\\d+)\\s*(%?)") { m, ns in
            guard let a = group(m, 1, ns).flatMap(Int.init),
                  let b = group(m, 3, ns).flatMap(Int.init) else { return nil }
            // в родительном форма всё равно зависит от числа: «одного процента», «девяти процентов»
            let pa = (group(m, 2, ns) ?? "") == "%" ? " " + plural(a, "процента", "процентов", "процентов") : ""
            let pb = (group(m, 4, ns) ?? "") == "%" ? " " + plural(b, "процента", "процентов", "процентов") : ""
            return "с \(spell(a, gender: .male, gcase: .gen))\(pa) до \(spell(b, gender: .male, gcase: .gen))\(pb)"
        }
    }

    /// «17:00» → «семнадцать ноль-ноль», «17:30» → «семнадцать тридцать»
    private static func times(_ s: String) -> String {
        replace(s, "\\b([01]?\\d|2[0-3]):([0-5]\\d)\\b") { m, ns in
            guard let h = group(m, 1, ns).flatMap(Int.init),
                  let mi = group(m, 2, ns).flatMap(Int.init) else { return nil }
            let hh = spell(h, gender: .male, gcase: .nom)
            if mi == 0 { return "\(hh) ноль-ноль" }
            if mi < 10 { return "\(hh) ноль \(spell(mi, gender: .female, gcase: .nom))" }
            return "\(hh) \(spell(mi, gender: .female, gcase: .nom))"
        }
    }

    private static let scaleSuffix = "(?:тыс|тысяч(?:и|а)?|млн|миллион(?:ов|а)?|млрд|миллиард(?:ов|а)?)"

    /// «15–30 млн», «5-10 человек», «3–4» → «от пятнадцати до тридцати миллионов»
    private static func ranges(_ s: String) -> String {
        replace(s, "\\b(\\d+)\\s*[–—-]\\s*(\\d+)\\s*(\(scaleSuffix))?") { m, ns in
            guard let a = group(m, 1, ns).flatMap(Int.init),
                  let b = group(m, 2, ns).flatMap(Int.init), b > a else { return nil }
            let tail = group(m, 3, ns).map { " " + expandScale($0, b) } ?? ""
            return "от \(spell(a, gender: .male, gcase: .gen)) до \(spell(b, gender: .male, gcase: .gen))\(tail)"
        }
    }

    /// «млн» при числе → «миллионов»/«миллиона»/«миллион» по последнему числу диапазона
    private static func expandScale(_ raw: String, _ n: Int) -> String {
        let low = raw.lowercased()
        if low.hasPrefix("тыс") { return plural(n, "тысяча", "тысячи", "тысяч") }
        if low.hasPrefix("млн") || low.hasPrefix("миллион") { return plural(n, "миллион", "миллиона", "миллионов") }
        if low.hasPrefix("млрд") || low.hasPrefix("миллиард") { return plural(n, "миллиард", "миллиарда", "миллиардов") }
        return raw
    }

    /// «30000 ₽», «75 000 руб.», «10 млн ₽» → «тридцать тысяч рублей»
    private static func money(_ s: String) -> String {
        var t = replace(s, "\\b(\\d+)\\s*(\(scaleSuffix))?\\s*(?:₽|рублей|рубля|рубль|руб\\.?)") { m, ns in
            guard let n = group(m, 1, ns).flatMap(Int.init) else { return nil }
            if let sc = group(m, 2, ns) {
                let scWord = expandScale(sc, n)
                let gender: Gender = scWord.hasPrefix("тысяч") ? .female : .male
                return "\(spell(n, gender: gender, gcase: .nom)) \(scWord) рублей"
            }
            return "\(spell(n, gender: .male, gcase: .nom)) \(plural(n, "рубль", "рубля", "рублей"))"
        }
        t = replace(t, "\\$\\s*(\\d+)") { m, ns in
            guard let n = group(m, 1, ns).flatMap(Int.init) else { return nil }
            return "\(spell(n, gender: .male, gcase: .nom)) \(plural(n, "доллар", "доллара", "долларов"))"
        }
        return t
    }

    /// «15%» → «пятнадцать процентов», «7,5%» → «семь и пять десятых процента»
    private static func percents(_ s: String) -> String {
        var t = replace(s, "\\b(\\d+)[.,](\\d+)\\s*%") { m, ns in
            guard let a = group(m, 1, ns).flatMap(Int.init),
                  let fracStr = group(m, 2, ns), let b = Int(fracStr) else { return nil }
            let unit = fracStr.count == 1 ? "десятых" : "сотых"
            return "\(spell(a, gender: .male, gcase: .nom)) и \(spell(b, gender: .female, gcase: .nom)) \(unit) процента"
        }
        t = replace(t, "\\b(\\d+)\\s*%") { m, ns in
            guard let n = group(m, 1, ns).flatMap(Int.init) else { return nil }
            return "\(spell(n, gender: .male, gcase: .nom)) \(plural(n, "процент", "процента", "процентов"))"
        }
        return t
    }

    /// «15 млн» без валюты → «пятнадцать миллионов»
    private static func scaleWords(_ s: String) -> String {
        replace(s, "\\b(\\d+)\\s*(\(scaleSuffix))\\b") { m, ns in
            guard let n = group(m, 1, ns).flatMap(Int.init), let sc = group(m, 2, ns) else { return nil }
            let scWord = expandScale(sc, n)
            let gender: Gender = scWord.hasPrefix("тысяч") ? .female : .male
            return "\(spell(n, gender: gender, gcase: .nom)) \(scWord)"
        }
    }

    /// «3-й», «18-го», «2-я», «5-е» → порядковое. Падеж берём из самого окончания.
    private static func ordinals(_ s: String) -> String {
        replace(s, "\\b(\\d+)-(й|я|е|го|му|м|х|ю|ое|ых)\\b") { m, ns in
            guard let n = group(m, 1, ns).flatMap(Int.init), n > 0, n < 100,
                  let end = group(m, 2, ns) else { return nil }
            switch end.lowercased() {
            case "го", "м", "му", "х", "ых":
                return ordinalGen99(n)            // родительный/дательный — на слух совпадают
            case "й":
                return ordinalNom99(n, .male)
            case "я", "ю":
                return ordinalNom99(n, .female)
            case "е", "ое":
                return ordinalNom99(n, .neuter)
            default:
                return ordinalGen99(n)
            }
        }
    }

    /// Число после предлога, который требует родительного. Список закрытый и однозначный:
    /// «с» сюда НЕ входит — он бывает и творительным («с 10 менеджерами»), и родительным
    /// («с 61% до 69%»); второй случай уже разобран в growth(), первому нужен синтаксис.
    private static let genPrepositions = "из|от|до|около|более|менее|свыше|больше|меньше|для|без|у"

    private static func afterGenitivePreposition(_ s: String) -> String {
        replace(s, "\\b(\(genPrepositions))\\s+(\\d{1,9})(?![\\d.,:%-])") { m, ns in
            guard let prep = group(m, 1, ns),
                  let raw = group(m, 2, ns), let n = Int(raw) else { return nil }
            if raw.count > 1 && raw.hasPrefix("0") { return nil }
            return "\(prep) \(spell(n, gender: .male, gcase: .gen))"
        }
    }

    /// Всё, что осталось цифрами. Длинные хвосты (телефон, номер) не трогаем:
    /// читать их числительным хуже, чем по цифрам.
    private static func plainNumbers(_ s: String) -> String {
        replace(s, "(?<![\\d.,:+])(\\d{1,9})(?![\\d.,:%])") { m, ns in
            guard let raw = group(m, 1, ns), let n = Int(raw) else { return nil }
            if raw.count > 1 && raw.hasPrefix("0") { return nil }   // «007» — код, не число
            return spell(n, gender: .male, gcase: .nom)
        }
    }
}
