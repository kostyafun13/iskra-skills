import Foundation

/// ОБЛАЧНОЕ РАСПОЗНАВАНИЕ — страховка от затора локального движка (заказ автора 18.09.2026).
///
/// Дословно: «когда я зажимаю и долго разговариваю, я отвлекаюсь от экрана, начинаю ходить,
/// у меня мысли текут потоком… и посередине потока обрывается. Меня это бесит. Я бы хотел,
/// чтобы он записывал дорожку, отправлял её в Яндекс, а там уже передавал мне текстовку».
///
/// **Что на самом деле рвалось.** Не лимит записи — лимита там нет, трёхминутные диктовки
/// пишутся целиком. Рвалась СКОРОСТЬ: локальный движок на этом маке распознаёт кусок в 20
/// секунд за 7 секунд по медиане, но каждый четвёртый — дольше 19 секунд, а худшие случаи
/// доходили до 96. Очередь копится, текст отстаёт на минуту, и поток мысли теряется.
/// Замер облака на тех же кусках: 1,6 секунды. Разница в пять-десять раз.
///
/// **Поэтому не «всё в облако», а гибрид.** Локальный движок бесплатный и обычно успевает;
/// облако включается, только когда он не справляется. По логу это примерно треть кусков —
/// около тысячи рублей в месяц вместо двух с половиной тысяч за полный перевод.
///
/// **Точность словами не хуже, но текст приходит сырым** — без пунктуации и заглавных.
/// Это не беда: следом всё равно работает ИИ-правка, которая ставит знаки и убирает
/// «короче». Термины чинит словарик `words.txt`, и он один и тот же для обоих движков.
enum YandexSTT {

    /// Читаем ключ там же, где озвучка — свой конфиг не плодим
    static func apiKey() -> String? { YandexTTS.config()?.apiKey }

    static var isAvailable: Bool { apiKey() != nil }

    enum STTError: Error { case noKey, http(Int, String), tooBig }

    /// Кусок WAV (16 кГц моно, как пишет `AudioRecorder`) → текст. Синхронный: зовут с фона.
    ///
    /// Шлём сырой PCM: у синхронного распознавания лимит миллион байт и тридцать секунд,
    /// а наши куски не длиннее двадцати четырёх — влезают с запасом. Заголовок WAV срезаем,
    /// параметры передаём в строке запроса.
    static func recognize(wav url: URL) throws -> String {
        guard let key = apiKey() else { throw STTError.noKey }
        let data = try Data(contentsOf: url)
        // WAV от WavWriter: 44 байта заголовка, дальше Int16 LE
        let pcm = data.count > 44 ? data.dropFirst(44) : data
        guard pcm.count <= 1_000_000 else { throw STTError.tooBig }

        var req = URLRequest(url: URL(string:
            "https://stt.api.cloud.yandex.net/speech/v1/stt:recognize?lang=ru-RU&format=lpcm&sampleRateHertz=16000")!)
        req.httpMethod = "POST"
        req.setValue("Api-Key \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = pcm
        req.timeoutInterval = 20      // дольше ждать смысла нет: локальный уже успел бы

        var out: Data?, err: Error?, code = 0
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, e in
            out = d; err = e; code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 25)

        if let err { throw err }
        guard code == 200, let d = out,
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw STTError.http(code, String((String(data: out ?? Data(), encoding: .utf8) ?? "").prefix(200)))
        }
        return (j["result"] as? String) ?? ""
    }

    /// Во сколько обошёлся кусок: тарификация блоками по 15 секунд, неполный блок — целиком
    static func rubles(forSeconds sec: Double) -> Double {
        max(1, ceil(sec / 15)) * 0.1626
    }
}
