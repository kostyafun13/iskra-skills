import Foundation

/// Самопроверка без UI и разрешений: прогоняет wav через движок и печатает текст.
/// Запуск: Diktovka --transcribe file.wav
enum SelfTest {
    static func run(wavPath: String) -> Never {
        let t = Transcriber()
        var done = false
        var exitCode: Int32 = 1

        t.onStateChange = { state in
            switch state {
            case .ready:
                FileHandle.standardError.write("модель готова, распознаю…\n".data(using: .utf8)!)
                _ = t.transcribe(fileURL: URL(fileURLWithPath: wavPath), deleteAfter: false)
            case .failed(let m):
                FileHandle.standardError.write("ошибка: \(m)\n".data(using: .utf8)!)
                done = true
            case .loadingModel:
                FileHandle.standardError.write("модель загружается…\n".data(using: .utf8)!)
            default:
                break
            }
        }
        t.onResult = { _, text, error in
            if let error { FileHandle.standardError.write("ошибка куска: \(error)\n".data(using: .utf8)!) }
            print(text)
            exitCode = 0
            done = true
        }
        t.start()

        let deadline = Date().addingTimeInterval(600)
        while !done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if !done { FileHandle.standardError.write("таймаут\n".data(using: .utf8)!) }
        t.stop()
        exit(exitCode)
    }
}
