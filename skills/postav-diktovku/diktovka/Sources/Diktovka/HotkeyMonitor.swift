import AppKit
import CoreGraphics

/// Три горячие клавиши (все — правые; device-маски из IOLLEvent.h в нижних 16 битах
/// флагов события): ⌘ 0x10 = диктовка (рация), ⌥ 0x40 = реплей истории,
/// ⇧ 0x04 = озвучка выделенного.
///
/// МЕХАНИКА (после инцидентов 26-27.07): основной канал — CGEventTap (listen-only).
/// NSEvent-мониторы система молча отключает при задержках главного потока, и они
/// НЕ умеют оживать; тапу же приходит событие tapDisabledByTimeout — включаем
/// себя обратно сами. Если тап создать не удалось (нет прав) — fallback на
/// NSEvent-мониторы, как раньше. ensureAlive() зовётся таймером раз в минуту.
///
/// Анти-конфликт: любая обычная клавиша при зажатом модификаторе = шорткат/
/// спецсимвол/Заглавная, а не жест → жест отменяется (для ⌘ — onOtherKey).
final class HotkeyMonitor {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onOtherKey: (() -> Void)?
    var onLatch: (() -> Void)?       // ⌘ держат ≥3 с: запись зафиксирована, палец можно убрать
    var onHandsFree: (() -> Void)?   // палец убран, но запись держится фиксацией
    var onCmdFreed: (() -> Void)?    // правый ⌘ физически отпущен после стоп-удара — печатать можно
    var onReplayTap: (() -> Void)?   // правый ⌥: удержан ≥0.2 с, отпущен чисто
    var onReplayHold: (() -> Void)?  // правый ⌥ ДЕРЖИТСЯ ≥0.45 с: открыть буфер диктовок
    var paletteOpen: (() -> Bool)?   // AppDelegate отвечает: открыт ли буфер сейчас
    var onSpeakTap: (() -> Void)?    // правый ⇧: удержан ≥0.2 с, отпущен чисто
    var onCleanTap: (() -> Void)?    // правые ⌥+⇧ ВМЕСТЕ: почистить выделенный текст
    var onTermsTap: (() -> Void)?    // клавиша Ю (код 47) ЗАЖАТА ≥0.5 с: запомнить термины
    var onBTTap: (() -> Void)?       // клавиша Б (код 43) ЗАЖАТА ≥0.5 с: тумблер Bluetooth
    var onVoiceTap: (() -> Void)?    // клавиша K/Л (код 40) ЗАЖАТА ≥0.5 с: вкл/выкл нейро-голос
    var onSpeedTap: ((Int) -> Void)?    // ←/→ во время чтения: скорость ±шаг
    var onSeekTap: ((Double) -> Void)?  // ↑/↓ во время чтения: перемотка ±15 с
    var isReading: (() -> Bool)?        // AppDelegate отвечает: идёт ли озвучка

    private var monitors: [Any] = []       // fallback NSEvent
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?

    private var comboHeld = false
    private var optHeld = false
    private var optPressedAt: Date?
    private var optDirty = false
    private var shiftHeld = false
    private var shiftPressedAt: Date?
    private var shiftDirty = false
    private var pairGesture = false   // правые ⌥+⇧ зажаты вместе — ждём отпускания обеих
    private var pendingKey: Int64?    // Б/Ю съедена: отпустил быстро = буква, держит = жест
    private var pendingFired = false  // жест по удержанию уже сработал (доедаем автоповтор)
    private var pendingHold: DispatchWorkItem?
    private var pendingAt = Date.distantPast  // когда съели down — страховка от застревания
    private let holdGestureMin: TimeInterval = 0.5
    private static let syntheticMark: Int64 = 0xD1C7   // метка наших синтетических букв
    private let termsKeyCode: Int64 = 47          // kVK_ANSI_Period = русская «ю» (выбор автора)
    private let btKeyCode: Int64 = 43             // kVK_ANSI_Comma = русская «б» (выбор автора 04.08)
    private let voiceKeyCode: Int64 = 40          // kVK_ANSI_K = русская «л» (выбор автора 13.08)
    private let rightCmdMask: UInt = 0x0010
    private let rightOptMask: UInt = 0x0040
    private let rightShiftMask: UInt = 0x0004
    private let tapHoldMin: TimeInterval = 0.2
    /// Просьба автора 18.09.2026: «зажал чуть-чуть — вставился, как раньше; держу больше
    /// чем чуть-чуть — открывается буфер». Отсюда две границы на одной клавише: 0.2 с —
    /// вставка, 0.45 с — палитра. Палитра открывается ПО ТАЙМЕРУ, не дожидаясь отпускания:
    /// иначе её не увидеть, пока держишь палец, и жест читается как задержка.
    private let paletteHoldMin: TimeInterval = 0.45
    private var optHoldTimer: DispatchWorkItem?
    private var paletteOpenedByHold = false   // палитру открыло это удержание → отпускание не вставляет
    /// ФИКСАЦИЯ диктовки (просьба автора 03.09.2026: «зажал больше трёх секунд —
    /// уведомление, можешь отпускать палец»). ⌘ держится дольше latchAfter → пишем
    /// дальше без пальца, стоп — повторным ударом по тому же ⌘. Пока держит фиксация,
    /// соседние клавиши запись НЕ роняют и голосовые жесты (⌥/⇧/Б/Ю/Л) молчат.
    private var latched = false
    private var latchWork: DispatchWorkItem?
    private var latchHardWork: DispatchWorkItem?   // предохранитель: фиксация не вечная
    private var stopOnPress = false      // повторный ⌘ уже остановил — отпускание молчит
    private let latchAfter: TimeInterval = 3.0
    private let latchHardLimit: TimeInterval = 1800  // полчаса — и отпускаем клавиатуру сами

    var isHeld: Bool { comboHeld }
    var isLatched: Bool { latched }

    /// Снять фиксацию снаружи: сессия закрылась не клавишей (термостоп, срыв входа,
    /// авто-стоп по тишине) — иначе следующий ⌘ был бы понят как «стоп» и не записал
    func cancelLatch() {
        latchWork?.cancel(); latchWork = nil
        latchHardWork?.cancel(); latchHardWork = nil
        if latched { AppLog.log("монитор: фиксация снята, клавиатура свободна") }
        latched = false
        stopOnPress = false
    }

    private func scheduleLatch() {
        latchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.comboHeld, !self.latched else { return }
            self.latched = true
            AppLog.log("монитор: ⌘ держится \(self.latchAfter) с — фиксирую запись, клавиатура заперта")
            self.onLatch?()
            self.armHardLimit()
        }
        latchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + latchAfter, execute: w)
    }

    /// Клавиатура не может остаться запертой навсегда: через полчаса фиксация
    /// снимается сама и сессия честно закрывается, что бы ни случилось выше.
    /// Полчаса, а не пятнадцать минут (19.09.2026): забытую фиксацию ловит тишина за 25 с,
    /// так что сюда доживает только НЕПРЕРЫВНАЯ речь — её обрывать нельзя.
    private func armHardLimit() {
        latchHardWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.latched else { return }
            AppLog.log("монитор: ПРЕДОХРАНИТЕЛЬ — фиксация висит полчаса, отпускаю клавиатуру")
            self.cancelLatch()
            self.onRelease?()
        }
        latchHardWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + latchHardLimit, execute: w)
    }

    /// Идемпотентен: пересоздаёт канал событий с нуля
    func start() {
        stopAll()
        if startEventTap() {
            AppLog.log("клавиши: CGEventTap установлен (самовосстанавливающийся)")
        } else {
            AppLog.log("клавиши: CGEventTap недоступен — fallback на NSEvent-мониторы")
            startNSEventMonitors()
        }
    }

    /// Сторож зовёт НЕ с главного потока: главный встал — отпустить клавиатуру, чтобы
    /// система не ждала таймаут на каждую клавишу (13.09.2026: буквы по одной в 20 с)
    func releaseTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    /// Лёгкая проверка живости (таймер раз в минуту): включает выключенный тап
    func ensureAlive() {
        if let tap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                AppLog.log("тап оказался выключен — включаю обратно")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        } else if monitors.isEmpty {
            start()
        }
    }

    // MARK: - Каналы событий

    private func stopAll() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        if let src = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            tapSource = nil
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            tap = nil
        }
    }

    private func startEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        // тап АКТИВНЫЙ (не listenOnly): жест «Ю» должен съедать своё нажатие,
        // иначе буква напечатается и затрёт выделенный текст. Всё остальное
        // пропускается нетронутым; умер процесс → система вернёт клавиатуру себе.
        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                return monitor.handleTapEvent(type: type, event: event)
                    ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    /// true = событие съедено (не дойдёт до приложений)
    private func handleTapEvent(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // главный поток замешкался и система прикрыла кран — открываем обратно
            AppLog.log("система выключила тап (код \(type.rawValue)) — включаю обратно")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // пока кран был закрыт, keyUp съеденной Б/Ю/Л мог пролететь мимо — вернуть
            // букву сейчас, иначе pendingKey застревает и клавиша «умирает» (баг 03.09)
            flushPendingLetter()
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMark {
                return false   // наша же синтетическая буква — пропустить как есть
            }
            // ФИКСАЦИЯ ЗАПЕРЛА КЛАВИАТУРУ (требование автора 03.09.2026): пока пишем без
            // пальца, ни одна обычная клавиша не доходит до приложений — ни буква в текст,
            // ни шорткат. Модификаторы (flagsChanged) пропускаем как есть, иначе система
            // сочтёт ⌘ залипшим. Выходы из блокировки: повторный правый ⌘, тишина 25 с,
            // пункт «🔓 Оживить клавиатуру» в меню (мышь мы не трогаем вообще) и
            // предохранитель на 15 минут ниже.
            if latched && !perekluchenieOkon(event) { return true }
            if arrowKeySeen(event) { return true }
            if holdKeyDown(event) { return true }
            keyDownSeen()
        case .keyUp:
            if latched && !perekluchenieOkon(event) { return true }
            if holdKeyUp(event) { return true }
        case .flagsChanged:
            flushPendingLetter()   // модификатор посреди удержания Б/Ю = печать, не жест
            processFlags(raw: UInt(event.flags.rawValue & 0xFFFF))
        default:
            break
        }
        return false
    }

    /// ⌘⇥ и ⌘` пропускаем СКВОЗЬ запертую клавиатуру (заказ автора 18.09.2026).
    ///
    /// Дословно: «иногда, когда я начинаю записывать диктовку, я хочу переключиться через
    /// Команда-Таб в другую вкладку и там поскроллить, потому что я даю фидбэк по тому, что
    /// там есть. И в этом случае у меня даже блокируется это».
    ///
    /// Блокировка клавиатуры при фиксации остаётся как была — она спасает от букв, улетающих
    /// в чужое поле. Но переключение окон ничего не печатает: это навигация, как и скролл
    /// мышью, который мы не трогали никогда. Текст при этом всё равно вернётся куда надо —
    /// за это отвечает `TargetAnchor`.
    private func perekluchenieOkon(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == 48 || code == 50 else { return false }   // ⇥ и ` (буква Ё)
        return event.flags.contains(.maskCommand)
    }

    /// Клавиши-жесты по УДЕРЖАНИЮ (правка автора 04.08: Б и Ю нужны ему в печати,
    /// «холодный тап» ложно срабатывал): Ю (точка) = запомнить термины, Б (запятая) =
    /// тумблер Bluetooth. Нажатие съедается и решается на отпускании: коротко —
    /// печатаем букву синтетически (при быстрой печати буква вылетает при следующей
    /// клавише, порядок сохраняется), держит ≥0.5 с — жест, буква не печатается
    /// (выделение для Ю остаётся целым). С модификаторами (Shift → заглавная,
    /// Cmd-шорткаты) не перехватываем вообще. Цена: автоповтор «ббб» по удержанию
    /// больше не работает — осознанный размен.
    private func holdKeyDown(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if let p = pendingKey {
            if code == p {
                // автоповтор удержания — молча съесть; но если down висит дольше 3 с,
                // это не автоповтор, а застрявший pending (keyUp потерялся, когда система
                // гасила тап) — сбросить и обработать нажатие как новое (баг Л/Ю 03.09)
                if Date().timeIntervalSince(pendingAt) < 3.0 {
                    pendingAt = Date()     // живой автоповтор освежает метку
                    return true
                }
                AppLog.log("монитор: pending \(p) застрял — сбрасываю и печатаю заново")
                pendingHold?.cancel(); pendingHold = nil
                pendingKey = nil; pendingFired = false
            } else {
                flushPendingLetter()       // печать пошла: сначала наша буква, потом чужая
            }
        }
        guard code == termsKeyCode || code == btKeyCode || code == voiceKeyCode,
              !comboHeld, !latched, !optHeld, !shiftHeld else { return false }
        let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl,
                                  .maskShift, .maskSecondaryFn]
        guard event.flags.intersection(mods).isEmpty else { return false }
        pendingKey = code
        pendingAt = Date()
        pendingFired = false
        let work = DispatchWorkItem { [weak self] in self?.firePendingGesture() }
        pendingHold = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdGestureMin, execute: work)
        return true
    }

    /// Стрелки во время чтения (правка автора 05.08): ←/→ = скорость, ↑ = +15 с,
    /// ↓ = −15 с. Вне чтения не трогаем — обычная навигация по тексту
    private var lastArrowAt = Date.distantPast

    private func arrowKeySeen(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard (123...126).contains(code), isReading?() == true,
              !comboHeld, !optHeld, !shiftHeld else { return false }
        // ВАЖНО: стрелки macOS ВСЕГДА несут maskSecondaryFn+maskNumericPad —
        // их в проверку НЕ включаем (иначе жест никогда не срабатывал, баг до 10.08).
        // Отсекаем только реальные модификаторы: Cmd/Opt/Ctrl/Shift-стрелки — навигация.
        let mods: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        guard event.flags.intersection(mods).isEmpty else { return false }
        let now = Date()
        if now.timeIntervalSince(lastArrowAt) < 0.2 { return true }  // автоповтор — глушим
        lastArrowAt = now
        AppLog.log("монитор: стрелка \(code) во время чтения")
        switch code {
        case 124: fire { self.onSpeedTap?(1) }     // →
        case 123: fire { self.onSpeedTap?(-1) }    // ←
        case 126: fire { self.onSeekTap?(15) }     // ↑
        default:  fire { self.onSeekTap?(-15) }    // ↓ (125)
        }
        return true
    }

    /// Отпускание Б/Ю: жест не успел — печатаем букву; успел — просто прибираемся
    private func holdKeyUp(_ event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        guard code == pendingKey else { return false }
        flushPendingLetter()
        return true
    }

    private func firePendingGesture() {
        guard let code = pendingKey, !pendingFired else { return }
        pendingFired = true
        pendingHold = nil
        if code == termsKeyCode {
            AppLog.log("монитор: Ю зажата — запоминаю термины из выделенного")
            fire { self.onTermsTap?() }
        } else if code == voiceKeyCode {
            AppLog.log("монитор: K/Л зажата — тумблер нейро-голоса")
            fire { self.onVoiceTap?() }
        } else {
            AppLog.log("монитор: Б зажата — тумблер Bluetooth")
            fire { self.onBTTap?() }
        }
    }

    /// Снять ожидание: если жест не сработал — синтезировать съеденную букву
    private func flushPendingLetter() {
        pendingHold?.cancel()
        pendingHold = nil
        guard let code = pendingKey else { return }
        pendingKey = nil
        if pendingFired { pendingFired = false; return }
        let src = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(code), keyDown: down)
            e?.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMark)
            e?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private func startNSEventMonitors() {
        let handleFlags: (NSEvent) -> Void = { [weak self] e in
            self?.processFlags(raw: e.modifierFlags.rawValue & 0xFFFF)
        }
        let handleKey: (NSEvent) -> Void = { [weak self] _ in self?.keyDownSeen() }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handleFlags) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in
            handleFlags(e)
            return e
        }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handleKey) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            handleKey(e)
            return e
        }) {
            monitors.append(m)
        }
    }

    // MARK: - Логика жестов (общая для обоих каналов)

    private func keyDownSeen() {
        if optHeld { optDirty = true }       // ⌥+клавиша = спецсимвол
        if shiftHeld { shiftDirty = true }   // ⇧+клавиша = Заглавная
        pairGesture = false                  // клавиша при паре = не жест чистки
        // ДО фиксации ⌘+клавиша = шорткат, запись честно отменяем; ПОСЛЕ фиксации
        // соседняя клавиша больше ничего не роняет (правка автора 03.09.2026)
        guard comboHeld, !latched else { return }
        fire { self.onOtherKey?() }
    }

    /// Тяжёлое действие НЕЛЬЗЯ делать прямо в колбэке перехвата (правка 04.09.2026).
    /// Старт аудио — 0.4 с, тумблер Bluetooth — 3 с, чистка текста — поход к ИИ; пока
    /// колбэк не вернулся, система считает тап зависшим и РУБИТ его
    /// (.tapDisabledByTimeout, код 0xFFFFFFFE — в логе 78 отвалов). Внешне это
    /// «жесты вдруг перестали реагировать»: до включения обратно клавиатура немая.
    /// Решение о съедании клавиши остаётся синхронным, само действие уходит в
    /// следующий виток главного цикла — очередь последовательная, порядок жестов цел.
    private func fire(_ body: @escaping () -> Void) {
        DispatchQueue.main.async(execute: body)
    }
    private func processFlags(raw: UInt) {
        let cmdNow = (raw & rightCmdMask) != 0
        let optNow = (raw & rightOptMask) != 0
        let shiftNow = (raw & rightShiftMask) != 0

        // правый ⌘ — рация; после трёх секунд удержания он же становится тумблером
        if cmdNow != comboHeld {
            comboHeld = cmdNow
            AppLog.log("монитор: правый ⌘ \(cmdNow ? "нажат" : "отпущен") [колбэк=\(cmdNow ? (onPress == nil ? "NIL!" : "есть") : (onRelease == nil ? "NIL!" : "есть")), main=\(Thread.isMainThread), фикс=\(latched)]")
            if cmdNow {
                if latched {
                    AppLog.log("монитор: повторный ⌘ — снимаю фиксацию, заканчиваю запись")
                    cancelLatch()
                    stopOnPress = true
                    fire { self.onRelease?() }
                } else {
                    fire { self.onPress?() }
                    scheduleLatch()
                }
            } else {
                latchWork?.cancel(); latchWork = nil
                if stopOnPress {
                    stopOnPress = false          // это отпускание после стоп-удара
                    fire { self.onCmdFreed?() }  // текст ждал именно этого момента (баг 13.09)
                } else if latched {
                    AppLog.log("монитор: палец убран, но запись зафиксирована — пишу дальше")
                    fire { self.onHandsFree?() }
                } else {
                    fire { self.onRelease?() }
                }
            }
        }

        // правый ⌥ — реплей истории; удержание — буфер диктовок
        if optNow != optHeld {
            optHeld = optNow
            if optNow {
                optPressedAt = Date()
                optDirty = comboHeld || shiftNow
                paletteOpenedByHold = false
                // держит дольше paletteHoldMin — открываем буфер, не дожидаясь отпускания.
                // Пока буфер уже открыт, повторный ⌥ — это перещёлкивание, а не второе открытие.
                optHoldTimer?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.optHeld, !self.optDirty, !self.comboHeld, !self.latched else { return }
                    // панель закрыта → открыть; уже открыта → это «вставить выбранное».
                    // Решает AppDelegate, монитор только сообщает о жесте.
                    self.paletteOpenedByHold = true
                    self.onReplayHold?()
                }
                optHoldTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + paletteHoldMin, execute: work)
            } else {
                optHoldTimer?.cancel(); optHoldTimer = nil
                let heldEnough = optPressedAt.map { Date().timeIntervalSince($0) >= tapHoldMin } ?? false
                // отпустили то самое удержание, что открыло буфер → ничего не вставляем:
                // человек ещё выбирает. Обычный тап при открытом буфере = перещёлкнуть.
                if !optDirty && heldEnough && !comboHeld && !latched && !paletteOpenedByHold {
                    fire { self.onReplayTap?() }
                }
                paletteOpenedByHold = false
                optPressedAt = nil
                optDirty = false
            }
        }

        // правый ⇧ — озвучка выделенного
        if shiftNow != shiftHeld {
            shiftHeld = shiftNow
            if shiftNow {
                shiftPressedAt = Date()
                shiftDirty = comboHeld || optNow
            } else {
                let heldEnough = shiftPressedAt.map { Date().timeIntervalSince($0) >= tapHoldMin } ?? false
                if !shiftDirty && heldEnough && !comboHeld && !latched { fire { self.onSpeakTap?() } }
                shiftPressedAt = nil
                shiftDirty = false
            }
        }

        // сочетания правых модификаторов между собой гасят одиночные жесты
        if optHeld && (cmdNow || shiftNow) { optDirty = true }
        if shiftHeld && (cmdNow || optNow) { shiftDirty = true }

        // правые ⌥+⇧ вместе (без ⌘) — жест «почистить выделенный текст»;
        // срабатывает на отпускании ОБЕИХ, чтобы синтетические Cmd+C/Cmd+V
        // не смешались с ещё зажатыми модификаторами
        if optHeld && shiftHeld && !comboHeld && !latched { pairGesture = true }
        if comboHeld { pairGesture = false }
        if pairGesture && !optHeld && !shiftHeld {
            pairGesture = false
            AppLog.log("монитор: правые ⌥+⇧ — чистка выделенного")
            fire { self.onCleanTap?() }
        }
    }
}
