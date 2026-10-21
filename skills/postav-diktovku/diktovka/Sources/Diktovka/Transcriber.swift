import Foundation

/// Обвязка распознавания: облако Яндекса по твоему ключу и/или локальный движок —
/// резидентный python-процесс (venv + onnx-asr + GigaAM v3, ставит install_engine.sh),
/// общение JSON-строками через пайпы. Локального движка нет — работаем облаком.
final class Transcriber {
    enum State: Equatable {
        case idle, starting, loadingModel, ready
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet {
            let s = state
            DispatchQueue.main.async { self.onStateChange?(s) }
        }
    }
    var onStateChange: ((State) -> Void)?
    var onResult: ((Int, String, String?) -> Void)?   // (id куска, текст, ошибка движка) — на main

    /// Папка данных: ~/Library/Application Support/Diktovka. `DIKTOVKA_HOME` в окружении —
    /// другая папка: проверка сборки, не трогая рабочие настройки, историю и журналы.
    static let appSupportDir: URL = {
        if let h = ProcessInfo.processInfo.environment["DIKTOVKA_HOME"], !h.isEmpty {
            return URL(fileURLWithPath: NSString(string: h).expandingTildeInPath)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diktovka")
    }()
    static let logURL = appSupportDir.appendingPathComponent("engine.log")

    // ── ОБЛАЧНАЯ СТРАХОВКА (заказ автора 18.09.2026)
    // Локальный движок бесплатный, но на этом маке каждый четвёртый кусок ждёт дольше
    // 19 секунд, а худшие — до полутора минут: очередь копится, текст отстаёт, поток мысли
    // рвётся. Поэтому кусок уходит в облако, когда локальный ЯВНО не справляется —
    // в очереди уже столько, сколько задано порогом, или движок ещё грузит модель.
    enum Route: String { case local, hybrid, cloud }
    static let routeKey = "asrRoute"
    static var route: Route {
        get { Route(rawValue: UserDefaults.standard.string(forKey: routeKey) ?? "") ?? .hybrid }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: routeKey) }
    }
    /// Локальный движок поставлен (install_engine.sh): есть venv с python
    static var localInstalled: Bool {
        FileManager.default.fileExists(atPath: appSupportDir.appendingPathComponent("venv/bin/python3").path)
    }
    /// Только облако: так выбрано в меню или локальный движок не ставили, а ключ Яндекса есть.
    /// Python тогда не поднимаем вовсе — диктовка готова сразу после запуска.
    static var cloudOnly: Bool { YandexSTT.isAvailable && (route == .cloud || !localInstalled) }

    /// Сколько кусков должно ждать локальный движок, чтобы следующий ушёл в облако
    private let cloudAfterQueue = 2
    private var inFlight = 0            // отправлено в локальный движок и ещё не вернулось
    private(set) var cloudSpentRub = 0.0
    private(set) var cloudChunks = 0

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var lineBuffer = Data()
    private var nextId = 1
    private let writeQueue = DispatchQueue(label: "diktovka.engine.write")

    func start() {
        guard process == nil else { return }
        if Self.cloudOnly {
            if state != .ready { state = .ready }
            return
        }
        lineBuffer = Data() // хвост от прошлого (умершего) процесса не клеим к новому
        state = .starting

        let venvPython = Self.appSupportDir.appendingPathComponent("venv/bin/python3")
        guard FileManager.default.fileExists(atPath: venvPython.path) else {
            // сюда попадаем, только если и ключа Яндекса нет: с ключом сработал бы cloudOnly
            state = .failed("нет ключа Яндекса и локального движка — настрой по скилу «Поставь Диктовку»")
            return
        }
        guard let script = Self.findHelperScript() else {
            state = .failed("не найден helper/asr_server.py")
            return
        }

        try? FileManager.default.createDirectory(at: Self.appSupportDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Self.logURL.path) {
            FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        }

        let p = Process()
        p.executableURL = venvPython
        p.arguments = ["-u", script.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = Self.appSupportDir.appendingPathComponent("hf-cache").path
        p.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        if let errHandle = try? FileHandle(forWritingTo: Self.logURL) {
            errHandle.seekToEndOfFile()
            p.standardError = errHandle
        }

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else {
                // EOF: обязательно снять хендлер, иначе dispatch source крутится
                // с пустыми данными вечно — 100% одного ядра до перезапуска
                h.readabilityHandler = nil
                return
            }
            self?.consume(d)
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.stdinHandle = nil
                if case .failed = self.state { return }
                self.state = .failed("движок остановился (код \(proc.terminationStatus)) — см. лог")
            }
        }

        do { try p.run() } catch {
            state = .failed("python не запустился: \(error.localizedDescription)")
            return
        }
        process = p
        stdinHandle = inPipe.fileHandleForWriting
    }

    func restartIfDead() {
        if process == nil { start() }
    }

    func stop() {
        send(["cmd": "quit"])
        process?.terminate()
        process = nil
    }

    /// Отдать wav в очередь распознавания; вернёт id куска.
    /// Кому именно отдать — решается здесь, снаружи ничего не меняется: и локальный движок,
    /// и облако отвечают одним и тем же `onResult(id, текст, ошибка)`.
    func transcribe(fileURL: URL, deleteAfter: Bool = true) -> Int {
        let id = nextId
        nextId += 1

        if shouldGoCloud() {
            sendToCloud(id: id, url: fileURL, deleteAfter: deleteAfter)
            return id
        }

        inFlight += 1
        var obj: [String: Any] = ["id": id, "wav": fileURL.path]
        if !deleteAfter { obj["keep"] = true }
        send(obj)
        return id
    }

    private func shouldGoCloud() -> Bool {
        guard YandexSTT.isAvailable else { return false }
        if Self.cloudOnly { return true }
        switch Self.route {
        case .local:  return false
        case .cloud:  return true
        case .hybrid: return inFlight >= cloudAfterQueue || state != .ready
        }
    }

    /// Облачный путь. Ошибка сети не теряет кусок — он падает обратно в локальный движок:
    /// лучше подождать, чем потерять мысль.
    private func sendToCloud(id: Int, url: URL, deleteAfter: Bool) {
        let prichina = Self.cloudOnly ? "только облако" : state == .ready ? "очередь \(inFlight)" : "движок не готов"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let text = try YandexSTT.recognize(wav: url)
                let sec = Double((try? Data(contentsOf: url).count).map { ($0 - 44) / 2 } ?? 0) / 16000
                if deleteAfter { try? FileManager.default.removeItem(at: url) }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cloudChunks += 1
                    self.cloudSpentRub += YandexSTT.rubles(forSeconds: sec)
                    AppLog.log(String(format: "кусок #%d: облако (%@) — %.0f с за %@, ≈%.2f ₽",
                                      id, prichina, sec, "запрос", YandexSTT.rubles(forSeconds: sec)))
                    self.onResult?(id, text, nil)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    // локального движка нет (режим «только облако») — отдавать некому:
                    // честная ошибка, звук сессии остаётся в архиве записей на неделю
                    guard self.process?.isRunning == true else {
                        AppLog.log("кусок #\(id): облако не смогло (\(error)), локального движка нет")
                        if deleteAfter { try? FileManager.default.removeItem(at: url) }
                        self.onResult?(id, "", "облако Яндекса не ответило — проверь интернет и ключ")
                        return
                    }
                    AppLog.log("кусок #\(id): облако не смогло (\(error)) — отдаю локальному движку")
                    self.inFlight += 1
                    var obj: [String: Any] = ["id": id, "wav": url.path]
                    if !deleteAfter { obj["keep"] = true }
                    self.send(obj)
                }
            }
        }
    }

    // MARK: - Внутренности

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        writeQueue.async { [weak self] in
            guard let self, let h = self.stdinHandle, self.process?.isRunning == true else { return }
            h.write(data)
            h.write(Data([0x0A]))
        }
    }

    private func consume(_ d: Data) {
        lineBuffer.append(d)
        while let r = lineBuffer.range(of: Data([0x0A])) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<r.lowerBound)
            lineBuffer.removeSubrange(lineBuffer.startIndex..<r.upperBound)
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let event = obj["event"] as? String {
            // state держим на main: сюда мы приходим с фонового потока пайпа
            DispatchQueue.main.async {
                switch event {
                case "loading": self.state = .loadingModel
                case "ready": self.state = .ready
                case "fatal": self.state = .failed((obj["error"] as? String) ?? "ошибка движка — см. лог")
                default: break
                }
            }
            return
        }
        if let id = obj["id"] as? Int {
            let text = (obj["text"] as? String) ?? ""
            let error = obj["error"] as? String
            DispatchQueue.main.async {
                self.inFlight = max(0, self.inFlight - 1)
                self.onResult?(id, text, error)
            }
        }
    }

    private static func findHelperScript() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("helper/asr_server.py"))
        }
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(exeDir.appendingPathComponent("../Resources/helper/asr_server.py").standardized)
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("helper/asr_server.py"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
