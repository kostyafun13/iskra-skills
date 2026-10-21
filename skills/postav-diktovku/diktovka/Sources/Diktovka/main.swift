import AppKit

// движок общается через пайпы — закрытый пайп не должен ронять приложение
signal(SIGPIPE, SIG_IGN)

// Режим самопроверки без UI и разрешений: Diktovka --transcribe file.wav
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--transcribe" {
    SelfTest.run(wavPath: CommandLine.arguments[2])
}

// Диагностика микрофонов без UI: Diktovka --mics — что видит CoreAudio и что возьмёт рекордер
if CommandLine.arguments.contains("--mics") {
    for d in AudioRecorder.inputDevices() {
        print("\(d.name) · \(d.transportLabel) · uid=\(d.uid)\(d.isVirtual ? " (виртуальный, в меню не показываем)" : "")")
    }
    let c = AudioRecorder.chooseDevice()
    print("выбор: \(c.device?.name ?? "—") — \(c.why)")
    exit(0)
}

// Диагностика иконок: Diktovka --icon-png <папка> — набор иконок бара крупно, посмотреть бейдж глазами
if let i = CommandLine.arguments.firstIndex(of: "--icon-png"), i + 1 < CommandLine.arguments.count {
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let set: [(String, NSImage?)] = [
        ("1_mic",            StatusIcon.make(symbol: "mic")),
        ("2_mic_B",          StatusIcon.make(symbol: "mic", badge: "Б")),
        ("3_mic_B_topright", StatusIcon.make(symbol: "mic", badge: "Б", badgeCorner: .topRight)),
        ("4_micfill_check",  StatusIcon.make(symbol: "mic.fill", checkmark: true)),
        ("5_micfill_check_B", StatusIcon.make(symbol: "mic.fill", checkmark: true, badge: "Б")),
        ("6_rec_B",          StatusIcon.make(symbol: "mic.fill", badge: "Б", template: false)),
        ("7_lock_B",         StatusIcon.make(symbol: "lock.fill", badge: "Б", template: false)),
        ("8_hourglass_B",    StatusIcon.make(symbol: "hourglass", badge: "Б")),
    ]
    for (name, img) in set {
        guard let img else { print("\(name): символ не найден"); continue }
        let ok = StatusIcon.writePNG(img, to: dir.appendingPathComponent(name + ".png"))
        print("\(name): \(ok ? "ok" : "НЕ записался")")
    }
    exit(0)
}

// Приёмка журнала: Diktovka --test-zhurnal — пишет тестовую строку и проверяет, что она легла
if CommandLine.arguments.contains("--test-zhurnal") {
    print(InsertAudit.testZapis())
    exit(0)
}

// Диагностика поля: Diktovka --pole — что видно в активном окне (проверяется ли приём текста)
if CommandLine.arguments.contains("--pole") {
    print(InsertAudit.diagnostikaPolya())
    exit(0)
}

// Самопроверка установки без UI: Diktovka --proverka — что настроено, ключ не печатается.
// Разрешения macOS отсюда не видны (из терминала они чужие) — их подтверждает app.log
// строкой «клавиши: CGEventTap установлен» после запуска приложения.
if CommandLine.arguments.contains("--proverka") {
    let fm = FileManager.default
    func est(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
    let dir = Transcriber.appSupportDir
    print("Папка данных: \(dir.path)")
    let tts = YandexTTS.config()
    print(tts != nil ? "✓ Ключ Яндекса найден (env_file из tts.json)"
                     : "✗ Ключа Яндекса нет — облачные распознавание и голос выключены (tts.json → env_file)")
    print(Transcriber.localInstalled ? "✓ Локальный движок установлен" : "· Локальный движок не установлен (по желанию — install_engine.sh)")
    if Transcriber.cloudOnly {
        print("✓ Распознавание: только облако Яндекса")
    } else if Transcriber.localInstalled {
        print("✓ Распознавание: режим «\(Transcriber.route.rawValue)», локальный движок\(YandexSTT.isAvailable ? " + облако" : "")")
    } else {
        print("✗ Распознавать нечем: нет ни ключа, ни локального движка")
    }
    let voice = Speaker.preferredRuVoiceId ?? "системный голос macOS"
    print("✓ Озвучка (правый ⇧): \(voice.hasPrefix("yandex:") ? YandexTTS.displayName(String(voice.dropFirst(7))) : voice)")
    print(AICleaner.loadConfig() != nil ? "✓ ИИ-правка: включена на своём ключе (ai.json)" : "· ИИ-правка: выключена (нет ai.json)")
    print("· Словарик: \(est(WordFixes.fileURL) ? "есть" : "создастся при первом запуске") — \(WordFixes.fileURL.path)")
    let lishnee = CloseOthers.dryRun()
    print("· «Закрыть лишнее» сейчас закрыло бы: \(lishnee.isEmpty ? "ничего" : lishnee.joined(separator: ", "))")
    print("· Не давать уснуть: \(UserDefaults.standard.bool(forKey: "keepAwakeEnabled") ? "включено" : "выключено") (меню значка)")
    print("· История диктовок: \(est(DictationHistory.url) ? DictationHistory.url.path : "пока пусто")")
    exit(tts != nil || Transcriber.localInstalled ? 0 : 1)
}

// Аналитика вставок без UI: Diktovka --analitika [дней] — что впечаталось и что не доехало
if let i = CommandLine.arguments.firstIndex(of: "--analitika") {
    let dney = (i + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[i + 1]) : nil) ?? 7
    print(InsertAudit.svodka(dney: dney))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
