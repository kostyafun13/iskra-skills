import AVFoundation

/// Проигрыватель WAV с НАДЁЖНОЙ сменой скорости на лету (правка автора 10.08.2026:
/// AVAudioPlayer.rate на vosk-WAV просто игнорировался — играл на 1.0). Здесь
/// AVAudioEngine → AVAudioPlayerNode → AVAudioUnitTimePitch → mixer: timePitch.rate
/// меняет ТЕМП без искажения тембра и подхватывается мгновенно, даже во время игры.
final class RatePlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var currentFormat: AVAudioFormat?
    private var gen = 0   // отсекает колбэки устаревших кусков после stop()/recover
    private var inFlight: (url: URL, completion: () -> Void)?
    private var paused = false   // пауза ради диктовки: кусок стоит на месте, очередь живёт

    init() {
        engine.attach(node)
        engine.attach(timePitch)
        // Смена аудио-выхода (подключились/отпали наушники) молча останавливает
        // движок — без восстановления чтение обрывалось насовсем (инцидент 12.08).
        // queue: nil + прыжок на main (фикс 24.09): с queue: .main очередь движка ждала
        // главный поток, а главный — её (зависание при диктовке поверх озвучки)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.recoverAfterConfigChange() }
        }
    }

    /// Темп 0.5–2.5× (timePitch.rate поддерживает 1/32…32), тембр сохраняется
    var rate: Float {
        get { timePitch.rate }
        set { timePitch.rate = max(0.5, min(2.5, newValue)) }
    }

    /// «Кусок в полёте», НЕ node.isPlaying: узел после конца файла остаётся
    /// «играющим» (тишину), из-за чего очередь кусков глохла после первого
    /// (инцидент 12.08: «сдохло через пять слов», part1+ копились в tmp)
    var isPlaying: Bool { inFlight != nil }

    /// Проиграть один файл; completion — на main, когда звук РЕАЛЬНО доиграл
    /// (.dataPlayedBack; старый колбэк «данные скормлены» стрелял раньше конца).
    /// Переподключаем граф под формат файла (vosk и piper дают разные форматы).
    func play(url: URL, rate: Float, completion: @escaping () -> Void) {
        gen += 1
        let g = gen
        guard let file = try? AVAudioFile(forReading: url) else {
            DispatchQueue.main.async(execute: completion); return
        }
        inFlight = (url, completion)
        let fmt = file.processingFormat
        if currentFormat == nil || currentFormat! != fmt {
            if engine.isRunning { engine.stop() }
            engine.disconnectNodeOutput(node)
            engine.disconnectNodeOutput(timePitch)
            // ВСЯ цепочка одним форматом голоса; mixer сам сконвертит в аппаратный
            // выход (иначе timePitch(fmt)→mixer(hardware) = -10868 FormatNotSupported)
            engine.connect(node, to: timePitch, format: fmt)
            engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
            currentFormat = fmt
        }
        timePitch.rate = max(0.5, min(2.5, rate))
        do {
            if !engine.isRunning { engine.prepare(); try engine.start() }
        } catch {
            AppLog.log("RatePlayer: движок не стартовал: \(error.localizedDescription)")
            currentFormat = nil   // сбросить, чтобы следующий раз переподключить заново
            inFlight = nil
            DispatchQueue.main.async(execute: completion); return
        }
        node.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.gen == g, self.inFlight != nil else { return }
                self.inFlight = nil
                completion()
            }
        }
        if paused {
            AppLog.log("RatePlayer: кусок запланирован, стоим на паузе")
        } else {
            node.play()
        }
    }

    /// Пауза/продолжение (просьба автора 13.09.2026): звук замирает на месте, а не
    /// сбрасывается; после диктовки читаем ровно оттуда, где остановились
    var isPaused: Bool { paused }

    func pause() {
        guard !paused else { return }
        paused = true
        if inFlight != nil { node.pause() }
    }

    func resume() {
        guard paused else { return }
        paused = false
        if inFlight != nil { node.play() }
    }

    /// Наушники подключились/отвалились: система остановила движок. Пересобираем
    /// граф под новый выход и переигрываем текущий кусок с начала — чтение живёт.
    private func recoverAfterConfigChange() {
        currentFormat = nil
        guard let job = inFlight else { engine.stop(); return }
        AppLog.log("RatePlayer: сменился аудио-выход — переигрываю кусок")
        inFlight = nil
        node.stop()
        engine.stop()
        play(url: job.url, rate: timePitch.rate, completion: job.completion)
    }

    func stop() {
        gen += 1
        inFlight = nil
        paused = false
        node.stop()
        engine.stop()
        currentFormat = nil
    }
}
