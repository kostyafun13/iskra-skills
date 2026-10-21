import AppKit

/// Вставка текста в активное поле.
///
/// ГЛАВНЫЙ путь (правка автора 07.08 после инцидента с подменой): текст
/// «впечатывается» напрямую юникод-событиями клавиатуры, БЕЗ буфера обмена.
/// Причина: раньше вставляли через буфер + Cmd+V, и если пока шло распознавание
/// пользователь копировал что-то в другом окне, Cmd+V выдёргивал ЧУЖУЮ копию
/// (реальный баг: вместо диктовки вставился скопированный ответ). Печать символами
/// вообще не трогает буфер — параллельное копирование больше не мешает.
///
/// Запасной путь (буфер + Cmd+V) — только для МНОГОСТРОЧНОГО текста (заготовки со
/// ссылками): при печати символами перевод строки в чатах = Enter = досрочная
/// отправка. Многострочное вставляется осознанно, гонка с буфером там маловероятна.
final class TextInserter {
    private var savedItems: [NSPasteboardItem]?
    private var restoreWork: DispatchWorkItem?
    private let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        if text.contains("\n") {
            insertViaPasteboard(text)   // многострочное (заготовки) — прежним путём
        } else {
            Self.typeUnicode(text)      // диктовка — печатью, буфер не трогаем
            AppLog.log("впечатано символами (\(text.count)), буфер не тронут")
        }
    }

    /// Печать текста юникод-событиями: буфер обмена не участвует. Бьём на куски
    /// (лимит одного CGEvent — ~20 UTF-16 юнитов), между кусками микропауза, чтобы
    /// приёмник не потерял символы при быстрой очереди.
    static func typeUnicode(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunk = 18
        var i = 0
        while i < units.count {
            let slice = Array(units[i ..< min(i + chunk, units.count)])
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: slice)
                // ФЛАГИ ЧИСТИМ ЯВНО (баг 13.09.2026): событие от combinedSessionState наследует
                // физически зажатые модификаторы, и буквы уезжали в приёмник как ⌘-шорткаты
                e.flags = []
                e.post(tap: .cgAnnotatedSessionEventTap)
            }
            i += chunk
            if i < units.count { usleep(1500) }   // 1.5 мс — приёмник успевает проглотить
        }
    }

    /// Зажат ли сейчас физически ⌘/⌥/⌃ (любой, не только правый): печатать в этот момент
    /// нельзя — приёмник читает буквы как шорткаты и молча глотает (13.09.2026 так
    /// пропали 1164 символа: стоп-удар по правому ⌘ закрывал сессию, а печать шла,
    /// пока палец ещё лежал на клавише)
    static func modifiersHeld() -> Bool {
        let f = CGEventSource.flagsState(.combinedSessionState)
        return !f.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
    }

    /// Старый путь для многострочного: буфер сохраняем целиком и возвращаем через
    /// 0.6 с; если пользователь за это окно скопировал новое (changeCount сдвинулся)
    /// — его копию не затираем.
    private func insertViaPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        if restoreWork == nil {
            savedItems = pb.pasteboardItems?.map { item in
                let copy = NSPasteboardItem()
                for t in item.types {
                    if let d = item.data(forType: t) { copy.setData(d, forType: t) }
                }
                return copy
            }
        }
        restoreWork?.cancel()

        pb.clearContents()
        pb.setString(text, forType: .string)
        pb.setString("", forType: transientType) // менеджеры буфера пропустят нашу вставку
        let myChange = pb.changeCount

        Self.pressKey(9, flags: .maskCommand) // kVK_ANSI_V
        AppLog.log("Cmd+V отправлен (многострочное)")

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if pb.changeCount == myChange {
                pb.clearContents()
                if let items = self.savedItems, !items.isEmpty { pb.writeObjects(items) }
            }
            self.savedItems = nil
            self.restoreWork = nil
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Эмуляция нажатия клавиши с модификаторами (нужен Универсальный доступ)
    static func pressKey(_ vKey: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = flags
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = flags
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
