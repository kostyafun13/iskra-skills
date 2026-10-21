import AVFoundation
import AppKit

/// Озвучка: штатные голоса macOS (AVSpeech) + локальные нейро-голоса Piper
/// (venv/bin/piper + модели в piper-voices/, ставятся install_voices.sh).
/// Всё локально; piper на M1 синтезирует абзац за ~1–2 с — короткая вспышка CPU.
/// Русский голос выбирается в меню («Голос озвучки»); латиница читается
/// английским системным голосом автоматически.
final class Speaker: NSObject {
    private let synth = AVSpeechSynthesizer()
    private var piperProc: Process?
    private let ratePlayer = RatePlayer()   // WAV-плеер с надёжной сменой темпа
    private var piperBusy = false
    private var piperGen = 0   // отмена устаревшего синтеза после stop()
    // облачная озвучка: куски синтезируются подряд в фоне, играются по очереди —
    // первый кусок звучит, пока следующий ещё едет по сети
    private var yaGen = 0
    private var yaQueue: [URL] = []
    private var yaPlaying = false
    private var yaDone = true
    private var yaBusy = false
    private var yaTail: String?   // хвост, который облако не дожевало — дочитываем локально
    private static let voiceKey = "speakVoiceId"
    private static let rateKey = "speakRate"

    var isSpeaking: Bool { synth.isSpeaking || piperBusy || yaBusy || ratePlayer.isPlaying }

    /// Скорость чтения (стрелки ←/→ во время чтения, правка автора 05.08):
    /// сохраняется и применяется к текущему куску на лету
    static var readRate: Float {
        get {
            let r = UserDefaults.standard.float(forKey: rateKey)
            return r == 0 ? 1.0 : min(2.5, max(0.75, r))
        }
        set { UserDefaults.standard.set(min(2.5, max(0.75, newValue)), forKey: rateKey) }
    }

    private var currentReadText: String?

    /// Озвучка на паузе ради диктовки (просьба автора 13.09.2026): «поймать её на паузу,
    /// ответить по ней, отпустил клавишу — читает дальше без перезапуска»
    private(set) var isPaused = false

    /// true = было что ставить на паузу
    func pause() -> Bool {
        guard isSpeaking, !isPaused else { return false }
        isPaused = true
        ratePlayer.pause()
        if synth.isSpeaking && !synth.isPaused { _ = synth.pauseSpeaking(at: .word) }
        return true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        ratePlayer.resume()
        if synth.isPaused { _ = synth.continueSpeaking() }
        playNextVoskIfIdle(gen: piperGen)   // пока стояли, конвейер мог наполнить очередь
    }

    /// Шаг 0.25×; возвращает новую скорость для плашки. НЕ перебиваем текущее чтение
    /// (перечитывание с начала раздражало и застревало — жалоба автора 10.08): скорость
    /// применяется к плееру на лету, а выбор нейро(1×)/запасной(ускоренный) — при
    /// СТАРТЕ следующего чтения по readRate. Нейро при ускорении не «бурундучит»,
    /// т.к. в vosk-путь заходим только при readRate ≤ 1.
    func bumpRate(_ delta: Int) -> Float {
        let r = min(2.5, max(0.75, Self.readRate + Float(delta) * 0.25))
        Self.readRate = r
        ratePlayer.rate = r
        return r
    }

    /// Стрелки ↑/↓: перемотка ±15 с. С поштучным конвейером vosk «вперёд» =
    /// перепрыгнуть текущий кусок в следующий; «назад» в пределах куска не делаем
    func seek(_ seconds: Double) {
        guard seconds > 0 else { return }   // назад по конвейеру некуда (куски удалены)
        ratePlayer.stop()
        playNextVoskIfIdle(gen: piperGen)
    }

    static var preferredRuVoiceId: String? {
        // ничего не выбрано, а ключ Яндекса есть — читаем облачным голосом из tts.json
        get { UserDefaults.standard.string(forKey: voiceKey) ?? YandexTTS.config().map { "yandex:" + $0.voice } }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: voiceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: voiceKey)
            }
        }
    }

    // MARK: - Реестр голосов

    static let piperDir = Transcriber.appSupportDir.appendingPathComponent("piper-voices")
    static var piperBin: URL { Transcriber.appSupportDir.appendingPathComponent("venv/bin/piper") }

    // Новый нейро-голос vosk-tts (выбор автора 04.08 — спикер №2 из мульти-модели);
    // синтез — helper/tts_synth.py венвом Диктовки, модель в ~/.cache/vosk/
    static var ttsVenvPython: URL { Transcriber.appSupportDir.appendingPathComponent("venv/bin/python3") }
    static let voskModelName = "vosk-model-tts-ru-0.9-multi"
    static var voskModelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/vosk/\(voskModelName)")
    }
    static func ttsHelperScript() -> URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let u = res.appendingPathComponent("helper/tts_synth.py")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static func voskVoiceIds() -> [String] {
        guard FileManager.default.fileExists(atPath: ttsVenvPython.path),
              FileManager.default.fileExists(atPath: voskModelDir.path),
              ttsHelperScript() != nil else { return [] }
        return ["vosk:2"]
    }
    static func displayName(forVoskId id: String) -> String {
        "Голос №\(id.dropFirst("vosk:".count)) — нейро (новый)"
    }

    /// id вида "piper:ru_RU-irina-medium" — по факту наличия модели на диске
    static func piperVoiceIds() -> [String] {
        guard FileManager.default.fileExists(atPath: piperBin.path) else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: piperDir.path)) ?? []
        return files.filter { $0.hasSuffix(".onnx") }
            .map { "piper:" + String($0.dropLast(5)) }
            .sorted()
    }

    static func displayName(forPiperId id: String) -> String {
        let base = id.replacingOccurrences(of: "piper:", with: "")
        let names = ["irina": "Ирина", "denis": "Денис", "dmitri": "Дмитрий", "ruslan": "Руслан"]
        for (k, v) in names where base.contains(k) { return "\(v) — нейро" }
        return base + " — нейро"
    }

    /// Установленные системные русские голоса (скачанные в Настройках появляются сами)
    static func russianVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ru-RU" }
            .sorted { ($0.name, $0.quality.rawValue) < ($1.name, $1.quality.rawValue) }
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .enhanced: return " (расширенный)"
        case .premium: return " (премиум)"
        default: return ""
        }
    }

    // MARK: - Чтение

    func speak(_ text: String) {
        stop()
        // числа → слова ДО чистки: sanitize вырезает «₽» и «%» как «не буквы», а Vosk и Piper
        // читают «50» как «пять ноль» (заказ автора 18.09.2026)
        let spoken = NumberSpeech.normalize(text)
        // чистим маркдаун/символьный мусор: голос спотыкался о «заборы» и глох
        let clean = Self.sanitize(spoken)
        guard !clean.isEmpty else { return }

        let letters = clean.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let cyrillic = letters.filter { (0x400...0x4FF).contains(Int($0.value)) }.count
        let isRussian = letters.isEmpty || cyrillic * 2 >= letters.count

        currentReadText = clean
        // ТОЛЬКО КРАСИВЫЙ ГОЛОС (правило автора 13.09.2026: «мне нужен только красивый голос
        // для озвучивания текста, я могу слушать только его»). Правило 10.08 «нейро только
        // на 1×, ускорение → запасной» отменено: сохранённая скорость 1,25× молча уводила
        // на запасной голос при прогретой модели — это и были «танцы с бубнами» и K.
        // Темп на любой скорости даёт timePitch без смены тембра; успевает ли синтез —
        // видно в логе («vosk-tts: синтез … RTF»).
        // облако — первым: автор выбрал его именно потому, что локальные звучат криво
        if isRussian, let pref = Self.preferredRuVoiceId, pref.hasPrefix("yandex:") {
            speakYandex(clean, voice: String(pref.dropFirst("yandex:".count)))
            return
        }
        if isRussian, let pref = Self.preferredRuVoiceId, pref.hasPrefix("vosk:"),
           let speakerId = Int(pref.dropFirst("vosk:".count)),
           Self.ttsHelperScript() != nil,
           FileManager.default.fileExists(atPath: Self.ttsVenvPython.path) {
            speakVosk(clean, speakerId: speakerId)
            return
        }
        if isRussian, let pref = Self.preferredRuVoiceId, pref.hasPrefix("piper:") {
            let model = Self.piperDir.appendingPathComponent(String(pref.dropFirst("piper:".count)) + ".onnx")
            if FileManager.default.fileExists(atPath: model.path),
               FileManager.default.fileExists(atPath: Self.piperBin.path) {
                synthAndPlay(clean, label: "piper") { p, wav in
                    p.executableURL = Self.piperBin
                    p.arguments = ["-m", model.path, "-f", wav.path]
                }
                return
            }
        }
        // штатный путь — кусками по предложениям (один гигантский utterance глохнет)
        for chunk in Self.chunks(from: clean) {
            let u = AVSpeechUtterance(string: chunk)
            u.voice = isRussian ? Self.systemRuVoice() : AVSpeechSynthesisVoice(language: "en-US")
            u.rate = Self.systemUtteranceRate()   // системный голос тоже слушает скорость
            synth.speak(u)
        }
    }

    func stop() {
        piperGen += 1
        yaGen += 1
        yaBusy = false
        yaPlaying = false
        yaDone = true
        yaTail = nil
        for url in yaQueue { try? FileManager.default.removeItem(at: url) }
        yaQueue.removeAll()
        isPaused = false
        stopWarmupTicker()
        voskCancelCurrentJob()
        piperProc?.terminate()
        piperProc = nil
        piperBusy = false
        for url in voskPartQueue { try? FileManager.default.removeItem(at: url) }
        voskPartQueue.removeAll()
        voskStreamDone = true
        ratePlayer.stop()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }

    /// Сказать серверу «брось недожёванное задание» (инцидент 13.08: без отмены
    /// повторные нажатия копили очередь синтеза на минуты — «нажимаю, а она не
    /// воспроизводится»). Сервер слушает stdin отдельным потоком и бросает
    /// текущий синтез на границе куска; строка-отмена сама по себе — no-op.
    private func voskCancelCurrentJob() {
        guard voskWarm, voskProc?.isRunning == true, let inH = voskIn else { return }
        let err = DiktovkaTryBlock {
            inH.write(Data("{\"cancel\":true}\n".utf8))
        }
        if err != nil { AppLog.log("vosk-tts: отмена не дошла (пайп закрыт?)") }
    }

    // MARK: - Внутренности

    /// Скорость для системного голоса (AVSpeechSynthesizer): дефолт × readRate,
    /// в допустимых пределах. Меняется для НОВЫХ фраз (на лету synth не умеет).
    private static func systemUtteranceRate() -> Float {
        let r = AVSpeechUtteranceDefaultSpeechRate * readRate
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, r))
    }

    private static func systemRuVoice() -> AVSpeechSynthesisVoice? {
        if let id = preferredRuVoiceId, !id.hasPrefix("piper:"),
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        return AVSpeechSynthesisVoice(language: "ru-RU")
    }

    // MARK: - Резидентный vosk-tts (голос №2)

    var onNotice: ((String) -> Void)?   // плашки наружу (hud живёт в AppDelegate)

    private var voskProc: Process?
    private var voskIn: FileHandle?
    private var voskOut: FileHandle?
    private var voskReady = false        // менять только под voskLock
    private var voskBuf = Data()
    private let voskQueue = DispatchQueue(label: "diktovka.tts")
    private let voskLock = NSLock()

    /// Потокобезопасно: тёплый = процесс жив и модель загружена
    private var voskWarm: Bool {
        voskLock.lock(); defer { voskLock.unlock() }
        return voskReady && voskProc?.isRunning == true
    }
    private func setVoskReady(_ v: Bool) {
        voskLock.lock(); voskReady = v; voskLock.unlock()
        DispatchQueue.main.async { self.onVoskState?(v) }
    }

    /// Статус нейро-голоса наружу (галочка в меню-баре, правка автора 13.08):
    /// true = модель в памяти, чтение пойдёт красивым голосом сразу
    var onVoskState: ((Bool) -> Void)?
    var voiceLoaded: Bool { voskWarm }

    /// Выгрузить нейро-голос из памяти руками (вернуть 0.7 ГБ маку)
    func unloadVoice() {
        voskQueue.async { self.killVoskServer() }
    }

    /// Прогрев сервера заранее (модель грузится ~40 с) — зовётся с задержкой
    /// после старта приложения, чтобы первое чтение не ждало холодного старта
    func warmUpVoskIfNeeded() {
        guard let pref = Self.preferredRuVoiceId, pref.hasPrefix("vosk:") else { return }
        voskQueue.async { _ = self.ensureVoskServer() }
    }

    /// Холодный сервер → греем и ЖДЁМ, читать будем красивым (правило автора 13.09.2026:
    /// «при первом запросе на озвучку ты загружаешь красивый голос, и дальше всё»).
    /// Запасной голос — только если сервер вообще не поднялся (модель не скачана, умер).
    private func speakVosk(_ text: String, speakerId: Int) {
        piperBusy = true
        piperGen += 1
        let gen = piperGen
        voskPartQueue.removeAll()
        voskStreamDone = false
        voskAudioSec = 0
        voskSynthStartedAt = Date()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("diktovka-tts-\(UUID().uuidString)")
        if !voskWarm {
            AppLog.log("vosk-tts: холодный — грею и жду, читать буду красивым")
            startWarmupTicker(gen: gen)
        }
        voskQueue.async { [weak self] in
            guard let self else { return }
            let up = self.ensureVoskServer()
            DispatchQueue.main.async { self.stopWarmupTicker() }
            guard self.piperGen == gen else { return }   // пока грелись — отменили (⇧ или новое чтение)
            guard up else {
                DispatchQueue.main.async {
                    guard self.piperGen == gen else { return }
                    self.piperBusy = false
                    AppLog.log("vosk-tts: сервер не поднялся — читаю запасным")
                    self.onNotice?("Красивый голос не поднялся — читаю запасным")
                    self.fallbackAfterVosk(text)
                }
                return
            }
            DispatchQueue.main.async { self.voskSynthStartedAt = Date() }
            let gotAny = self.voskStream(text, speakerId: speakerId, base: base, gen: gen)
            DispatchQueue.main.async {
                guard self.piperGen == gen else { return }
                self.voskStreamDone = true
                let synth = Date().timeIntervalSince(self.voskSynthStartedAt)
                if self.voskAudioSec > 0 {
                    AppLog.log(String(format: "vosk-tts: синтез %d симв. за %.1f с, аудио %.1f с, RTF %.2f, скорость %.2g×",
                                      text.count, synth, self.voskAudioSec, synth / self.voskAudioSec, Self.readRate))
                }
                if gotAny {
                    self.playNextVoskIfIdle(gen: gen)
                } else {
                    self.piperBusy = false
                    AppLog.log("vosk-tts: синтез не вышел — читаю запасным голосом")
                    self.fallbackAfterVosk(text)
                }
            }
        }
    }

    // Пока греется — плашка с секундами, чтобы тишина не читалась как «не работает»
    private var warmupTicker: Timer?
    private var warmupStartedAt = Date()
    private var voskAudioSec: Double = 0        // сколько секунд звука пришло за это чтение
    private var voskSynthStartedAt = Date()

    private func startWarmupTicker(gen: Int) {
        warmupStartedAt = Date()
        onNotice?("🔥 Грею красивый голос — начну читать через ~30 с")
        warmupTicker?.invalidate()
        let t = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            guard let self, self.piperGen == gen else { self?.stopWarmupTicker(); return }
            let s = Int(Date().timeIntervalSince(self.warmupStartedAt))
            self.onNotice?("🔥 Грею красивый голос… \(s) с")
        }
        RunLoop.main.add(t, forMode: .common)
        warmupTicker = t
    }

    private func stopWarmupTicker() {
        warmupTicker?.invalidate()
        warmupTicker = nil
    }

    /// Только на voskQueue: задание серверу + приём кусков конвейера.
    /// true = хотя бы один кусок дошёл (значит что-то уже играет)
    private func voskStream(_ text: String, speakerId: Int, base: URL, gen: Int) -> Bool {
        guard ensureVoskServer(), let inH = voskIn else { return false }
        let job: [String: Any] = ["text": text, "out": base.path, "speaker": speakerId]
        guard let data = try? JSONSerialization.data(withJSONObject: job) else { return false }
        inH.write(data)
        inH.write(Data("\n".utf8))
        var gotAny = false
        while let line = voskReadLine(timeout: 120),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
            if let part = obj["part"] as? String {
                gotAny = true
                DispatchQueue.main.async {
                    self.enqueueVoskPart(URL(fileURLWithPath: part), gen: gen)
                }
                continue
            }
            if obj["done"] as? Bool == true { return gotAny }
            if let err = obj["error"] as? String {
                AppLog.log("vosk-tts: ошибка синтеза: \(err)")
                return gotAny
            }
        }
        AppLog.log("vosk-tts: сервер не ответил — перезапущу при следующем чтении")
        killVoskServer()
        return gotAny
    }

    // очередь готовых кусков (только main): играем по одному, стыки = паузы фраз
    private var voskPartQueue: [URL] = []
    private var voskStreamDone = false

    private func enqueueVoskPart(_ url: URL, gen: Int) {
        guard piperGen == gen else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 {
            voskAudioSec += Double(f.length) / f.processingFormat.sampleRate
        }
        voskPartQueue.append(url)
        playNextVoskIfIdle(gen: gen)
    }

    private func playNextVoskIfIdle(gen: Int) {
        guard piperGen == gen, !isPaused, !ratePlayer.isPlaying else { return }
        guard !voskPartQueue.isEmpty else {
            if voskStreamDone { piperBusy = false }
            return
        }
        let url = voskPartQueue.removeFirst()
        ratePlayer.play(url: url, rate: Self.readRate) { [weak self] in
            try? FileManager.default.removeItem(at: url)   // wav отыграл — освобождаем
            guard let self, self.piperGen == gen else { return }
            self.playNextVoskIfIdle(gen: gen)              // следующий кусок конвейера
        }
    }

    /// Сервер умер/не собрался — не молчать, а прочитать Русланом или системным
    private func fallbackAfterVosk(_ text: String) {
        let piperIds = Self.piperVoiceIds()
        if let ruslan = piperIds.first(where: { $0.contains("ruslan") }) ?? piperIds.first {
            let model = Self.piperDir.appendingPathComponent(String(ruslan.dropFirst("piper:".count)) + ".onnx")
            if FileManager.default.fileExists(atPath: model.path) {
                synthAndPlay(text, label: "piper") { p, wav in
                    p.executableURL = Self.piperBin
                    p.arguments = ["-m", model.path, "-f", wav.path]
                }
                return
            }
        }
        for chunk in Self.chunks(from: text) {
            let u = AVSpeechUtterance(string: chunk)
            u.voice = AVSpeechSynthesisVoice(language: "ru-RU")
            u.rate = Self.systemUtteranceRate()
            synth.speak(u)
        }
    }

    /// Только на voskQueue: поднять сервер и дождаться {"ready":true} (~40 с холодный)
    private func ensureVoskServer() -> Bool {
        if voskWarm { return true }
        killVoskServer()
        guard let script = Self.ttsHelperScript() else { return false }
        let p = Process()
        p.executableURL = Self.ttsVenvPython
        p.arguments = [script.path]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            AppLog.log("vosk-tts: сервер не запустился: \(error.localizedDescription)")
            return false
        }
        voskProc = p
        voskIn = inPipe.fileHandleForWriting
        voskOut = outPipe.fileHandleForReading
        voskBuf.removeAll()
        AppLog.log("vosk-tts: грею модель (~40 с при холодном старте)…")
        guard let line = voskReadLine(timeout: 120), line.contains("\"ready\"") else {
            AppLog.log("vosk-tts: модель не прогрелась")
            killVoskServer()
            return false
        }
        setVoskReady(true)
        AppLog.log("vosk-tts: голос №2 готов")
        return true
    }

    private func killVoskServer() {
        voskProc?.terminate()
        voskProc = nil
        voskIn = nil
        voskOut = nil
        setVoskReady(false)
        voskBuf.removeAll()
    }

    /// Построчное чтение из пайпа сервера (availableData порциями, до \n)
    private func voskReadLine(timeout: TimeInterval) -> String? {
        guard let out = voskOut else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let nl = voskBuf.firstIndex(of: UInt8(ascii: "\n")) {
                let line = voskBuf.prefix(upTo: nl)
                voskBuf.removeSubrange(...nl)
                return String(data: line, encoding: .utf8)
            }
            let chunk = out.availableData   // блокирует до порции данных
            if chunk.isEmpty { return nil } // пайп закрыт — сервер умер
            voskBuf.append(chunk)
        }
        return nil
    }

    /// Общий путь локального синтеза (piper / vosk-tts): процесс получает текст
    /// со stdin, пишет wav, мы проигрываем. configure настраивает бинарь и аргументы.
    // MARK: - Облачная озвучка (Яндекс)

    /// Читает облаком. Синтез идёт кусками в фоне, готовые куски встают в очередь и
    /// играются подряд — так первая фраза звучит через секунду, а не после всего текста.
    ///
    /// Сеть отвалилась — не молчим: первый же сбой роняет нас на локальный голос
    /// с плашкой. Молчащая кнопка хуже кривого голоса.
    private func speakYandex(_ text: String, voice: String) {
        guard let cfg0 = YandexTTS.config() else {
            AppLog.log("яндекс-озвучка: нет ключа — читаю локальным голосом")
            onNotice?("Нет ключа Яндекса — читаю локальным")
            speakLocally(text)
            return
        }
        var cfg = cfg0
        cfg.voice = voice.isEmpty ? cfg0.voice : voice

        yaGen += 1
        let gen = yaGen
        yaBusy = true
        yaDone = false
        yaQueue = []
        let parts = YandexTTS.chunks(text)
        let simvolov = text.count
        AppLog.log("яндекс-озвучка: \(simvolov) символов, \(parts.count) кусок(ов), голос \(cfg.voice), ≈\(String(format: "%.2f", Double(simvolov) / 1000 * cfg.rubPer1000)) ₽")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (i, part) in parts.enumerated() {
                guard let self, self.yaGen == gen else { return }
                // Слабый интернет рвёт ОДИН кусок (-1005 «connection was lost», -1001 таймаут),
                // а не связь целиком — переспрашиваем трижды (инцидент 19.09.2026: сказала три
                // фразы и замолчала на куске четыре). Пауза между попытками растёт.
                var gotovo: URL?
                var posledniy: Error?
                for popytka in 0..<3 {
                    do { gotovo = try YandexTTS.synthesize(part, config: cfg); break }
                    catch {
                        posledniy = error
                        guard self.yaGen == gen, YandexTTS.setevaya(error), popytka < 2 else { break }
                        AppLog.log("яндекс-озвучка: кусок \(i + 1) не дошёл (попытка \(popytka + 1)) — переспрашиваю")
                        DispatchQueue.main.async {
                            guard self.yaGen == gen else { return }
                            self.onNotice?("📡 Слабый интернет — переспрашиваю")
                        }
                        Thread.sleep(forTimeInterval: popytka == 0 ? 1.0 : 3.0)
                    }
                }
                guard let wav = gotovo else {
                    AppLog.log("яндекс-озвучка: кусок \(i + 1) из \(parts.count) не дошёл после трёх попыток — дочитываю локальным (\(posledniy.map { String(describing: $0) } ?? "?"))")
                    let hvost = parts[i...].joined(separator: " ")
                    DispatchQueue.main.async {
                        guard self.yaGen == gen else { return }
                        self.yaDone = true
                        self.onNotice?(i == 0 ? "Яндекс не ответил — читаю локальным"
                                              : "📡 Интернет пропал — дочитываю локальным голосом")
                        self.yaTail = hvost          // дочитаем, когда доиграет уже готовое
                        self.drainYaTailIfIdle(gen: gen)
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard self.yaGen == gen else { try? FileManager.default.removeItem(at: wav); return }
                    self.yaQueue.append(wav)
                    self.playNextYandex(gen: gen)
                }
            }
            DispatchQueue.main.async {
                guard let self, self.yaGen == gen else { return }
                self.yaDone = true
                if self.yaQueue.isEmpty && !self.yaPlaying { self.yaBusy = false }
            }
        }
    }

    private func playNextYandex(gen: Int) {
        guard yaGen == gen, !yaPlaying, !yaQueue.isEmpty else { return }
        let url = yaQueue.removeFirst()
        yaPlaying = true
        ratePlayer.play(url: url, rate: Self.readRate) { [weak self] in
            guard let self else { return }
            try? FileManager.default.removeItem(at: url)
            self.yaPlaying = false
            guard self.yaGen == gen else { return }
            if !self.yaQueue.isEmpty { self.playNextYandex(gen: gen) }
            else if self.yaTail != nil { self.drainYaTailIfIdle(gen: gen) }
            else if self.yaDone { self.yaBusy = false }
        }
    }

    /// Хвост, который облако не дожевало, читаем локальным голосом — но только когда
    /// доиграет уже синтезированное, иначе два голоса заговорят разом.
    ///
    /// Здесь же чинится главная беда инцидента 19.09.2026: раньше при обрыве посреди
    /// текста `yaBusy` оставался true НАВСЕГДА. Чтение молчало, а `isSpeaking` врал «читаю»
    /// — и следующий правый ⇧ попадал в ветку «стоп» вместо нового чтения. Автор дословно:
    /// «зажимаю шифт — она типа перестаёт озвучивать, но по факту она перестала уже до этого».
    private func drainYaTailIfIdle(gen: Int) {
        guard yaGen == gen, let tail = yaTail, yaQueue.isEmpty, !yaPlaying else { return }
        yaTail = nil
        yaBusy = false                 // облако кончилось — состояние честное
        speakLocally(tail)
    }

    /// Локальный путь без облака — запасной выход и для «Яндекс молчит», и для
    /// коротких служебных фраз. Повторяет хвост speak(), но без выбора облака.
    private func speakLocally(_ clean: String) {
        for chunk in Self.chunks(from: clean) {
            let u = AVSpeechUtterance(string: chunk)
            u.voice = Self.systemRuVoice() ?? AVSpeechSynthesisVoice(language: "ru-RU")
            u.rate = Self.systemUtteranceRate()
            synth.speak(u)
        }
    }

    private func synthAndPlay(_ text: String, label: String,
                              configure: @escaping (Process, URL) -> Void) {
        piperBusy = true
        piperGen += 1
        let gen = piperGen
        let wav = FileManager.default.temporaryDirectory
            .appendingPathComponent("diktovka-tts-\(UUID().uuidString).wav")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let p = Process()
            configure(p, wav)
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            let inPipe = Pipe()
            p.standardInput = inPipe
            do { try p.run() } catch {
                AppLog.log("\(label) не запустился: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.piperBusy = false }
                return
            }
            DispatchQueue.main.async { self?.piperProc = p }
            if let d = text.data(using: .utf8) {
                inPipe.fileHandleForWriting.write(d)
            }
            try? inPipe.fileHandleForWriting.close()
            p.waitUntilExit()
            DispatchQueue.main.async {
                guard let self, self.piperGen == gen else {
                    try? FileManager.default.removeItem(at: wav)
                    return
                }
                self.piperProc = nil
                guard p.terminationStatus == 0 else {
                    self.piperBusy = false
                    try? FileManager.default.removeItem(at: wav)
                    AppLog.log("\(label) не синтезировал (код \(p.terminationStatus))")
                    return
                }
                self.ratePlayer.play(url: wav, rate: Self.readRate) { [weak self] in
                    try? FileManager.default.removeItem(at: wav)
                    self?.piperBusy = false
                }
            }
        }
    }

    // MARK: - Чистка текста

    /// Убираем всё, что голосу читать не надо: *, `, →, =====, \, эмодзи, кавычки…
    /// Остаются буквы, цифры, пробелы и обычные знаки препинания.
    static func sanitize(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(.whitespacesAndNewlines)
        allowed.formUnion(CharacterSet(charactersIn: ".,!?;:—–-()%№"))
        var scalars = String.UnicodeScalarView()
        let space: Unicode.Scalar = " "
        for sc in text.unicodeScalars {
            scalars.append(allowed.contains(sc) ? sc : space)
        }
        var s = String(scalars)
        s = s.replacingOccurrences(of: "[-—–]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Предложения, склеенные в куски до ~400 символов
    static func chunks(from text: String, maxLen: Int = 400) -> [String] {
        var sentences: [String] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .bySentences) { sub, _, _, _ in
            if let sub, !sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(sub)
            }
        }
        if sentences.isEmpty { return [text] }
        var result: [String] = []
        var current = ""
        for s in sentences {
            if current.count + s.count > maxLen && !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += s
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
