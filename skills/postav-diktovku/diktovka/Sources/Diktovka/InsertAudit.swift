import AppKit
import ApplicationServices

/// ЖУРНАЛ ВСТАВОК — «что реально впечаталось в окно» (заказ автора 19.09.2026).
///
/// Дословно: «может быть, ты можешь ещё ввести лог того, что впечаталось в окно.
/// Потому что, мне кажется, иногда что-то мимо утекает и бесит. Поэтому я пользуюсь
/// буфером… может, прикрутить аналитику, если она опять же не греет? И просто
/// проанализировать, проследить, пособирать данные».
///
/// **Зачем.** Старый лог говорил «впечатано символами (3734)» — но это факт ОТПРАВКИ
/// событий клавиатуры, а не факт приёма. Разбор лога 19.09 показал цену этой слепоты:
/// 318 раз автор вставлял диктовку заново руками (правый ⌥), из них 225 — в первые
/// десять секунд после «успешной» вставки. То есть примерно каждая двадцатая вставка
/// до поля не доезжала, и узнать об этом можно было только по тому, что он чинит сам.
///
/// **Что пишем** — строку JSON на событие в `vstavki.jsonl`: куда вставляли, каким
/// путём (печать символами или буфер), сколько знаков, начало и хвост текста (чтобы
/// пропажу можно было опознать), вернули ли фокус якорем и — главное — **подтвердилось
/// ли приём**: читаем поле через Accessibility и ищем в нём хвост вставленного.
///
/// **Почему не греет.** Ни таймеров, ни опроса: одно чтение атрибута через 0.4 с после
/// вставки, на фоновой очереди, с таймаутом полсекунды. Дозапись строки в файл.
/// Постоянно в фоне не работает ничего.
enum InsertAudit {

    static let url = Transcriber.appSupportDir.appendingPathComponent("vstavki.jsonl")
    private static let queue = DispatchQueue(label: "diktovka.vstavki")
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// когда вставляли последний раз — чтобы измерить, через сколько автор чинит руками
    private static var lastInsertAt: Date?
    private static let lock = NSLock()

    // MARK: - запись событий

    /// Вставка произошла. Зовётся СРАЗУ после `inserter.insert`, проверку ставит сама.
    /// - put: «печать» (юникод-события) или «буфер» (Cmd+V, многострочное)
    /// - vernul: якорь возвращал фокус перед этой вставкой
    /// - zhdal: сколько секунд ждали отпускания модификаторов (кандидат в причину утечки:
    ///   именно зажатый ⌘ уже съедал текст 13.09, и лечение могло закрыть не весь случай)
    static func vstavka(text: String, put: String, nachali: String, vernul: Bool, zhdal: Double) {
        guard !text.isEmpty else { return }
        lock.lock(); lastInsertAt = Date(); lock.unlock()
        let hvost = konec(text)
        let nachalo = String(text.prefix(40))
        // 0.4 с — приёмник успевает отрисовать вставленное; больше ждать нельзя,
        // человек за это время уже кликает в другое место и проверка соврёт
        queue.asyncAfter(deadline: .now() + 0.4) {
            let (proverka, kuda) = proveritPriyom(hvost: hvost)
            zapisat([
                "t": df.string(from: Date()),
                "sob": "вставка",
                "put": put,
                "n": text.count,
                "nachali": nachali,
                "kuda": kuda,
                "vernul": vernul,
                "zhdal_s": zhdal,
                "proverka": proverka,
                "nachalo": nachalo,
                "hvost": hvost,
            ])
        }
    }

    /// Автор починил руками: реплей правым ⌥ или вставка из палитры буфера.
    /// Это и есть внешний сигнал «текст не доехал» — своей головой приложение
    /// об этом узнать не может (канон: сигнал только снаружи).
    static func remont(vid: String, znakov: Int) {
        lock.lock(); let last = lastInsertAt; lock.unlock()
        var posle: Any = "—"
        if let last { posle = Double(round(10 * Date().timeIntervalSince(last)) / 10) }
        let gde = NSWorkspace.shared.frontmostApplication?.localizedName ?? "—"
        zapisat([
            "t": df.string(from: Date()),
            "sob": "ремонт",
            "vid": vid,
            "n": znakov,
            "gde": gde,
            "posle_s": posle,
        ])
    }

    private static func zapisat(_ obj: [String: Any]) {
        queue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                         options: [.sortedKeys, .withoutEscapingSlashes]),
                  var line = String(data: data, encoding: .utf8) else { return }
            line += "\n"
            guard let bytes = line.data(using: .utf8) else { return }
            try? FileManager.default.createDirectory(at: Transcriber.appSupportDir,
                                                     withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: url.path) {
                h.seekToEndOfFile(); h.write(bytes); try? h.close()
            } else {
                try? bytes.write(to: url)
            }
        }
    }

    // MARK: - проверка приёма

    /// Последние значащие знаки вставленного — по ним ищем текст в поле.
    /// Берём хвост, а не начало: начало могло слипнуться с тем, что было в поле.
    private static func konec(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.suffix(24))
    }

    private static func norm(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "  ", with: " ")
    }

    /// Итог: («да» | «нет» | «нечем», имя приложения, где смотрели).
    /// «нечем» — приложение не отдаёт дерево доступности (Electron: Cursor, Slack,
    /// VS Code — пока им не выставлен AXManualAccessibility). Это не ошибка вставки,
    /// это предел проверки, и в сводке он считается отдельно от провала.
    private static func proveritPriyom(hvost: String) -> (String, String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("нечем", "—") }
        let imya = app.localizedName ?? "—"
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return ("нечем", imya) }
        let el = f as! AXUIElement
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let s = value as? String, !s.isEmpty else { return ("нечем", imya) }
        return (norm(s).contains(norm(hvost)) ? "да" : "нет", imya)
    }

    /// Приёмка самой записи: `Diktovka --test-zhurnal` кладёт строку с пометкой «тест»
    /// (сводка её не считает) и говорит, дошла ли она до файла. Нужна потому, что путь
    /// «Swift → JSON → файл» иначе проверяется только живой диктовкой автора.
    static func testZapis() -> String {
        let bylo = (try? String(contentsOf: url, encoding: .utf8))?.count ?? 0
        zapisat(["t": df.string(from: Date()), "sob": "тест", "kuda": "проверка записи"])
        queue.sync { }                       // дождаться очереди журнала
        let stalo = (try? String(contentsOf: url, encoding: .utf8))?.count ?? 0
        return stalo > bylo
            ? "запись в журнал работает: \(bylo) → \(stalo) байт, файл \(url.path)"
            : "ЗАПИСЬ НЕ ПРОШЛА: \(url.path)"
    }

    /// Диагностика `Diktovka --pole`: что приложение видит в поле активного окна.
    /// Ею проверяется сам механизм подтверждения — и заодно видно, какие окна
    /// отдают текст (Telegram), а какие молчат (Electron: Cursor, Slack).
    static func diagnostikaPolya() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "активного приложения нет" }
        let imya = app.localizedName ?? "—"
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else {
            return "\(imya): фокусное поле не отдаётся — проверить приём НЕЧЕМ"
        }
        let el = f as! AXUIElement
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &value) == .success,
              let s = value as? String else {
            return "\(imya): поле есть (\((role as? String) ?? "роль неизвестна")), но текст не отдаёт — проверить приём НЕЧЕМ"
        }
        let hvost = String(s.suffix(120)).replacingOccurrences(of: "\n", with: "⏎")
        return "\(imya): поле \((role as? String) ?? "?"), знаков \(s.count) — приём проверяется\n  хвост: …\(hvost)"
    }

    // MARK: - сводка

    /// Текстовая сводка по журналу: `Diktovka --analitika [дней]` и пункт меню.
    /// Считает ровно то, ради чего журнал заведён: доля подтверждённых вставок,
    /// доля ручных починок и в каких приложениях текст не доезжает.
    static func svodka(dney: Int = 7) -> String {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return "Журнал вставок пуст: \(url.path)\nОн заполняется с первой диктовки после обновления."
        }
        let granica = Calendar.current.date(byAdding: .day, value: -dney, to: Date()) ?? Date.distantPast
        var vsego = 0, da = 0, net = 0, nechem = 0, vernuli = 0, pechat = 0, bufer = 0
        var remontov = 0, remontBystryh = 0
        var remontPoApp: [String: Int] = [:]
        var zhdaliIRemont = 0, zhdali = 0
        var poApp: [String: (vsego: Int, net: Int, nechem: Int)] = [:]
        var poDnyam: [String: (Int, Int)] = [:]      // день → (вставок, ремонтов)
        var znakov = 0

        for line in raw.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let ts = o["t"] as? String, let when = df.date(from: ts), when >= granica else { continue }
            let den = String(ts.prefix(10))
            switch o["sob"] as? String {
            case "вставка":
                vsego += 1
                znakov += (o["n"] as? Int) ?? 0
                let app = (o["kuda"] as? String) ?? "—"
                var a = poApp[app] ?? (0, 0, 0)
                a.vsego += 1
                switch (o["proverka"] as? String) ?? "нечем" {
                case "да":  da += 1
                case "нет": net += 1; a.net += 1
                default:    nechem += 1; a.nechem += 1
                }
                poApp[app] = a
                if (o["vernul"] as? Bool) == true { vernuli += 1 }
                if ((o["put"] as? String) ?? "") == "буфер" { bufer += 1 } else { pechat += 1 }
                if let z = o["zhdal_s"] as? Double, z > 0 {
                    zhdali += 1
                    if ((o["proverka"] as? String) ?? "") == "нет" { zhdaliIRemont += 1 }
                }
                var p = poDnyam[den] ?? (0, 0); p.0 += 1; poDnyam[den] = p
            case "ремонт":
                remontov += 1
                if let s = o["posle_s"] as? Double, s <= 30 { remontBystryh += 1 }
                let gde = (o["gde"] as? String) ?? "—"
                remontPoApp[gde, default: 0] += 1
                var p = poDnyam[den] ?? (0, 0); p.1 += 1; poDnyam[den] = p
            default: break
            }
        }

        func dolya(_ a: Int, _ b: Int) -> String { b == 0 ? "—" : String(format: "%.1f%%", 100 * Double(a) / Double(b)) }

        var out = "ЧТО ВПЕЧАТАЛОСЬ В ОКНО — за \(dney) дн.\n\n"
        out += "Вставок: \(vsego) (\(znakov) знаков) · печатью \(pechat) · буфером \(bufer)\n"
        out += "Подтверждено чтением поля: \(da) (\(dolya(da, vsego)))\n"
        out += "НЕ ДОЕХАЛО (поле прочитано, текста нет): \(net) (\(dolya(net, vsego)))\n"
        out += "Проверить нечем (окно без доступности): \(nechem) (\(dolya(nechem, vsego)))\n"
        out += "Фокус возвращал якорь: \(vernuli)\n\n"
        out += "Чинил руками (⌥ реплей, палитра): \(remontov), из них в первые 30 с после вставки — \(remontBystryh)\n"
        if vsego > 0 { out += "Цена слепоты: \(dolya(remontBystryh, vsego)) вставок переиграно руками\n" }

        if zhdali > 0 {
            out += "Вставок после ожидания зажатого модификатора: \(zhdali), из них не доехало \(zhdaliIRemont)\n"
        }
        if !remontPoApp.isEmpty {
            out += "\nГде чинил руками: "
            out += remontPoApp.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")
            out += "\n"
        }
        if !poApp.isEmpty {
            out += "\nПо окнам (вставок · не доехало · нечем проверить):\n"
            for (app, a) in poApp.sorted(by: { $0.value.vsego > $1.value.vsego }).prefix(8) {
                out += "  \(app): \(a.vsego) · \(a.net) · \(a.nechem)\n"
            }
        }
        if !poDnyam.isEmpty {
            out += "\nПо дням (вставок / починок руками):\n"
            for (den, p) in poDnyam.sorted(by: { $0.key < $1.key }) {
                out += "  \(den): \(p.0) / \(p.1)\n"
            }
        }
        out += "\nЖурнал: \(url.path)"
        return out
    }
}
