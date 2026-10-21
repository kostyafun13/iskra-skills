import Foundation

/// ОБЛАЧНАЯ ОЗВУЧКА — Яндекс SpeechKit (решение автора 18.09.2026).
///
/// Дословно: «меня раздражает, что у меня звучание кривое… а что если бы я просто делал
/// тоже через Яндекс-студию воспроизведение? Если там меньше 200 ₽ в неделю — железобетонно
/// берём, меньше 400 — окей, тоже, бери сразу, делай».
///
/// **Посчитано по факту, а не на глаз.** `app.log` за последние семеро суток: 109 озвучек,
/// 215 062 символа. По тарифу 1,32 ₽ за 1000 символов — 284 ₽ в неделю, в среднем по
/// тридцати суткам лога — 213 ₽. Обе цифры ниже планки в 400 ₽, поэтому включено сразу.
///
/// **Ключ — только твой и только в .env.** `tts.json` хранит не сам ключ, а путь к файлу
/// `.env` (`env_file`) и имя переменной (`env_var`, по умолчанию `YANDEX_API_KEY`) — тот же
/// `.env`, что заводит скил подключения расшифровки. Путь можно писать через `~`.
/// Ключа нет — облачные голоса и облачное распознавание просто не показываются.
enum YandexTTS {

    struct Config {
        var apiKey: String
        var voice: String
        var rubPer1000: Double
        var useV3: Bool          // v3 вдвое дешевле v1, но принимает не больше 250 знаков за раз
    }

    static var configURL: URL {
        Transcriber.appSupportDir.appendingPathComponent("tts.json")
    }

    private static let defaultConfig = """
    {
      "env_file": "",
      "env_var": "YANDEX_API_KEY",
      "voice": "alena",
      "api": "v3",
      "rub_per_1000": 0.65,
      "_голоса": "alena, filipp, ermil, jane, zahar, dasha, julia, lera, masha, marina, alexander, kirill, anton"
    }
    """

    /// Конфиг читаем при каждом синтезе — правка голоса подхватывается без перезапуска
    static func config() -> Config? {
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.createDirectory(at: Transcriber.appSupportDir, withIntermediateDirectories: true)
            try? defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
        }
        guard let data = try? Data(contentsOf: configURL),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var key = j["key"] as? String ?? ""
        if key.isEmpty,
           let envFile = (j["env_file"] as? String).map({ NSString(string: $0).expandingTildeInPath }),
           !envFile.isEmpty,
           let envVar = j["env_var"] as? String,
           let env = try? String(contentsOfFile: envFile, encoding: .utf8) {
            for line in env.split(separator: "\n") where line.hasPrefix("\(envVar)=") {
                key = String(line.dropFirst(envVar.count + 1))
                    .split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
                key = key.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                break
            }
        }
        guard !key.isEmpty else { return nil }
        let v3 = (j["api"] as? String ?? "v3").lowercased() != "v1"
        return Config(apiKey: key,
                      voice: j["voice"] as? String ?? "alena",
                      rubPer1000: j["rub_per_1000"] as? Double ?? (v3 ? 0.65 : 1.342),
                      useV3: v3)
    }

    static var isAvailable: Bool { config() != nil }

    /// Доступные голоса для меню. Список фиксированный: у Яндекса нет метода «перечисли
    /// голоса», а дёргать синтез ради проверки — платить за пустое.
    static let voices = ["alena", "filipp", "ermil", "jane", "zahar", "omazh", "dasha", "julia", "lera", "masha", "marina", "alexander", "kirill", "anton"]

    static func displayName(_ voice: String) -> String {
        let ru = ["alena": "Алёна", "filipp": "Филипп", "ermil": "Ермил", "jane": "Джейн",
                  "zahar": "Захар", "omazh": "Омаж", "dasha": "Даша", "julia": "Юля",
                  "lera": "Лера", "masha": "Маша", "marina": "Марина",
                  "alexander": "Александр", "kirill": "Кирилл", "anton": "Антон"]
        return "☁️ Яндекс · " + (ru[voice] ?? voice)
    }

    enum TTSError: Error { case noKey, http(Int, String), empty }

    /// Синтез одного куска → WAV на диске. Синхронный: зовут с фонового потока.
    ///
    /// Формат просим `lpcm` 48 кГц, а не `oggopus`: движок воспроизведения читает файл
    /// через AVAudioFile, а ogg/opus он нативно не открывает. Сырой PCM сами заворачиваем
    /// в WAV — на один шаг меньше зависимостей и никакого перекодирования.
    /// Единая точка: v3 (дёшево, куски до 240 знаков) с откатом на v1 при сбое.
    /// Откат важен: v3 у Яндекса строже к тексту, и падать из-за одной фразы нельзя.
    static func synthesize(_ text: String, config cfg: Config) throws -> URL {
        do { return try synthesizeOnce(text, config: cfg) }
        catch {
            // Повтор по ТОМУ ЖЕ соединению бесполезен (инцидент 23.09.2026): застрявшее
            // HTTP/2-соединение к Яндексу держалось в пуле URLSession, и все три попытки
            // висели на нём по 22 с. В те же секунды ИИ-правка проходила за полторы секунды,
            // а curl к тому же адресу отвечал за 1,2 с — сеть была жива, мёртвым было одно
            // соединение. Выбрасываем пул — следующая попытка откроет свежее.
            if setevaya(error) { sbrosSoedineniy() }
            throw error
        }
    }

    private static func synthesizeOnce(_ text: String, config cfg: Config) throws -> URL {
        if cfg.useV3 {
            do { return try synthesizeV3(text, config: cfg) }
            catch {
                // Оборвалась СЕТЬ — v1 поедет по той же сети и так же не доедет, а ждать
                // будем вдвое дольше (инцидент 19.09.2026, слабый вайфай: v3 висел
                // 45 с, потом v1 ещё 10 с, и всё это время чтение молчало). Отдаём ошибку
                // наверх — там повтор. В v1 откатываемся только когда v3 не осилил сам текст.
                if setevaya(error) { throw error }
                AppLog.log("яндекс-озвучка: v3 не смог (\(error)) — пробую v1")
                return try synthesizeV1(text, config: cfg)
            }
        }
        return try synthesizeV1(text, config: cfg)
    }

    /// Своя сессия, а не общая `URLSession.shared`: общий пул нельзя сбросить, не задев
    /// ИИ-правку и распознавание, а застрявшее соединение в нём живёт минутами.
    ///
    /// Таймауты по замеру 23.09.2026 (пять синтезов подряд): первый байт 0,6–0,8 с, кусок
    /// целиком 1,2–2,8 с. Поэтому 8 с тишины без единого пакета — уже мёртвое соединение
    /// (было 20), а 20 с на весь кусок оставляют запас медленной кухонной сети.
    private static let tishinaSek: TimeInterval = 8
    private static let kusokSek: TimeInterval = 20
    private static let sessiyaLock = NSLock()
    private static var sessiya = novayaSessiya()

    private static func novayaSessiya() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = tishinaSek
        c.timeoutIntervalForResource = kusokSek
        return URLSession(configuration: c)
    }

    /// Выбросить все соединения к Яндексу: зависшие запросы отменяются, следующий
    /// запрос заново открывает TCP и TLS.
    static func sbrosSoedineniy() {
        sessiyaLock.lock()
        let staraya = sessiya
        sessiya = novayaSessiya()
        sessiyaLock.unlock()
        staraya.invalidateAndCancel()
        AppLog.log("яндекс-озвучка: сбросил соединения — повтор пойдёт по свежему")
    }

    /// Синхронный запрос. Не дождались — ОТМЕНЯЕМ задачу: раньше она оставалась висеть
    /// в фоне и держала то самое соединение, по которому шёл повтор.
    private static func zapros(_ req: URLRequest) throws -> (Data?, Int) {
        sessiyaLock.lock()
        let s = sessiya
        sessiyaLock.unlock()
        var out: Data?, err: Error?, code = 0
        let sem = DispatchSemaphore(value: 0)
        let task = s.dataTask(with: req) { d, resp, e in
            out = d; err = e; code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + kusokSek + 1) == .timedOut {
            task.cancel()
            throw URLError(.timedOut)
        }
        if let err { throw err }
        return (out, code)
    }

    /// Сетевая ошибка (обрыв, таймаут, DNS, 5xx, «слишком часто») лечится повтором;
    /// отказ по ключу или по тексту (4xx) — не лечится, повторять бесполезно.
    static func setevaya(_ error: Error) -> Bool {
        if let e = error as? TTSError, case .http(let code, _) = e {
            return code == 0 || code == 429 || code >= 500
        }
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// v3: тарифицируется блоками по 250 знаков — 0,65 ₽ за 1000 против 1,34 ₽ у v1.
    /// Ответ приходит потоком JSON-строк, в каждой кусок звука в base64; склеиваем подряд.
    ///
    /// **Просим MP3, а не сырой PCM (инцидент 24.09.2026).** Кусок в 240 знаков сырым
    /// звуком 48 кГц — это 1,4 МБ, в base64 ответ 2 МБ. На медленном канале (замер на VPN
    /// ~80 КБ/с) это 24 с на кусок при пороге 20 с, отсюда «слабый интернет» при живой сети
    /// и паузы между фразами. Тот же кусок в MP3 (64 кбит/с) —
    /// 168 КБ и 1,1 с по тому же туннелю. Кадры MP3 склеиваются подряд без заголовков,
    /// AVAudioFile читает .mp3 сам, `afinfo` подтвердил 48 кГц моно, 15,6 с звука.
    static func synthesizeV3(_ text: String, config cfg: Config) throws -> URL {
        var req = URLRequest(url: URL(string: "https://tts.api.cloud.yandex.net/tts/v3/utteranceSynthesis")!)
        req.httpMethod = "POST"
        req.setValue("Api-Key \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = tishinaSek
        let body: [String: Any] = [
            "text": text,
            "outputAudioSpec": ["containerAudio": ["containerAudioType": "MP3"]],
            "hints": [["voice": cfg.voice]],
            "loudnessNormalizationType": "LUFS",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (out, code) = try zapros(req)
        guard code == 200, let raw = out, let body = String(data: raw, encoding: .utf8) else {
            let msg = String(data: out ?? Data(), encoding: .utf8) ?? ""
            throw TTSError.http(code, String(msg.prefix(200)))
        }

        var mp3 = Data()
        for line in body.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let result = j["result"] as? [String: Any],
                  let chunk = result["audioChunk"] as? [String: Any],
                  let b64 = chunk["data"] as? String,
                  let bytes = Data(base64Encoded: b64) else { continue }
            mp3.append(bytes)
        }
        guard !mp3.isEmpty else { throw TTSError.empty }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diktovka-ya-\(UUID().uuidString).mp3")
        try mp3.write(to: url)
        return url
    }

    static func synthesizeV1(_ text: String, config cfg: Config) throws -> URL {
        var req = URLRequest(url: URL(string: "https://tts.api.cloud.yandex.net/speech/v1/tts:synthesize")!)
        req.httpMethod = "POST"
        req.setValue("Api-Key \(cfg.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = tishinaSek
        var params = URLComponents()
        params.queryItems = [
            .init(name: "text", value: text),
            .init(name: "lang", value: "ru-RU"),
            .init(name: "voice", value: cfg.voice),
            .init(name: "format", value: "lpcm"),
            .init(name: "sampleRateHertz", value: "48000"),
        ]
        req.httpBody = params.percentEncodedQuery?.data(using: .utf8)

        let (out, code) = try zapros(req)
        guard code == 200, let pcm = out, !pcm.isEmpty else {
            let body = String(data: out ?? Data(), encoding: .utf8) ?? ""
            throw TTSError.http(code, String(body.prefix(200)))
        }

        return try wav(from: pcm)
    }

    /// Int16 LE → Float → WAV на диске (движок воспроизведения читает файл, не поток)
    private static func wav(from pcm: Data) throws -> URL {
        var samples = [Float](); samples.reserveCapacity(pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Int16.self)
            for v in ptr { samples.append(Float(Int16(littleEndian: v)) / 32768.0) }
        }
        guard !samples.isEmpty else { throw TTSError.empty }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diktovka-ya-\(UUID().uuidString).wav")
        try WavWriter.write(samples: samples, sampleRate: 48000, to: url)
        return url
    }

    /// Куски под лимит запроса. Режем по границам предложений: разрыв посреди фразы
    /// слышен паузой не там, где надо.
    static func chunks(_ text: String, limit: Int = 240) -> [String] {
        var out: [String] = []
        var cur = ""
        for sentence in text.split(omittingEmptySubsequences: false, whereSeparator: { ".!?\n".contains($0) }) {
            let piece = String(sentence).trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            let add = piece + ". "
            if cur.count + add.count > limit, !cur.isEmpty { out.append(cur); cur = "" }
            if add.count > limit {   // одно гигантское предложение — режем по словам
                for word in add.split(separator: " ") {
                    if cur.count + word.count + 1 > limit { out.append(cur); cur = "" }
                    cur += word + " "
                }
            } else {
                cur += add
            }
        }
        if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
        return out.isEmpty ? [text] : out
    }
}
