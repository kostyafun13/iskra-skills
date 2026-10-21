import Foundation

/// Автоперезапуск после падения (13.09.2026, 09:22: SIGSEGV в AppKit при открытии меню —
/// приложение исчезло, а launchd его не поднял: экземпляр запущен через open, не как job).
/// Обработчик сигнала только порождает `sh -c "sleep 1; open <бандл>"` и отдаёт сигнал
/// дальше — крэш-репорт пишется как обычно. Страховка от петли: каждое падение — байт в
/// crashes.txt; три падения за десять минут → обработчик не ставим, ждём ручного запуска.
// глобальные, а не static: C-обработчик сигнала не может захватывать контекст типа
private var crashArgv: [UnsafeMutablePointer<CChar>?] = []
private var crashMarksPath: [CChar] = []

enum CrashRelaunch {
    static let marksURL = Transcriber.appSupportDir.appendingPathComponent("crashes.txt")

    /// Ставить ли обработчик: считаем падения за последние 10 минут
    static func install() {
        let fm = FileManager.default
        var recent = 0
        if let attrs = try? fm.attributesOfItem(atPath: marksURL.path),
           let mtime = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(mtime) < 600,
           let size = attrs[.size] as? Int {
            recent = size
        } else {
            try? fm.removeItem(at: marksURL)   // старые метки не считаем
        }
        if recent >= 3 {
            AppLog.log("автоперезапуск: \(recent) падения за 10 минут — выключен до ручного запуска")
            return
        }
        let cmd = "sleep 1; /usr/bin/open \"\(Bundle.main.bundlePath)\""
        crashArgv = [strdup("/bin/sh"), strdup("-c"), strdup(cmd), nil]
        crashMarksPath = Array(marksURL.path.utf8CString)
        for sig in [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig) { s in
                // только системные вызовы: open/write/posix_spawn — безопасны в обработчике
                let fd = open(crashMarksPath, O_WRONLY | O_APPEND | O_CREAT, 0o644)
                if fd >= 0 { var b: UInt8 = 0x78; write(fd, &b, 1); close(fd) }
                var pid: pid_t = 0
                crashArgv.withUnsafeBufferPointer { buf in
                    _ = posix_spawn(&pid, buf[0], nil, nil, buf.baseAddress, environ)
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        AppLog.log("автоперезапуск после падения: включён")
    }
}
