import AppKit
import AVFoundation

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private let transcriber = Transcriber()
    private let thermal = ThermalGuard()
    private let inserter = TextInserter()
    private let hud = HUDController()
    private let palette = HistoryPalette()   // буфер последних диктовок (правый ⌥ подольше)
    private let anchor = TargetAnchor()      // куда вернуть текст, если автор ушёл в другое окно
    private var restoringFocus = false
    private var anchorJustRestored = false   // якорь вернул фокус перед этой вставкой — сказать автору и записать в журнал
    private var lastWaitSeconds = 0.0        // сколько ждали отпускания модификаторов — кандидат в причину утечки
    private let speaker = Speaker()
    private let watchdog = Watchdog()
    private let keepAwake = KeepAwake()
    private let keepAwakeDot = KeepAwakeDot(frame: .zero)
    private let keepAwakeRow = KeepAwakeMenuRow()
    private let keepAwakeItem = NSMenuItem(title: "Не давать компьютеру уснуть",
                                         action: #selector(toggleKeepAwake), keyEquivalent: "")

    @objc private func toggleKeepAwake() {
        if keepAwake.isEnabled {
            keepAwake.disable()
        } else if !keepAwake.enable() {
            hud.showError("Не удалось включить запрет сна", autoHide: 3)
        }
        UserDefaults.standard.set(keepAwake.isEnabled, forKey: "keepAwakeEnabled")
        refreshKeepAwake()
        AppLog.log("не давать компьютеру уснуть: \(keepAwake.isEnabled ? "вкл" : "выкл")")
    }

    private func refreshKeepAwake() {
        keepAwakeItem.state = keepAwake.isEnabled ? .on : .off
        keepAwakeRow.toggle.state = keepAwake.isEnabled ? .on : .off
        keepAwakeDot.isHidden = !keepAwake.isEnabled
        statusItem?.button?.toolTip = keepAwake.isEnabled
            ? "Диктовка — компьютер и экран не засыпают" : "Диктовка"
    }

    // Сессия диктовки: куски по порядку и их распознанные тексты.
    // При быстром повторном зажатии клавиш недовставленные куски НЕ теряются —
    // очередь живёт, пока всё не вставлено (см. pressBegan/flushReady).
    private var sessionChunkIds: [Int] = []
    private var sessionTexts: [Int: String] = [:]
    private var insertedChunks = 0
    private var insertedAnyText = false
    private var lastInsertTailChar: Character?   // чем кончилась прошлая вставка —
    private var lastInsertAt = Date.distantPast  // для пробела между диктовками подряд
    private var sessionHadError = false
    private var recordingNow = false
    private var awaitingResults = false
    private var keysHeld = false
    private var latchedNow = false               // запись держится без пальца (фиксация ⌘)
    private var lastVoiceAt = Date.distantPast   // когда последний раз слышали голос
    private var latchIdleTimer: Timer?           // страховка: тишина в фиксации → закрываем сами
    private let latchIdleLimit: TimeInterval = 25
    private var sessionGen = 0       // поколение сессии: отсекает устаревшие колбэки stop()
    private var sessionStartedAt: Date?
    private var axTimer: Timer?
    private var hudShowWork: DispatchWorkItem?
    private var flushRetryWork: DispatchWorkItem?   // печать ждёт, пока отпустят модификаторы
    private var flushWaitSince: Date?
    private var readingPaused = false        // озвучку поставили на паузу ради диктовки
    private var sessionAudioName: String?    // файл архива звука этой сессии (zapisi/…)
    private var prevRawTail: String?         // хвост предыдущего куска — контекст корректору
    private var prevRawAt = Date.distantPast
    private var voiceUnloadedByHeat = false   // красивый голос выгружен из-за нагрева — вернуть, когда остынет
    private var memPressure: DispatchSourceMemoryPressure?
    private var sessionAllText = ""  // весь текст сессии — для истории-предохранителя
    private var lastDictation: String?
    private var replayIndex = 0      // листание истории правым ⌥: 0=последняя, 1=пред…
    private var lastReplayAt: Date?
    private let replayDepth = 3      // глубина листания (просьба автора — до трёх)
    private let paletteDepth = 4     // сколько показывать в буфере (просьба автора 18.09.2026)
    private let replayChainWindow: TimeInterval = 8  // пауза дольше — снова с последней

    private let voiceMenu = NSMenu(title: "Голос озвучки")
    private let asrMenu = NSMenu(title: "Распознавание")
    private let micMenu = NSMenu(title: "Микрофон")
    private let micItem = NSMenuItem(title: "🎙 Микрофон", action: nil, keyEquivalent: "")
    private var lastChosenMicUID: String?      // что выбрал бы рекордер — ловим смену (Boya воткнули/вынули)
    private var iconSymbol = "hourglass"       // текущая иконка бара — чтобы перерисовать с бейджем
    private var iconTint: NSColor?
    private var iconCheck = false
    /// «Б» в углу иконки, пока звук идёт с внешнего микрофона (Boya) — правка автора 13.09.2026
    private var externalMicBadge: String? {
        guard let d = AudioRecorder.chooseDevice().device, !d.isBuiltIn else { return nil }
        return "Б"
    }
    private var micChangeWork: DispatchWorkItem?
    private var showMicInHUD: Bool {           // подпись микрофона в плашке записи (тумблер в меню)
        UserDefaults.standard.object(forKey: "showMicInHUD") as? Bool ?? true
    }
    private let hintItem = NSMenuItem(title: "Зажми ПРАВЫЙ ⌘ и говори", action: nil, keyEquivalent: "")
    private let modelItem = NSMenuItem(title: "Модель: запускается…", action: nil, keyEquivalent: "")
    private let thermalItem = NSMenuItem(title: "Нагрев: …", action: nil, keyEquivalent: "")
    private let voiceStateItem = NSMenuItem(title: "💤 Красивый голос спит — нажми или зажми K/Л",
                                            action: #selector(toggleNeuroVoice), keyEquivalent: "")
    private var voiceWarmNow = false   // нейро-голос в памяти (галочка на иконке бара)
    private let autoFixItem = NSMenuItem(title: "✨ Править каждую диктовку (ИИ)",
                                         action: #selector(toggleAutoFix), keyEquivalent: "")

    /// Авто-правка каждой диктовки ИИ-корректором (заказ автора 01.08.2026); дефолт ВКЛ
    var autoFixEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoFixEnabled") as? Bool ?? true
    }

    @objc private func toggleAutoFix() {
        UserDefaults.standard.set(!autoFixEnabled, forKey: "autoFixEnabled")
        autoFixItem.state = autoFixEnabled ? .on : .off
        hud.showError(autoFixEnabled ? "✨ Авто-правка диктовок ВКЛ" : "Авто-правка диктовок выкл",
                      autoHide: 1.5)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // сборка, собранная при живом приложении, подхватывается при ЛЮБОМ запуске
        // (апплет с рабочего стола, open), а не только через меню (правка 13.09.2026)
        if Relaunch.hasStagedBuild {
            AppLog.log("нашёл Diktovka.new.app — подменяю сборку и перезапускаюсь")
            Relaunch.now(exitCode: 0)
        }
        CrashRelaunch.install()
        setupStatusItem()
        if UserDefaults.standard.bool(forKey: "keepAwakeEnabled"), !keepAwake.enable() {
            hud.showError("Не удалось восстановить запрет сна", autoHide: 3)
        }
        refreshKeepAwake()
        wire()
        // сторож главного потока: завис — отпускаем клавиатуру, дольше 30 с — перезапуск
        watchdog.onRelease = { [weak self] in self?.hotkey.releaseTap() }
        watchdog.onRecover = { [weak self] in
            guard let self, Permissions.accessibilityTrusted else { return }
            self.hotkey.ensureAlive()
        }
        watchdog.start()
        Permissions.requestMicrophone { [weak self] ok in
            if !ok { self?.modelItem.title = "⚠️ Нет доступа к микрофону" }
        }
        transcriber.start()
        startHotkeyWhenTrusted()
        refreshThermal()
        lastDictation = DictationHistory.lastEntry()
        // архив звука (правило автора 13.09.2026): записи старше недели чистим при старте
        // и раз в шесть часов — папка не растёт бесконечно
        DispatchQueue.global(qos: .utility).async { AudioArchive.cleanup() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { AudioArchive.cleanup() }
        }
        // голос №2 (vosk-tts) греется заранее, чтобы первое чтение не ждало ~40 с;
        // задержка — чтобы не толкаться с загрузкой модели распознавания
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.speaker.warmUpVoskIfNeeded()
        }
        // после сна мониторы клавиш иногда умирают — пересоздаём на пробуждении
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, Permissions.accessibilityTrusted else { return }
            AppLog.log("проснулись — пересоздаю мониторы клавиш")
            self.hotkey.start()
        }
        // страж раз в минуту: 1) оживить выключенный системой тап (безопасно в
        // ЛЮБОЙ момент — прошлый вариант блокировался «идущей» записью и не спас,
        // когда потерялось отпускание клавиши); 2) добить сессию, где палец «залип» —
        // клавиша нажата, отпускание потерялось, фиксация не включилась.
        // ФИКСАЦИЮ ЭТОТ СТРАЖ НЕ ТРОГАЕТ (баг 19.09.2026): он рубил живую диктовку ровно
        // на третьей минуте — 10:16:41 автор начал, 10:19:44 страж закрыл сессию посреди
        // фразы («потеряно отпускание?»), хотя фиксация — осознанный режим «пишу без
        // пальца», и длинная речь в нём законна. У зафиксированной сессии свои два
        // сторожа, и оба точнее времени: 25 с тишины (latchIdleTimer — ловит «забыл
        // нажать стоп» за полминуты) и предохранитель монитора на полчаса.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Permissions.accessibilityTrusted { self.hotkey.ensureAlive() }
            if self.recordingNow, !self.latchedNow, let t = self.sessionStartedAt,
               Date().timeIntervalSince(t) > 180 {
                AppLog.log("сессия дольше 3 минут БЕЗ фиксации — принудительно завершаю (потеряно отпускание?)")
                self.keysHeld = false
                self.pressEnded()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake.disable()
        transcriber.stop()
    }

    // MARK: - Меню-бар

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setIcon("hourglass", tint: nil)
        if let button = statusItem.button {
            keepAwakeDot.isHidden = true
            keepAwakeDot.attach(to: button)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        // аварийная кнопка — САМАЯ ПЕРВАЯ: если фиксация заперла клавиатуру и что-то
        // пошло не так, мышь всегда доходит до этого меню (требование автора 03.09.2026)
        menu.addItem(withTitle: "🔓 Оживить клавиатуру", action: #selector(reviveKeyboard),
                     keyEquivalent: "").target = self
        menu.addItem(.separator())
        keepAwakeItem.target = self
        keepAwakeRow.onToggle = { [weak self] in self?.toggleKeepAwake() }
        keepAwakeItem.view = keepAwakeRow
        keepAwakeItem.toolTip = "Не выключать экран и не засыпать от бездействия, пока работает Диктовка"
        menu.addItem(keepAwakeItem)
        menu.addItem(withTitle: "🧹 Закрыть всё, кроме Клода, Кодекса, Хрома, Зума и Телеги",
                     action: #selector(closeOthers), keyEquivalent: "").target = self
        menu.addItem(.separator())
        hintItem.isEnabled = false
        modelItem.isEnabled = false
        thermalItem.isEnabled = false
        menu.addItem(hintItem)
        let replayHint = NSMenuItem(title: "Правый ⌥ (держать 0.2 с) — вставить последнюю диктовку", action: nil, keyEquivalent: "")
        replayHint.isEnabled = false
        menu.addItem(replayHint)
        let speakHint = NSMenuItem(title: "Выделить текст + правый ⇧ (0.2 с) — прочитать вслух", action: nil, keyEquivalent: "")
        speakHint.isEnabled = false
        menu.addItem(speakHint)
        let cleanHint = NSMenuItem(title: "Выделить текст + правые ⌥⇧ вместе — поправить грамматику", action: nil, keyEquivalent: "")
        cleanHint.isEnabled = false
        menu.addItem(cleanHint)
        let termsHint = NSMenuItem(title: "Выделить текст + зажать Ю (полсекунды) — запомнить термины", action: nil, keyEquivalent: "")
        termsHint.isEnabled = false
        menu.addItem(termsHint)
        let btHint = NSMenuItem(title: "Зажать Б (полсекунды) — вкл/выкл Bluetooth", action: nil, keyEquivalent: "")
        btHint.isEnabled = false
        menu.addItem(btHint)
        let voiceHint = NSMenuItem(title: "Зажать K/Л (полсекунды) — вкл/выкл красивый голос", action: nil, keyEquivalent: "")
        voiceHint.isEnabled = false
        voiceHint.isHidden = Speaker.voskVoiceIds().isEmpty   // локальный нейро-голос не ставили
        menu.addItem(voiceHint)
        let arrowHint = NSMenuItem(title: "Во время чтения: ←/→ — скорость, ↑/↓ — ±15 сек", action: nil, keyEquivalent: "")
        arrowHint.isEnabled = false
        menu.addItem(arrowHint)
        let tplHint = NSMenuItem(title: "Сказать «шаблон до встречи» — вставить заготовку", action: nil, keyEquivalent: "")
        tplHint.isEnabled = false
        menu.addItem(tplHint)
        menu.addItem(modelItem)
        menu.addItem(thermalItem)
        menu.addItem(.separator())
        autoFixItem.target = self
        autoFixItem.state = autoFixEnabled ? .on : .off
        if AICleaner.loadConfig() == nil {
            // ИИ-правка работает только на своём ключе (ai.json); без него — тихая локальная чистка
            autoFixItem.title = "✨ ИИ-правка выключена — нужен свой ключ (ai.json)"
            autoFixItem.isEnabled = false
        }
        menu.addItem(autoFixItem)
        menu.addItem(withTitle: "Скопировать последнюю диктовку", action: #selector(copyLastDictation), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть историю диктовок", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть чёрный ящик (всё распознанное)", action: #selector(openRawLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть записи звука (архив 7 дней)", action: #selector(openArchive), keyEquivalent: "").target = self
        menu.addItem(withTitle: "📊 Что впечаталось в окно (за 7 дней)", action: #selector(openAudit), keyEquivalent: "").target = self
        micMenu.delegate = self
        micMenu.autoenablesItems = false
        micItem.submenu = micMenu
        menu.addItem(micItem)
        voiceStateItem.target = self
        voiceStateItem.isHidden = Speaker.voskVoiceIds().isEmpty
        menu.addItem(voiceStateItem)
        let voiceItem = NSMenuItem(title: "Голос озвучки", action: nil, keyEquivalent: "")
        voiceMenu.delegate = self
        voiceMenu.autoenablesItems = false
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)
        let asrItem = NSMenuItem(title: "Распознавание", action: nil, keyEquivalent: "")
        asrMenu.delegate = self
        asrMenu.autoenablesItems = false
        asrItem.submenu = asrMenu
        menu.addItem(asrItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Перезапустить клавиши (если зависли)", action: #selector(restartHotkeys), keyEquivalent: "").target = self
        menu.addItem(withTitle: "🔄 Перезапустить Диктовку", action: #selector(restartApp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Выдать разрешения…", action: #selector(openPermissions), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть лог движка", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Открыть лог приложения", action: #selector(openAppLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    private func setIcon(_ symbol: String, tint: NSColor?, checkmark: Bool = false) {
        iconSymbol = symbol
        iconTint = tint
        iconCheck = checkmark
        redrawIcon()
    }

    /// Перерисовать текущую иконку — с бейджем «Б», если звук идёт с внешнего микрофона.
    /// Зовётся и при смене состояния, и когда воткнули/вынули Boya (devicesChanged)
    private func redrawIcon() {
        guard let btn = statusItem?.button else { return }
        btn.image = StatusIcon.make(symbol: iconSymbol, checkmark: iconCheck,
                                    badge: externalMicBadge, template: iconTint == nil)
        btn.contentTintColor = iconTint
    }

    /// Иконка покоя: микрофон с галочкой = нейро-голос в памяти, читаем красиво
    /// (правка автора 13.08 — видеть статус голоса прямо в баре). Готового символа
    /// «mic + checkmark» в macOS НЕТ (проверено по CoreGlyphs: только plus/xmark),
    /// поэтому рисуем сами (StatusIcon): mic.fill + вырез + галочка в углу, как системные бейджи.
    private func setIdleIcon() {
        setIcon(voiceWarmNow ? "mic.fill" : "mic", tint: nil, checkmark: voiceWarmNow)
    }

    /// Нейро-голос сменил состояние (прогрелся/выгружен) — галочка в баре и меню
    private func voiceStateChanged(_ warm: Bool) {
        let was = voiceWarmNow
        voiceWarmNow = warm
        voiceStateItem.state = warm ? .on : .off
        voiceStateItem.title = warm
            ? "🟢 Красивый голос в памяти — нажми/зажми K/Л, чтобы выгрузить"
            : "💤 Красивый голос спит — нажми/зажми K/Л, чтобы включить (~30 с)"
        if !recordingNow && !thermal.isTooHot, case .ready = transcriber.state { setIdleIcon() }
        if warm != was {
            hud.showError(warm ? "🟢 Красивый голос готов" : "💤 Красивый голос выгружен", autoHide: 1.6)
        }
    }

    /// Зажатие K/Л (или клик в меню): вкл/выкл нейро-голос руками
    @objc private func toggleNeuroVoice() {
        if speaker.voiceLoaded {
            AppLog.log("нейро-голос: выгружаю по команде автора")
            speaker.unloadVoice()
        } else {
            AppLog.log("нейро-голос: грею по команде автора")
            hud.showError("🔥 Грею красивый голос (~30 с) — появится галочка на микрофоне", autoHide: 2.5)
            speaker.warmUpVoskIfNeeded()
        }
    }

    // MARK: - Разрешения и старт клавиш

    /// Глобальный монитор, поставленный ДО выдачи Универсального доступа, молчит
    /// до перезапуска — поэтому ставим его только после выдачи (опрос раз в секунду).
    private func startHotkeyWhenTrusted() {
        if Permissions.ensureAccessibility(prompt: true) {
            hotkey.start()
            return
        }
        // МОЛЧАЛИВЫЙ ОТКАЗ БОЛЬШЕ НЕ ДОПУСКАЕМ (инцидент 03.09.2026): после пересборки
        // macOS отзывает Универсальный доступ (сменился cdhash ad-hoc подписи), клавиши
        // не поднимаются, а приложение выглядит живым — «диктовка не запускается, молчок».
        // Теперь: иконка-предупреждение в баре, плашка, сами открываем нужные настройки
        // и напоминаем каждые 20 с, пока доступ не выдан.
        AppLog.log("клавиши: НЕТ Универсального доступа — жду выдачи, напоминаю плашкой")
        hintItem.title = "⚠️ Выдай «Универсальный доступ» — и клавиши оживут"
        setIcon("exclamationmark.triangle.fill", tint: .systemOrange)
        hud.showError("⌨️ Клавиши мертвы: выдай Диктовке «Универсальный доступ»", autoHide: 6)
        Permissions.openAccessibilitySettings()
        var ticks = 0
        axTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { return }
            guard Permissions.accessibilityTrusted else {
                ticks += 1
                if ticks % 20 == 0 {
                    self.hud.showError("⌨️ Клавиши мертвы: выдай Диктовке «Универсальный доступ»",
                                       autoHide: 5)
                }
                return
            }
            t.invalidate()
            self.axTimer = nil
            self.hotkey.start()
            self.hintItem.title = "Зажми ПРАВЫЙ ⌘ и говори"
            self.hud.showError("✅ Клавиши ожили — зажми правый ⌘ и говори", autoHide: 2.5)
            self.setIdleIcon()
        }
    }

    // MARK: - Связка компонентов

    private func wire() {
        hotkey.onPress = { [weak self] in
            guard let self else { AppLog.log("onPress: AppDelegate уже нет?!"); return }
            AppLog.log("onPress: rec=\(self.recordingNow) await=\(self.awaitingResults) keys=\(self.keysHeld) state=\(String(describing: self.transcriber.state))")
            self.keysHeld = true
            // сторожок взводим ДО pressBegan: срыв внутри него (глотаемый NSException
            // аудио-системы) иначе не даёт сторожку даже запланироваться (инцидент 29.07)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, self.keysHeld, !self.recordingNow else { return }
                AppLog.log("СТОРОЖОК: нажатие было, записи нет — тихий срыв старта аудио")
                self.hud.showError("Аудио спотыкнулось 🎤 Отпусти и зажми ⌘ ещё раз", autoHide: 2.0)
            }
            self.pressBegan()
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            self.keysHeld = false
            self.pressEnded()
            self.flushReady()   // на случай сессии, закрытой термостопом/сбоем при зажатых клавишах
        }
        hotkey.onOtherKey = { [weak self] in self?.cancelSession() }
        // фиксация: ⌘ держат дольше трёх секунд — дальше пишем без пальца
        hotkey.onLatch = { [weak self] in self?.latchOn() }
        hotkey.onHandsFree = { [weak self] in self?.keysHeld = false }
        // стоп-удар по ⌘ закрыл сессию, а печатать можно только после ФИЗИЧЕСКОГО отпускания
        hotkey.onCmdFreed = { [weak self] in self?.flushReady() }
        hotkey.onReplayTap = { [weak self] in self?.replayHistory() }
        hotkey.onReplayHold = { [weak self] in self?.paletteGesture() }
        hotkey.paletteOpen = { [weak self] in self?.palette.isOpen ?? false }
        // правка автора 01.08 (вторая): правый ⇧ остаётся озвучкой (пользуется!),
        // ИИ-правка грамматики — на паре ⌥+⇧
        hotkey.onSpeakTap = { [weak self] in self?.speakSelection() }
        hotkey.onCleanTap = { [weak self] in self?.cleanSelection() }
        hotkey.onTermsTap = { [weak self] in self?.rememberTermsFromSelection() }
        hotkey.onBTTap = { [weak self] in self?.toggleBluetooth() }
        hotkey.onVoiceTap = { [weak self] in self?.toggleNeuroVoice() }
        speaker.onVoskState = { [weak self] warm in self?.voiceStateChanged(warm) }
        speaker.onNotice = { [weak self] msg in self?.hud.showError(msg, autoHide: 3.0) }
        hotkey.isReading = { [weak self] in self?.speaker.isSpeaking ?? false }
        hotkey.onSpeedTap = { [weak self] delta in
            guard let self else { return }
            let r = self.speaker.bumpRate(delta)
            self.hud.showError(String(format: "⏩ Скорость %.2g×", r), autoHide: 1.0)
        }
        hotkey.onSeekTap = { [weak self] sec in
            guard let self else { return }
            self.speaker.seek(sec)
            self.hud.showError(sec > 0 ? "⏭ +15 сек" : "⏮ −15 сек", autoHide: 0.8)
        }
        recorder.onLevel = { [weak self] l in
            guard let self else { return }
            if l > 0.08 { self.lastVoiceAt = Date() }   // порог «говорят», а не шум комнаты
            self.hud.updateLevel(l)
        }
        // микрофон: знать, с чего пишем, и говорить плашкой, когда воткнули/вынули внешний
        lastChosenMicUID = AudioRecorder.chooseDevice().device?.uid
        refreshMicTitle()
        AudioRecorder.watchDevices { [weak self] in self?.devicesChanged() }
        recorder.onChunk = { [weak self] url in
            guard let self else { return }
            let id = self.transcriber.transcribe(fileURL: url)
            self.sessionChunkIds.append(id)
            AppLog.log("кусок #\(id) отправлен в движок")
        }
        recorder.onInterrupted = { [weak self] in
            guard let self, self.recordingNow else { return }
            self.pressEnded()
            self.hud.showError("Микрофон переключился — вставляю, что успел 🎧")
        }
        transcriber.onStateChange = { [weak self] st in self?.modelStateChanged(st) }
        transcriber.onResult = { [weak self] id, text, error in
            guard let self else { return }
            if let error {
                self.sessionTexts[id] = text
                self.sessionHadError = true
                AppLog.log("кусок #\(id): ОШИБКА движка: \(error)")
                self.flushReady()
                return
            }
            AppLog.log("кусок #\(id): распознано \(text.count) символов")
            DictationHistory.appendRaw(text)   // чёрный ящик: сырьё на диск СРАЗУ
            // контекст для корректора: хвост предыдущего куска той же речи (не старше 10 мин)
            let context = Date().timeIntervalSince(self.prevRawAt) < 600 ? self.prevRawTail : nil
            self.prevRawTail = String(text.suffix(200))
            self.prevRawAt = Date()
            // голосовая заготовка: «шаблон до встречи» → готовый текст, без ИИ
            if let tpl = Templates.lookup(text) {
                AppLog.log("заготовка «\(tpl.name)» вместо диктовки")
                self.hud.showError("📋 «\(tpl.name)»", autoHide: 1.2)
                self.sessionTexts[id] = tpl.text
                self.flushReady()
                return
            }
            // триггер есть, а заготовки нет: текст НЕ вставляем (это был запрос,
            // не диктовка), сырец — в историю как предохранитель, плашка объясняет
            if let wanted = Templates.requestedName(text) {
                let names = Templates.available()
                AppLog.log("заготовка «\(wanted)» не нашлась (есть: \(names.joined(separator: ", ")))")
                DictationHistory.append(text)
                self.hud.showError("Заготовки «\(wanted)» нет" +
                    (names.isEmpty ? "" : ". Есть: \(names.joined(separator: ", "))"), autoHide: 3.0)
                self.sessionTexts[id] = ""
                self.flushReady()
                return
            }
            let fixed = WordFixes.apply(text)   // словарик терминов — всегда
            // авто-правка: кусок чинится ИИ до вставки; flushReady сам ждёт
            // sessionTexts[id] и держит порядок кусков, очередь не нужна
            if self.autoFixEnabled, fixed.count >= 12,
               let cfg = AICleaner.loadConfig(), fixed.count <= 12000 {
                AICleaner.fix(fixed, config: cfg, timeout: 12, context: context) { [weak self] ai in
                    // кусок ещё в очереди этой сессии и его никто не заполнил (дедлайн/новая сессия)
                    guard let self, self.sessionChunkIds.contains(id), self.sessionTexts[id] == nil else { return }
                    if let ai {
                        AppLog.log("кусок #\(id): поправлен ИИ (\(fixed.count) → \(ai.count) симв.)")
                        self.sessionTexts[id] = ai
                    } else {
                        self.sessionTexts[id] = TextCleaner.continueCase(TextCleaner.clean(fixed), after: context)
                    }
                    self.flushReady()
                }
                // ДЕДЛАЙН (13.09.2026, 09:17–09:22): запросы к корректору повисли без ответа и
                // без таймаута, семь кусков ждали его полторы минуты, вставка стояла. Сеть не
                // должна держать текст: не ответил за 8 с — вставляем с правкой правилами
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.sessionChunkIds.contains(id), self.sessionTexts[id] == nil else { return }
                    AppLog.log("кусок #\(id): ИИ не ответил за 8 с — вставляю с правкой правилами")
                    self.sessionTexts[id] = TextCleaner.continueCase(TextCleaner.clean(fixed), after: context)
                    self.flushReady()
                }
            } else {
                self.sessionTexts[id] = TextCleaner.continueCase(fixed, after: context)
                self.flushReady()
            }
        }
        thermal.onChange = { [weak self] _ in
            guard let self else { return }
            self.refreshThermal()
            // перегрелись во время записи: стоп; уже сказанное дораспознаем, новые сессии — блок
            if self.thermal.isTooHot && self.recordingNow { self.pressEnded() }
            // красивый голос живёт в памяти всегда (правило автора 13.09.2026); единственные
            // причины выгрузить — нагрев (здесь) и нехватка памяти (memPressure) или клавиша K
            if self.thermal.isTooHot, self.speaker.voiceLoaded {
                AppLog.log("нейро-голос: мак горячий — выгружаю, верну, когда остынет")
                self.hud.showError("🥵 Мак горячий — выгрузил красивый голос, верну, когда остынет", autoHide: 3)
                self.voiceUnloadedByHeat = true
                self.speaker.unloadVoice()
            } else if !self.thermal.isTooHot, self.voiceUnloadedByHeat {
                self.voiceUnloadedByHeat = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                    guard let self, !self.thermal.isTooHot else { return }
                    AppLog.log("нейро-голос: остыли — грею обратно")
                    self.speaker.warmUpVoskIfNeeded()
                }
            }
        }
        // нехватка памяти (8 ГБ): критическое давление → отдать 0,7 ГБ голоса системе
        let mp = DispatchSource.makeMemoryPressureSource(eventMask: [.critical], queue: .main)
        mp.setEventHandler { [weak self] in
            guard let self, self.speaker.voiceLoaded else { return }
            AppLog.log("нейро-голос: памяти критически мало — выгружаю (K — вернуть)")
            self.hud.showError("🧠 Памяти мало — выгрузил красивый голос, K — вернуть", autoHide: 3)
            self.speaker.unloadVoice()
        }
        mp.resume()
        memPressure = mp
    }

    // MARK: - Сессия диктовки

    private func pressBegan() {
        // логируем каждый выход: инцидент «⌘ не прожимается» дважды был немым
        guard !recordingNow else {
            AppLog.log("⌘ нажат, но recordingNow=true — игнор (залипшая сессия?)")
            return
        }
        if thermal.isTooHot {
            AppLog.log("⌘ нажат: блок по нагреву")
            NSSound.beep()
            hud.showError("Распознавание невозможно: Mac слишком горячий. Дай ему остыть 🥵")
            return
        }
        transcriber.restartIfDead()
        switch transcriber.state {
        case .ready:
            break
        case .failed(let m):
            AppLog.log("⌘ нажат: движок failed: \(m)")
            hud.showError("Движок: \(m)")
            return
        default:
            AppLog.log("⌘ нажат: модель не готова (\(String(describing: transcriber.state)))")
            hud.showError("Модель ещё загружается — секунду…")
            return
        }
        guard Permissions.microphoneGranted else {
            AppLog.log("⌘ нажат: нет доступа к микрофону")
            hud.showError("Нет доступа к микрофону — «Выдать разрешения…» в меню")
            Permissions.requestMicrophone { _ in }
            return
        }
        if speaker.isSpeaking, speaker.pause() {
            // ПАУЗА, а не стоп (просьба автора 13.09.2026): «поймать озвучку на паузу, ответить
            // по ней, отпустил клавишу — читает дальше без перезапуска». Голос из динамиков
            // в микрофон не попадает: на время записи звук стоит на месте. Раньше здесь был
            // честный stop() (инцидент 12.08) — теперь честная пауза
            readingPaused = true
            AppLog.log("озвучка на паузе — диктовка поверх чтения")
        }
        do { try recorder.start() } catch {
            AppLog.log("микрофон не стартовал: \(error.localizedDescription)")
            hud.showError("Микрофон не стартовал: \(error.localizedDescription)")
            resumeReadingIfPaused()
            return
        }
        sessionAudioName = recorder.archiveURL?.lastPathComponent
        if let name = sessionAudioName { DictationHistory.appendRaw("🎙 запись \(name)") }
        hud.setDevice(showMicInHUD ? recorder.activeLabel : nil)
        AppLog.log("=== запись пошла (зажат правый ⌘)")
        recordingNow = true
        lastVoiceAt = Date()
        sessionStartedAt = Date()
        // где мы начинали: автор диктует и параллельно листает другое окно (⌘⇥),
        // а текст обязан вернуться в то поле, куда он кликнул до диктовки
        if !awaitingResults && insertedChunks == sessionChunkIds.count { anchor.capture() }
        sessionGen += 1
        // сбрасываем учёт ТОЛЬКО если от прошлой сессии ничего не висит —
        // иначе повторное зажатие продолжает ту же очередь и хвост не теряется
        if !awaitingResults && insertedChunks == sessionChunkIds.count {
            sessionChunkIds = []
            sessionTexts = [:]
            insertedChunks = 0
            insertedAnyText = false
            sessionHadError = false
            sessionAllText = ""
        }
        awaitingResults = false
        // плашку показываем после короткой задержки: быстрый ⌘-шорткат не мигает HUD'ом
        hudShowWork?.cancel()
        let show = DispatchWorkItem { [weak self] in
            guard let self, self.recordingNow else { return }
            self.hud.showRecording()
        }
        hudShowWork = show
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: show)
        setIcon("mic.fill", tint: .systemRed)
    }

    /// Нажали обычную клавишу при зажатом правом ⌘ — это шорткат, а не диктовка:
    /// запись отменяем, звук выбрасываем, ничего не вставляем.
    private func cancelSession() {
        guard recordingNow else { return }
        AppLog.log("отмена: чужая клавиша при зажатом ⌘ (шорткат) — звук выброшен")
        recordingNow = false
        latchOff()
        sessionGen += 1
        hudShowWork?.cancel()
        recorder.cancel()
        resumeReadingIfPaused()
        insertedChunks = sessionChunkIds.count   // ушедшее в движок не вставляем
        awaitingResults = false
        sessionHadError = false
        hud.hide()
        refreshThermal()
        if !thermal.isTooHot { setIdleIcon() }
    }

    /// ⌘ держат дольше трёх секунд: дальше пишем без пальца, стоп — повторным ⌘.
    /// Страховка от «забыл нажать»: 25 с тишины — закрываем сессию сами и вставляем
    /// текст (потерять надиктованное хуже, чем закрыть на секунду раньше).
    private func latchOn() {
        guard recordingNow else { hotkey.cancelLatch(); return }   // записи нет — фиксировать нечего
        latchedNow = true
        lastVoiceAt = Date()
        AppLog.log("=== фиксация: пишу без пальца, стоп — повторный правый ⌘")
        // БЕЗ БОЛЬШОЙ ПЛАШКИ (правка автора 04.09.2026): текст поверх эквалайзера читался
        // как «запись пропала» — он отпускал палец. Хватает замочка прямо в эквалайзере
        hud.showRecording(latched: true)
        setIcon("lock.fill", tint: .systemRed)
        latchIdleTimer?.invalidate()
        latchIdleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.latchedNow, self.recordingNow else { return }
            guard Date().timeIntervalSince(self.lastVoiceAt) >= self.latchIdleLimit else { return }
            AppLog.log("фиксация: тишина \(Int(self.latchIdleLimit)) с — закрываю сессию сам")
            self.hud.showError("⏹ Тишина — закончил сам, вставляю текст", autoHide: 2.0)
            self.keysHeld = false
            self.pressEnded()
        }
    }

    /// Сессия кончилась (клавишей, тишиной, термостопом, срывом входа) — снять фиксацию
    /// Аварийный выход из блокировки: снять фиксацию, закрыть сессию (текст не теряем —
    /// pressEnded вставит распознанное) и пересоздать канал клавиш с нуля
    @objc private func reviveKeyboard() {
        AppLog.log("МЕНЮ: оживляю клавиатуру — снимаю фиксацию и пересоздаю тап")
        latchOff()
        keysHeld = false
        if recordingNow { pressEnded() }
        hotkey.start()
        hud.showError("🔓 Клавиатура свободна", autoHide: 1.5)
        if !recordingNow { setIdleIcon() }
    }

    private func latchOff() {
        latchIdleTimer?.invalidate()
        latchIdleTimer = nil
        latchedNow = false
        hotkey.cancelLatch()
    }

    private func pressEnded() {
        guard recordingNow else { return }
        recordingNow = false
        latchOff()
        hudShowWork?.cancel()
        hud.endRecording()   // эквалайзер не должен пережить сессию (зависание 13.09)
        setIdleIcon()
        sessionGen += 1
        let gen = sessionGen
        recorder.stop { [weak self] in
            guard let self, self.sessionGen == gen else { return } // сессию уже перезапустили/закрыли
            self.awaitingResults = true
            if self.sessionChunkIds.isEmpty {
                self.awaitingResults = false
                AppLog.log("сессия пуста: ни одного куска (тихо/коротко)")
                self.hud.showError("Не расслышал 🤔 Говори ближе к микрофону", autoHide: 1.8)
                return
            }
            if self.insertedChunks < self.sessionChunkIds.count { self.hud.showProcessing() }
            self.flushReady()
        }
        resumeReadingIfPaused()   // микрофон уже снят — чтение продолжается с места паузы
    }

    /// Озвучка стояла на паузе ради диктовки — читаем дальше с того же места
    private func resumeReadingIfPaused() {
        guard readingPaused else { return }
        readingPaused = false
        speaker.resume()
        AppLog.log("озвучка продолжена с места паузы")
    }

    /// Вставляем готовые куски строго по порядку — и только когда клавиши отпущены
    /// (эмуляция Cmd+V при зажатых правых ⌥+⌘ смешала бы модификаторы).
    private func flushReady() {
        guard awaitingResults, !keysHeld, !recordingNow else { return }
        // ПЕЧАТАТЬ ТОЛЬКО ПРИ ОТПУЩЕННЫХ МОДИФИКАТОРАХ (баг 13.09.2026): стоп-удар по правому ⌘
        // закрывал сессию, и первая пачка печаталась, пока ⌘ ещё физически зажат — приёмник
        // читал символы как ⌘-шорткаты и молча глотал (1164 символа в 08:13, 183 в 08:16,
        // 315 накануне в 17:30; автор восстанавливал их ⌘A + правым ⌥). Ждём отпускания,
        // проверяя каждые 50 мс; дольше 3 с — печатаем с чистыми флагами, чтобы не зависнуть
        if hotkey.isHeld || TextInserter.modifiersHeld() {
            if flushWaitSince == nil {
                flushWaitSince = Date()
                AppLog.log("вставка ждёт: модификатор ещё зажат")
            }
            if Date().timeIntervalSince(flushWaitSince!) < 3 {
                flushRetryWork?.cancel()
                let w = DispatchWorkItem { [weak self] in self?.flushReady() }
                flushRetryWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: w)
                return
            }
            AppLog.log("вставка: модификатор зажат дольше 3 с — печатаю с чистыми флагами")
        }
        lastWaitSeconds = flushWaitSince.map { Double(round(10 * Date().timeIntervalSince($0)) / 10) } ?? 0
        flushWaitSince = nil
        flushRetryWork?.cancel()
        flushRetryWork = nil
        // фокус уехал в другое окно — сперва вернуть его туда, где диктовали, потом печатать
        if anchor.needsRestore {
            guard !restoringFocus else { return }
            restoringFocus = true
            anchor.restore { [weak self] in
                self?.restoringFocus = false
                self?.anchorJustRestored = true
                self?.flushReady()
            }
            return
        }
        var toInsert = ""
        var pokazalZametku = false   // «↩︎ вернул» не гасим тут же финальным hide()
        while insertedChunks < sessionChunkIds.count,
              let t = sessionTexts[sessionChunkIds[insertedChunks]] {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                if insertedAnyText || !toInsert.isEmpty { toInsert += " " }
                toInsert += clean
            }
            insertedChunks += 1
        }
        if !toInsert.isEmpty {
            // диктовки подряд слипались («предложениями.Я подумал» — правка автора
            // 01.08): прошлая вставка была недавно и кончилась не пробелом → пробел
            if !insertedAnyText, let prev = lastInsertTailChar,
               Date().timeIntervalSince(lastInsertAt) < 600,
               !prev.isWhitespace, !toInsert.first!.isPunctuation {
                toInsert = " " + toInsert
            }
            AppLog.log("вставляю \(toInsert.count) символов")
            inserter.insert(toInsert)
            // что впечаталось и доехало ли — журнал `vstavki.jsonl` (заказ автора 19.09.2026)
            let vernul = anchorJustRestored
            anchorJustRestored = false
            InsertAudit.vstavka(text: toInsert,
                                put: toInsert.contains("\n") ? "буфер" : "печать",
                                nachali: anchor.podpis,
                                vernul: vernul,
                                zhdal: lastWaitSeconds)
            if vernul { hud.showNote("↩︎ вернул в «\(anchor.podpis)»"); pokazalZametku = true }
            insertedAnyText = true
            sessionAllText += toInsert
            lastInsertTailChar = toInsert.last
            lastInsertAt = Date()
        }
        if insertedChunks == sessionChunkIds.count {
            awaitingResults = false
            // предохранитель: диктовка целиком — в локальную историю
            let whole = sessionAllText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !whole.isEmpty {
                lastDictation = whole
                DictationHistory.append(whole, audio: sessionAudioName)
                replayIndex = 0        // новая диктовка — листание снова с последней
                palette.close(insert: false)   // и буфер убираем: он про старое, а тут новое
                lastReplayAt = nil
            }
            hud.endProcessing()   // хвоста больше нет — плашки ниже гаснут, а не зовут спиннер
            if sessionHadError {
                hud.showError("Часть не распозналась — движок ругнулся, см. лог", autoHide: 2.5)
            } else if insertedAnyText {
                if !pokazalZametku { hud.hide() }
            } else {
                hud.showError("Не расслышал 🤔", autoHide: 1.5)
            }
            sessionHadError = false
        }
    }

    /// Движок умер посреди сессии: останавливаем запись, вставляем уже распознанное,
    /// остальное честно объявляем потерянным.
    private func failActiveSession(_ msg: String) {
        let hadWork = recordingNow || awaitingResults || insertedChunks < sessionChunkIds.count
        if recordingNow {
            recordingNow = false
            latchOff()
            sessionGen += 1
            recorder.stop { }
            resumeReadingIfPaused()
            hud.endRecording()
        }
        if insertedChunks < sessionChunkIds.count {
            awaitingResults = true
            flushReady() // вставит куски, чьи результаты уже пришли (если клавиши отпущены)
        }
        awaitingResults = false
        sessionChunkIds = []
        sessionTexts = [:]
        insertedChunks = 0
        sessionHadError = false
        // что успело вставиться — сохраняем в историю, не теряем
        let whole = sessionAllText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !whole.isEmpty {
            lastDictation = whole
            DictationHistory.append(whole)
            sessionAllText = ""
        }
        hud.endProcessing()
        if hadWork { hud.showError(msg, autoHide: 3.5) }
    }

    // MARK: - Статусы

    private func modelStateChanged(_ st: Transcriber.State) {
        switch st {
        case .idle, .starting:
            modelItem.title = "Модель: запускается…"
            setIcon("hourglass", tint: nil)
        case .loadingModel:
            modelItem.title = "Модель: загружается (первый раз качает ~230 МБ)…"
            setIcon("hourglass", tint: nil)
        case .ready:
            modelItem.title = Transcriber.cloudOnly
                ? "Распознавание: облако Яндекса (≈0,65 ₽ за минуту речи)"
                : "Модель: готова (GigaAM v3, локально)"
            if !recordingNow && !thermal.isTooHot { setIdleIcon() }
        case .failed(let m):
            modelItem.title = "⚠️ \(m)"
            setIcon("mic.slash", tint: .systemGray)
            failActiveSession("Движок распознавания упал — часть текста потеряна. Зажми клавиши ещё раз.")
        }
    }

    private func refreshThermal() {
        thermalItem.title = "Нагрев: " + ThermalGuard.label(for: thermal.state)
        if thermal.isTooHot {
            setIcon("thermometer.high", tint: .systemOrange)
        } else if !recordingNow, case .ready = transcriber.state {
            setIdleIcon()
        }
    }

    // MARK: - Действия меню

    @objc private func restartHotkeys() {
        guard Permissions.accessibilityTrusted else {
            hud.showError("Сначала выдай «Универсальный доступ»", autoHide: 2.0)
            return
        }
        AppLog.log("клавиши перезапущены вручную из меню")
        hotkey.start()
        hud.showError("Клавиши перезапущены ✔️", autoHide: 1.3)
    }

    /// Кнопка «перезапустить приложение» (просьба автора 07.08). С 13.09.2026 — через
    /// `Relaunch` (open после выхода), а не launchctl kickstart: kickstart -k не убивал
    /// экземпляр, запущенный через open, и поднимал второй. Если рядом лежит
    /// Diktovka.new.app (сборка, сделанная при живом приложении) — подменяется здесь же.
    @objc private func restartApp() {
        AppLog.log("перезапуск приложения из меню")
        hud.showError("🔄 Перезапускаю Диктовку…", autoHide: 1.5)
        transcriber.stop()
        speaker.unloadVoice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Relaunch.now(exitCode: 0) }
    }

    @objc private func openPermissions() {
        _ = Permissions.ensureAccessibility(prompt: true)
        Permissions.requestMicrophone { _ in }
        if !Permissions.accessibilityTrusted {
            Permissions.openAccessibilitySettings()
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .denied
            || AVCaptureDevice.authorizationStatus(for: .audio) == .restricted {
            Permissions.openMicrophoneSettings()
        }
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Transcriber.logURL)
    }

    // MARK: - Голос озвучки

    /// Подменю собираем при каждом открытии — скачанные в Настройках голоса
    /// появляются сами, без перезапуска
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === micMenu { buildMicMenu(menu); return }
        if menu === asrMenu { buildAsrMenu(menu); return }
        guard menu === voiceMenu else { return }
        menu.removeAllItems()
        let current = Speaker.preferredRuVoiceId
            ?? AVSpeechSynthesisVoice(language: "ru-RU")?.identifier
        for v in Speaker.russianVoices() {
            let item = NSMenuItem(title: v.name + Speaker.qualityLabel(v),
                                  action: #selector(selectVoice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v.identifier
            item.state = (v.identifier == current) ? .on : .off
            menu.addItem(item)
        }
        // облако сверху и с пометкой цены: автор выбирает его осознанно, а не вслепую
        if YandexTTS.isAvailable {
            menu.addItem(.separator())
            let head = NSMenuItem(title: "Облако — чисто, ≈0,65 ₽ за 1000 знаков", action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for v in ["alena", "filipp", "jane", "ermil", "zahar"] {
                let id = "yandex:" + v
                let item = NSMenuItem(title: YandexTTS.displayName(v),
                                      action: #selector(selectVoice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = (id == current) ? .on : .off
                menu.addItem(item)
            }
        }
        let voskIds = Speaker.voskVoiceIds()
        if !voskIds.isEmpty {
            menu.addItem(.separator())
            for id in voskIds {
                let item = NSMenuItem(title: Speaker.displayName(forVoskId: id),
                                      action: #selector(selectVoice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = (id == current) ? .on : .off
                menu.addItem(item)
            }
        }
        let piperIds = Speaker.piperVoiceIds()
        if !piperIds.isEmpty {
            menu.addItem(.separator())
            for id in piperIds {
                let item = NSMenuItem(title: Speaker.displayName(forPiperId: id),
                                      action: #selector(selectVoice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.state = (id == current) ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let dl = NSMenuItem(title: "Скачать ещё голоса… (Настройки → Устный контент)",
                            action: #selector(openSpokenContent), keyEquivalent: "")
        dl.target = self
        menu.addItem(dl)
    }

    // MARK: - Распознавание: локально, гибрид, облако

    /// Автор 18.09.2026: «посередине потока обрывается, меня это бесит». Рвал не лимит,
    /// а скорость локального движка — отсюда третий режим, где облако подхватывает затор.
    private func buildAsrMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let cur = Transcriber.route
        let punkty: [(Transcriber.Route, String)] = [
            (.local,  "Только локально — бесплатно, но на длинных потоках отстаёт"),
            (.hybrid, "Гибрид — облако подхватывает, когда локальный не успевает"),
            (.cloud,  "Только облако — быстрее всех, ≈0,65 ₽ за минуту речи"),
        ]
        for (r, title) in punkty {
            let item = NSMenuItem(title: title, action: #selector(selectRoute(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = r.rawValue
            item.state = (r == cur) ? .on : .off
            switch r {
            case .local:  item.isEnabled = Transcriber.localInstalled
            case .hybrid: item.isEnabled = Transcriber.localInstalled && YandexSTT.isAvailable
            case .cloud:  item.isEnabled = YandexSTT.isAvailable
            }
            menu.addItem(item)
        }
        if !Transcriber.localInstalled {
            let note = NSMenuItem(title: "Локальный движок не установлен — install_engine.sh", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        if transcriber.cloudChunks > 0 {
            menu.addItem(.separator())
            let info = NSMenuItem(title: String(format: "За сеанс: %d кусков облаком, ≈%.2f ₽",
                                                transcriber.cloudChunks, transcriber.cloudSpentRub),
                                  action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
    }

    @objc private func selectRoute(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let r = Transcriber.Route(rawValue: raw) else { return }
        Transcriber.route = r
        AppLog.log("распознавание: режим «\(raw)»")
        // из «только облака» в гибрид или локально — поднять движок; заголовок меню — по факту
        transcriber.restartIfDead()
        modelStateChanged(transcriber.state)
        hud.showError(r == .local ? "Распознаю локально" :
                      r == .cloud ? "Распознаю облаком" : "Гибрид: облако подхватит затор", autoHide: 1.8)
    }

    // MARK: - Микрофон (правка автора 13.09.2026: «хочу видеть, что говорю с Boya»)

    /// Подменю собираем при каждом открытии: воткнутый Boya появляется сам
    private func buildMicMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let pref = AudioRecorder.preferredUID
        let devices = AudioRecorder.inputDevices().filter { !$0.isVirtual }
        let choice = AudioRecorder.chooseDevice()

        let auto = NSMenuItem(title: "Авто: внешний микрофон, если подключён, иначе встроенный",
                              action: #selector(selectMic(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = pref == nil ? .on : .off
        menu.addItem(auto)
        let builtin = NSMenuItem(title: "Всегда встроенный микрофон мака",
                                 action: #selector(selectMic(_:)), keyEquivalent: "")
        builtin.target = self
        builtin.representedObject = AudioRecorder.builtInPref
        builtin.state = pref == AudioRecorder.builtInPref ? .on : .off
        menu.addItem(builtin)
        menu.addItem(.separator())
        for d in devices {
            var title = "\(d.name) · \(d.transportLabel)"
            if d.uid == choice.device?.uid { title += "   ← пишу с него" }
            let item = NSMenuItem(title: title, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = d.uid
            item.state = (pref == d.uid) ? .on : .off
            menu.addItem(item)
        }
        if let pref, pref != AudioRecorder.builtInPref, !devices.contains(where: { $0.uid == pref }) {
            let gone = NSMenuItem(title: "«\(AudioRecorder.preferredName ?? "выбранный микрофон")» не подключён — пишу со встроенного",
                                  action: nil, keyEquivalent: "")
            gone.isEnabled = false
            menu.addItem(gone)
        }
        menu.addItem(.separator())
        let hudToggle = NSMenuItem(title: "Показывать микрофон в плашке записи",
                                   action: #selector(toggleMicHUD), keyEquivalent: "")
        hudToggle.target = self
        hudToggle.state = showMicInHUD ? .on : .off
        menu.addItem(hudToggle)
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        AudioRecorder.preferredUID = uid.isEmpty ? nil : uid
        AudioRecorder.preferredName = AudioRecorder.inputDevices().first { $0.uid == uid }?.name
        let choice = AudioRecorder.chooseDevice()
        let name = choice.device?.name ?? "системный вход"
        AppLog.log("микрофон: настройка «\(uid.isEmpty ? "авто" : uid)» → «\(name)» (\(choice.why))")
        hud.showError("🎙 Микрофон: \(name)" + (recordingNow ? " — со следующей диктовки" : ""), autoHide: 2.2)
        lastChosenMicUID = choice.device?.uid
        refreshMicTitle()
    }

    @objc private func toggleMicHUD() {
        let now = !showMicInHUD
        UserDefaults.standard.set(now, forKey: "showMicInHUD")
        if recordingNow { hud.setDevice(now ? recorder.activeLabel : nil) }
        hud.showError(now ? "🎙 Микрофон в плашке — показываю" : "Микрофон в плашке — скрыт", autoHide: 1.6)
    }

    private func refreshMicTitle() {
        micItem.title = "🎙 Микрофон: \(AudioRecorder.chooseDevice().device?.name ?? "системный вход")"
        redrawIcon()   // бейдж «Б» на иконке — вместе с заголовком меню
    }

    /// Список аудиоустройств изменился (воткнули/вынули Boya, сели AirPods): сигналы летят
    /// пачкой — дебаунс 0.6 с, потом смотрим, поменялся ли ВЫБОР, и говорим об этом плашкой.
    /// Идущую запись не трогаем: рекордер сам переподключится, если поток встанет
    private func devicesChanged() {
        micChangeWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let choice = AudioRecorder.chooseDevice()
            let uid = choice.device?.uid
            guard uid != self.lastChosenMicUID else { return }
            self.lastChosenMicUID = uid
            self.refreshMicTitle()
            guard let dev = choice.device else { return }
            AppLog.log("микрофон: список устройств изменился → «\(dev.name)» (\(choice.why))")
            // системный вход — сразу (автор 13.09: «я же ещё в Zoom записываю»): Zoom и Телеграм
            // берут «как в системе», и Boya для них включается в момент подключения, а не при
            // первой диктовке. Отвалился внешний — macOS сама вернёт встроенный
            if !dev.isBuiltIn { AudioRecorder.ensureDefaultInput(is: dev) }
            let tail = self.recordingNow ? " — со следующей диктовки" : ""
            if dev.isBuiltIn {
                self.hud.showError("🎙 Внешний микрофон отключён — пишу с «\(dev.name)»\(tail)", autoHide: 3)
            } else {
                self.hud.showError("🎙 Подключён «\(dev.name)» — пишу с него\(tail)", autoHide: 3)
            }
        }
        micChangeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
    }

    // MARK: - Голос озвучки: выбор

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Speaker.preferredRuVoiceId = id
        AppLog.log("голос озвучки: \(sender.title)")
        speaker.speak("Так звучит выбранный голос. Привет!")
    }

    @objc private func openSpokenContent() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAppLog() {
        NSWorkspace.shared.open(AppLog.url)
    }

    /// Правый ⌥ ЗАЖАТ ≥0.45 с (просьба автора 18.09.2026): панель с четырьмя последними
    /// диктовками. Закрыта — открываем, открыта — вставляем выбранное и закрываем.
    /// Короткий ⌥ при открытой панели перещёлкивает выбор — это в replayHistory().
    private func paletteGesture() {
        guard !recordingNow, !awaitingResults else { return }
        if palette.isOpen { palette.commit(); return }
        let entries = DictationHistory.lastEntries(paletteDepth)
        guard !entries.isEmpty else {
            hud.showError("История пуста — нечего показывать", autoHide: 1.5)
            return
        }
        palette.onPick = { [weak self] text in
            guard let self else { return }
            InsertAudit.remont(vid: "палитра буфера", znakov: text.count)
            self.inserter.insert(text)
            self.replayIndex = 0     // после буфера листание начинается заново
        }
        palette.open(with: entries)
    }

    /// Правый ⌥ (≥0.2 с): вставить последнюю диктовку; повторное нажатие подряд —
    /// предпоследнюю, потом третью с конца. Пауза >8 с или новая диктовка — сброс.
    /// Если открыт буфер — тот же тап перещёлкивает выбор по кругу, а не вставляет.
    private func replayHistory() {
        guard !recordingNow else { return }
        // ⌥ ПОКА ХВОСТ РАСПОЗНАЁТСЯ (баг 25.09.2026): раньше молча ничего не делал —
        // Автор жал «докинуть остаток», не видел ни текста, ни ответа и решал, что
        // Диктовка сломалась. Хвост допечатается сам, говорим об этом вслух
        if awaitingResults || insertedChunks < sessionChunkIds.count {
            AppLog.log("реплей ⌥: хвост ещё распознаётся — не вставляю, допечатаю сам")
            hud.showNote("⏳ Хвост ещё распознаётся — допечатаю сам", autoHide: 1.8)
            return
        }
        if palette.isOpen { palette.cycle(); return }
        let now = Date()
        if let last = lastReplayAt, now.timeIntervalSince(last) > replayChainWindow { replayIndex = 0 }
        lastReplayAt = now

        let entries = DictationHistory.lastEntries(replayDepth)
        guard !entries.isEmpty else {
            hud.showError("История пуста — нечего вставлять", autoHide: 1.5)
            return
        }
        guard replayIndex < entries.count else {
            hud.showError("Глубже \(entries.count) не листаю — «Открыть историю диктовок» в меню", autoHide: 2.2)
            return
        }
        let text = entries[replayIndex]
        AppLog.log("реплей ⌥: вставляю диктовку №\(replayIndex + 1) с конца (\(text.count) симв.)")
        InsertAudit.remont(vid: "реплей ⌥ №\(replayIndex + 1)", znakov: text.count)
        inserter.insert(replayIndex == 0 ? text : " " + text)
        hud.showError("⏪ Диктовка \(replayIndex + 1) из \(entries.count)", autoHide: 1.3)
        replayIndex += 1
    }

    /// Правый ⇧ (≥0.2 с): прочитать вслух выделенный текст; повторное нажатие — стоп.
    /// Выделение забираем через Cmd+C с сохранением и возвратом буфера обмена.
    private func speakSelection() {
        guard !recordingNow else { return }
        if speaker.isSpeaking {
            speaker.stop()
            hud.showError("🔇 Остановил чтение", autoHide: 1.0)
            return
        }
        grabSelectedText { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.hud.showError("Сначала выдели текст, потом правый ⇧", autoHide: 1.8)
                return
            }
            AppLog.log("озвучка: читаю \(text.count) символов")
            self.speaker.speak(text)
            self.hud.showError("🔊 Читаю… (правый ⇧ — стоп)", autoHide: 2.0)
        }
    }

    /// Правые ⌥+⇧ вместе: выделенный текст → правка грамматики (сохраняя слова
    /// и смысл). Основной путь — корректор AICleaner (настройка в ai.json), запасной —
    /// локальный TextCleaner. Оригинал уходит в историю диктовок (предохранитель).
    private func cleanSelection() {
        guard !recordingNow else { return }
        grabSelectedText { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.hud.showError("Сначала выдели текст, потом правые ⌥+⇧", autoHide: 2.0)
                return
            }
            if let cfg = AICleaner.loadConfig(), text.count <= 12000 {
                self.hud.showError("✨ Правлю грамматику…", autoHide: 25)
                AICleaner.fix(text, config: cfg) { [weak self] fixed in
                    guard let self else { return }
                    if let fixed {
                        self.applyCleaned(original: text, cleaned: fixed, label: "✨ Поправил (ИИ)")
                    } else {
                        self.applyCleaned(original: text, cleaned: TextCleaner.clean(text),
                                          label: "🧹 ИИ недоступен — почистил правилами")
                    }
                }
            } else {
                self.applyCleaned(original: text, cleaned: TextCleaner.clean(text), label: "🧹 Почистил")
            }
        }
    }

    private func applyCleaned(original: String, cleaned: String, label: String) {
        guard cleaned != original.trimmingCharacters(in: .whitespacesAndNewlines) else {
            hud.showError("Чистить нечего — текст и так аккуратный ✨", autoHide: 1.6)
            return
        }
        DictationHistory.append(original)
        AppLog.log("чистка ⇧: \(original.count) → \(cleaned.count) симв. [\(label)]")
        inserter.insert(cleaned)
        hud.showError("\(label): \(original.count) → \(cleaned.count) симв. (оригинал в истории)", autoHide: 2.2)
    }

    /// Кнопка Ю (заказ автора 01.08.2026): выделенный текст → ИИ вытаскивает термины
    /// (названия, имена, жаргон) → копилка terms.txt. С этого момента ИИ-корректор
    /// знает канонные написания и чинит кривоту распознавания сам.
    private func rememberTermsFromSelection() {
        guard !recordingNow else { return }
        grabSelectedText { [weak self] text in
            guard let self else { return }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.hud.showError("Сначала выдели текст с терминами, потом Ю", autoHide: 2.0)
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // короткое выделение (1–3 слова) = автор явно показал термин:
            // берём КАК ЕСТЬ, без ИИ («зарелизился» модель считала не-термином)
            if trimmed.count <= 60, trimmed.split(separator: " ").count <= 3,
               !trimmed.contains("\n") {
                self.finishRememberTerms([trimmed])
                return
            }
            guard let cfg = AICleaner.loadConfig() else {
                self.hud.showError("ИИ не настроен — выдели сам термин (1–3 слова)", autoHide: 2.5)
                return
            }
            self.hud.showError("📚 Разбираю термины…", autoHide: 15)
            AICleaner.extractTerms(String(text.prefix(4000)), config: cfg) { [weak self] terms in
                guard let self else { return }
                guard let terms else {
                    self.hud.showError("ИИ недоступен — термины не запомнил", autoHide: 2.0)
                    return
                }
                guard !terms.isEmpty else {
                    self.hud.showError("Терминов в выделенном не нашлось 🤷 Выдели само слово", autoHide: 2.5)
                    return
                }
                self.finishRememberTerms(terms)
            }
        }
    }

    private func finishRememberTerms(_ terms: [String]) {
        let added = WordFixes.rememberTerms(terms)
        if added.isEmpty {
            hud.showError("Всё уже в словаре ✔️", autoHide: 2.0)
        } else {
            AppLog.log("термины Ю: +\(added.joined(separator: ", "))")
            hud.showError("📚 Запомнил: \(added.joined(separator: ", "))", autoHide: 3.5)
        }
    }

    /// Кнопка Б: тумблер Bluetooth. Сценарий автора 04.08: слушает в AirPods с
    /// телефона → жмёт Б (Bluetooth выключен, наушники отвалились) → диктует во
    /// встроенный микрофон → жмёт Б (Bluetooth включён, AirPods подключаются к
    /// маку сами) → слушает результат. Подключение блокирует — уводим в фон.
    private func toggleBluetooth() {
        if DiktovkaBTPowerOn() {
            DiktovkaBTSetPower(false)
            AppLog.log("Б: Bluetooth выключен")
            hud.showError("📴 Bluetooth выключен — диктуй", autoHide: 2.0)
            return
        }
        DiktovkaBTSetPower(true)
        AppLog.log("Б: Bluetooth включаю, зову наушники")
        hud.showError("📶 Bluetooth включён, зову наушники…", autoHide: 8.0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let deadline = Date().addingTimeInterval(5)   // питание поднимается не мгновенно
            while !DiktovkaBTPowerOn() && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.3)
            }
            var name: String?
            for attempt in 0..<3 {   // наушникам нужно пару секунд, чтобы проснуться
                if let n = DiktovkaBTConnectHeadphones() { name = n; break }
                if attempt < 2 { Thread.sleep(forTimeInterval: 1.2) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let name {
                    AppLog.log("Б: подключил «\(name)»")
                    self.hud.showError("🎧 \(name) — подключены", autoHide: 2.2)
                } else {
                    AppLog.log("Б: Bluetooth включён, наушники не ответили")
                    self.hud.showError("Bluetooth включён, но наушники не ответили (они рядом/в ушах?)", autoHide: 3.0)
                }
            }
        }
    }

    /// Копия выделенного текста активного окна: буфер сохраняем и возвращаем
    private func grabSelectedText(completion: @escaping (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for t in item.types {
                if let d = item.data(forType: t) { copy.setData(d, forType: t) }
            }
            return copy
        }
        pb.clearContents()
        TextInserter.pressKey(8, flags: .maskCommand) // kVK_ANSI_C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let text = pb.string(forType: .string)
            pb.clearContents()
            if let saved, !saved.isEmpty { pb.writeObjects(saved) }
            completion(text)
        }
    }

    /// Кнопка «закрыть лишнее» (просьба автора 16.10.2026) — логика в CloseOthers.swift
    @objc private func closeOthers() {
        let closed = CloseOthers.run()
        hud.showNote(closed.isEmpty ? "Лишнего нет — всё уже закрыто"
                                    : "🧹 Закрываю: \(closed.joined(separator: ", "))",
                     autoHide: 2.5)
    }

    @objc private func copyLastDictation() {
        guard let text = lastDictation ?? DictationHistory.lastEntry() else {
            hud.showError("История пуста — ещё ничего не надиктовано", autoHide: 1.8)
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        hud.showError("Скопировал последнюю диктовку ✔️ Жми ⌘V где нужно", autoHide: 1.8)
    }

    @objc private func openHistory() {
        if !FileManager.default.fileExists(atPath: DictationHistory.url.path) {
            hud.showError("История пуста — ещё ничего не надиктовано", autoHide: 1.8)
            return
        }
        NSWorkspace.shared.open(DictationHistory.url)
    }

    @objc private func openArchive() {
        try? FileManager.default.createDirectory(at: AudioArchive.dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(AudioArchive.dir)
    }

    /// Сводка журнала вставок: сколько дошло, сколько не дошло, где чинил руками.
    /// Кнопка «Открыть журнал» — сырые строки, если захочется копать самому.
    @objc private func openAudit() {
        let a = NSAlert()
        a.messageText = "Что впечаталось в окно"
        a.informativeText = InsertAudit.svodka(dney: 7)
        a.addButton(withTitle: "Понятно")
        a.addButton(withTitle: "Открыть журнал")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn {
            if FileManager.default.fileExists(atPath: InsertAudit.url.path) {
                NSWorkspace.shared.open(InsertAudit.url)
            } else {
                hud.showNote("Журнал пуст — заполнится с первой диктовки", autoHide: 2.0)
            }
        }
    }

    @objc private func openRawLog() {
        if !FileManager.default.fileExists(atPath: DictationHistory.rawURL.path) {
            hud.showError("Чёрный ящик пуст — ещё ничего не распознано", autoHide: 1.8)
            return
        }
        NSWorkspace.shared.open(DictationHistory.rawURL)
    }
}
