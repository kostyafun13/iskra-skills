import AppKit

/// Сторож главного потока (инцидент 13.09.2026): главный поток встал, активный CGEventTap
/// перестал отвечать — система на каждую клавишу ждала таймаут, буквы доходили по одной,
/// меню не открывалось, помог только kill. Сторож живёт в СВОЁМ потоке: раз в секунду ждёт
/// отклика главного; тишина дольше `releaseAfter` — отпускаем клавиатуру (выключаем тап)
/// и снимаем сэмпл процесса в App Support/hang_<время>.txt (в следующий раз будет видно,
/// ГДЕ стоял поток); дольше `restartAfter` — перезапускаемся сами: зависшее приложение
/// всё равно мертво, а клавиатура и диктовка нужны.
final class Watchdog {
    var onRelease: (() -> Void)?   // НЕ на главном потоке: выключить тап
    var onRecover: (() -> Void)?   // на главном: тап можно включать обратно
    private let releaseAfter: TimeInterval = 8
    private let restartAfter: TimeInterval = 60
    private var lastCheck = ProcessInfo.processInfo.systemUptime
    private var activity: NSObjectProtocol?
    private let lock = NSLock()
    // systemUptime — монотонные часы БЕЗ времени сна: Date() после двухчасового сна мака
    // показывал «главный поток молчит 2 часа» (13.09 10:54→13:04) — с Date() гонка на пробуждении
    // могла перезапустить приложение ни за что
    private var lastPong = ProcessInfo.processInfo.systemUptime
    private var released = false
    private var sampled = false

    func start() {
        // Без App Nap: система «усыпляет» фоновое меню-бар приложение и задерживает таймеры
        // на секунды — 13.09 10:54 сторож поймал «зависание» при свободном главном потоке
        // (сэмпл hang_2026-09-13_10-54-06.txt: main в mach_msg, ждёт событий)
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Диктовка держит перехват клавиш и сторож")
        // таймер в .common: тикает и при открытом меню (eventTracking), и в модалках —
        // иначе открытое на полминуты меню выглядело бы как зависание
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.pong() }
        RunLoop.main.add(t, forMode: .common)
        let th = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                guard let self else { return }
                self.check()
            }
        }
        th.name = "diktovka.watchdog"
        th.qualityOfService = .userInteractive
        th.start()
    }

    private func pong() {
        lock.lock()
        lastPong = ProcessInfo.processInfo.systemUptime
        let wasReleased = released
        released = false
        sampled = false
        lock.unlock()
        if wasReleased {
            AppLog.log("сторож: главный поток ожил — возвращаю клавиатуру")
            onRecover?()
        }
    }

    private func check() {
        // сам сторож проспал (сон мака, App Nap, приостановка процесса) — это не зависание
        // главного потока: сбрасываем отсчёт и не трогаем клавиатуру
        let now = ProcessInfo.processInfo.systemUptime
        let gap = now - lastCheck
        lastCheck = now
        if gap > 3 {
            lock.lock(); lastPong = now; lock.unlock()
            return
        }
        lock.lock()
        let silent = now - lastPong
        let rel = released
        let smp = sampled
        lock.unlock()
        guard silent > releaseAfter else { return }
        if !rel {
            lock.lock(); released = true; lock.unlock()
            AppLog.log(String(format: "сторож: главный поток молчит %.0f с — отпускаю клавиатуру", silent))
            onRelease?()
        }
        if !smp {
            lock.lock(); sampled = true; lock.unlock()
            sample()
        }
        if silent > restartAfter {
            AppLog.log(String(format: "сторож: главный поток молчит %.0f с — перезапускаюсь", silent))
            Relaunch.now(exitCode: 3)
        }
    }

    /// /usr/bin/sample своего процесса — три секунды стека всех потоков в файл
    private func sample() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let out = Transcriber.appSupportDir.appendingPathComponent("hang_\(f.string(from: Date())).txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(ProcessInfo.processInfo.processIdentifier)", "3", "-mayDie", "-file", out.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            AppLog.log("сторож: сэмпл процесса → \(out.lastPathComponent)")
        } catch {
            AppLog.log("сторож: sample не запустился: \(error.localizedDescription)")
        }
    }
}

/// Перезапуск через open, а не launchctl kickstart (13.09.2026: kickstart -k не убил
/// экземпляр, запущенный через open, а поднял ВТОРОЙ). Ждём, пока текущий процесс уйдёт,
/// и открываем бандл заново; если рядом лежит Diktovka.new.app — сначала подменяем сборку.
enum Relaunch {
    static func now(exitCode: Int32) {
        let bundle = URL(fileURLWithPath: Bundle.main.bundlePath)
        swapStagedBuild(bundle)
        let pid = ProcessInfo.processInfo.processIdentifier
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c",
            "for i in $(seq 1 80); do kill -0 \(pid) 2>/dev/null || break; sleep 0.25; done; " +
            "/usr/bin/open \"\(bundle.path)\""]
        try? sh.run()
        Thread.sleep(forTimeInterval: 0.3)   // дать логгеру дописать строки
        _exit(exitCode)                      // без atexit: главный поток мог зависнуть
    }

    /// Есть ли рядом сборка, ждущая подмены
    static var hasStagedBuild: Bool {
        let dir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("Diktovka.new.app").path)
    }

    /// build_app.sh кладёт свежую сборку в Diktovka.new.app, пока приложение запущено:
    /// менять бандл под живым процессом нельзя (13.09.2026 — процесс потерял доверие TCC,
    /// перестали доходить и напечатанный текст, и ⌘C озвучки). Подмена — в момент перезапуска.
    static func swapStagedBuild(_ bundle: URL) {
        let fm = FileManager.default
        let dir = bundle.deletingLastPathComponent()
        let staged = dir.appendingPathComponent("Diktovka.new.app")
        guard fm.fileExists(atPath: staged.path) else { return }
        let old = dir.appendingPathComponent("Diktovka.old.app")
        try? fm.removeItem(at: old)
        do {
            try fm.moveItem(at: bundle, to: old)
            try fm.moveItem(at: staged, to: bundle)
            // прежний бандл не храним: он всплывал в списке Универсального доступа как
            // «Diktovka old» и путал (вопрос автора 13.09); откат — из git
            try? fm.removeItem(at: old)
            AppLog.log("перезапуск: подменил сборку из Diktovka.new.app, прежнюю удалил")
        } catch {
            AppLog.log("перезапуск: не смог подменить сборку: \(error.localizedDescription)")
        }
    }
}
