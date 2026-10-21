import AVFoundation
import CoreAudio
import AudioToolbox

/// Запись микрофона → 16 кГц моно float. Псевдостриминг: GigaAM не ест куски >25 с,
/// поэтому после 20 с ищем паузу в речи (тихие последние 0.3 с) и режем по ней;
/// на 24 с режем в самом тихом окне хвоста, чтобы не рубить слово посередине.
/// Куски уходят через onChunk по порядку.
///
/// Аудиограф: СВЕЖИЙ AVAudioEngine на каждый старт (протухший граф после смен
/// конфигурации кидал глотаемое NSException — корень «тихих отказов» 26-27.07).
/// Скачки входа во время записи (диалог Cursor / гарнитура дёргают устройство,
/// 48↔24 кГц) переживаем на лету: пере-подключаем вход, буфер не теряем.
///
/// Вход ПРИБИВАЕМ к конкретному устройству, а не берём «дефолт» (28.07): Bluetooth-наушники
/// как вход отдают нули, пока система переключает их в режим гарнитуры, а после их отвала
/// дефолтный вход становится фантомом (44100/2 кан.) и старт падает NSException'ом.
/// До 13.09.2026 это всегда был встроенный микрофон мака — из-за этого внешний микрофон
/// Boya никогда не подхватывался (автор: «не всегда переключается на него»). Теперь
/// устройство выбирает chooseDevice(): авто — внешний проводной, если подключён, иначе
/// встроенный; либо то, что автор выбрал в меню «🎙 Микрофон». Bluetooth-входы в авто-режиме
/// не берём никогда (та самая боль 28.07/04.08), вручную — можно.
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?     // громкость 0…1 для эквалайзера (main)
    /// С какого устройства идёт (шла) запись — для плашки и меню
    private(set) var activeDevice: InputDevice?
    var activeLabel: String { activeDevice?.name ?? "системный вход" }
    var onChunk: ((URL) -> Void)?       // готовый wav-кусок (main, строго по порядку)
    var onInterrupted: (() -> Void)?    // вход не удалось удержать — сессия завершается (main)

    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "diktovka.audio")
    /// Кладбище движков: старый AVAudioEngine хороним ЗДЕСЬ, а не на главном потоке (см. engineUp)
    private let reaper = DispatchQueue(label: "diktovka.audio.reaper")
    private var samples: [Float] = []
    private var recording = false
    private var configObserver: NSObjectProtocol?
    private var restartWork: DispatchWorkItem?
    private var restartCount = 0
    private var lastBufferAt = Date.distantPast
    private var converter: AVAudioConverter?   // ленивый: подстраивается под фактический поток
    private var archiveFile: AVAudioFile?      // архив сессии (zapisi/*.m4a), трогаем только на queue
    private var archivedFrames = 0             // сколько кадров ушло в архив (только на queue)
    private(set) var archiveURL: URL?          // файл текущей/последней сессии

    private let sampleRate = 16000
    // Мягкий рез — с 15 с (было 20, правка 13.09.2026): в окне 20–24 с настоящей паузы
    // часто не было, и рез шёл по самому тихому месту — посреди слова
    // («транспри…» | «Крибирировать» в логе 13.09)
    private var softLimit: Int { 15 * sampleRate }     // с этой длины ждём паузу
    private var hardLimit: Int { 24 * sampleRate }     // тут режем принудительно
    private var silenceWindow: Int { sampleRate * 3 / 10 }  // 0.3 с — окно «самого тихого места»
    private var cutSilence: Int { sampleRate / 2 }          // 0.5 с настоящей паузы для мягкого реза
    private var minChunk: Int { sampleRate * 3 / 10 }       // короче — отбрасываем
    private let silenceThreshold: Float = 0.012        // порог ПАУЗЫ (для нарезки)
    private let dropThreshold: Float = 0.004           // порог «весь кусок — тишина» (мягче!)

    func start() throws {
        guard !recording else { return }
        restartCount = 0
        queue.sync { samples.removeAll() }
        try engineUpWithFallback()
        recording = true
        openArchive()
    }

    // MARK: - Архив звука (правило автора 13.09.2026)

    /// Один m4a на сессию; не открылся — диктовка идёт как шла, просто без архива
    private func openArchive() {
        archiveURL = nil
        guard AudioArchive.enabled,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                      channels: 1, interleaved: false) else { return }
        let url = AudioArchive.newFileURL()
        guard let f = AudioArchive.open(url, format: fmt) else { return }
        archiveURL = url
        queue.async { self.archiveFile = f; self.archivedFrames = 0 }
    }

    /// Закрыть файл сессии; отменённую или пустую (короче minChunk) — удалить
    private func closeArchive(delete: Bool) {
        let url = archiveURL
        queue.async {
            let frames = self.archivedFrames
            self.archiveFile = nil   // AVAudioFile дописывает заголовок при освобождении
            if let url, delete || frames < self.minChunk {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Только на queue: буфер 16 кГц в архив; сбой — лог и дальше без архива
    private func archiveWrite(_ buf: AVAudioPCMBuffer) {
        guard let f = archiveFile else { return }
        do {
            try f.write(from: buf)
            archivedFrames += Int(buf.frameLength)
        } catch {
            AppLog.log("архив: запись сорвалась (\(error.localizedDescription)) — дальше без архива")
            archiveFile = nil
        }
    }

    /// Сначала с выбранным микрофоном (chooseDevice); сорвалось (Bluetooth запутал систему) —
    /// вторая попытка с дефолтным входом: лучше писать хоть с чего-то, чем ошибка
    private func engineUpWithFallback() throws {
        let choice = Self.chooseDevice()
        if let dev = choice.device {
            AppLog.log("recorder: микрофон — «\(dev.name)» (\(dev.transportLabel); \(choice.why))")
            Self.ensureDefaultInput(is: dev)
        }
        do { try engineUp(device: choice.device) } catch {
            AppLog.log("recorder: с «\(choice.device?.name ?? "—")» не стартовало — пробую дефолтный вход")
            do { try engineUp(device: nil) } catch {
                // залипший HAL (инцидент 04.08: при живых AirPods оба входа отдают
                // «44100 Гц/2 кан.» и -10868, ретраи не лечат) — дать системе
                // продышаться и зайти ещё раз со встроенным
                AppLog.log("recorder: оба входа сорвались — пауза 0.5 с и последняя попытка со встроенным")
                Thread.sleep(forTimeInterval: 0.5)
                let builtin = Self.inputDevices().first { $0.isBuiltIn }
                if let builtin { Self.ensureDefaultInput(is: builtin) }
                try engineUp(device: builtin)
            }
        }
    }

    /// Системный дефолт-вход → выбранное устройство (правка 04.08, обобщена 13.09): при
    /// подключённых AirPods система скармливает свежему AVAudioEngine формат ВЫХОДА наушников
    /// (44.1 кГц/стерео) вместо формата входа, старт падает -10868 и залипает даже
    /// после выключения Bluetooth. Пин внутри движка (pin) от этого не спасает — чиним сам
    /// системный дефолт. Выход (музыка в наушниках) не трогаем. Побочный плюс: воткнул Boya —
    /// и весь мак (Zoom, Телеграм) тоже пишет с него, автору не надо лезть в настройки.
    static func ensureDefaultInput(is device: InputDevice) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var current: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                      &addr, 0, nil, &size, &current) == noErr,
           current == device.id { return }
        var dev = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
        AppLog.log(status == noErr
            ? "recorder: системный вход переключён на «\(device.name)»"
            : "recorder: не смог переключить системный вход на «\(device.name)» (ошибка \(status))")
    }

    // MARK: - Выбор микрофона (правка автора 13.09.2026: «хочу видеть, что говорю с Boya»)

    /// Входное аудиоустройство: что это и как подключено
    struct InputDevice: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let transport: UInt32

        var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
        /// Zoom, AirBeamTV, составные — не микрофоны, в меню не показываем
        var isVirtual: Bool {
            transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
        }
        /// Проводной внешний микрофон (USB-ресивер Boya, петличка в USB-C, звуковая карта) —
        /// такие в авто-режиме берём вперёд встроенного. Bluetooth и «неизвестный» транспорт
        /// (микрофон iPhone по Continuity) — нет
        var isExternalWired: Bool {
            [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeAVB].contains(transport)
        }
        var transportLabel: String { AudioRecorder.transportLabel(transport) }
    }

    /// Настройка «какой микрофон»: nil — авто (внешний проводной, если подключён, иначе
    /// встроенный); "builtin" — всегда встроенный (поведение до 13.09.2026); иначе UID устройства
    static let prefKey = "inputDeviceUID"
    static let prefNameKey = "inputDeviceName"
    static let builtInPref = "builtin"
    static var preferredUID: String? {
        get {
            let v = UserDefaults.standard.string(forKey: prefKey) ?? ""
            return v.isEmpty ? nil : v
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: prefKey) }
    }
    /// Имя выбранного вручную устройства — чтобы в меню сказать «Boya не подключён», когда его нет
    static var preferredName: String? {
        get { UserDefaults.standard.string(forKey: prefNameKey) }
        set { UserDefaults.standard.set(newValue, forKey: prefNameKey) }
    }

    /// Какой микрофон возьмём на следующем старте и почему (для лога, плашки и меню)
    static func chooseDevice() -> (device: InputDevice?, why: String) {
        let all = inputDevices()
        let builtin = all.first { $0.isBuiltIn }
        switch preferredUID {
        case nil:
            if let ext = all.first(where: { $0.isExternalWired }) { return (ext, "авто: внешний подключён") }
            return (builtin, "авто: внешнего нет — встроенный")
        case builtInPref?:
            return (builtin, "настройка: всегда встроенный")
        case let uid?:
            if let d = all.first(where: { $0.uid == uid }) { return (d, "настройка: выбран вручную") }
            return (builtin, "«\(preferredName ?? "выбранный микрофон")» не подключён — встроенный")
        }
    }

    /// Все устройства с входными каналами, как их видит CoreAudio (виртуальные тоже —
    /// фильтрует вызывающий)
    static func inputDevices() -> [InputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { dev in
            guard hasInputStreams(dev) else { return nil }
            var taddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var transport: UInt32 = 0
            var tsize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(dev, &taddr, 0, nil, &tsize, &transport)
            let uid = stringProp(dev, kAudioDevicePropertyDeviceUID) ?? "id\(dev)"
            let name = stringProp(dev, kAudioDevicePropertyDeviceNameCFString) ?? "Устройство \(dev)"
            return InputDevice(id: dev, uid: uid, name: name, transport: transport)
        }
    }

    /// Дефолтный вход системы как InputDevice (когда пишем без пина — знать, с чего)
    static func defaultInputDevice() -> InputDevice? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var current: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &current) == noErr else { return nil }
        return inputDevices().first { $0.id == current }
    }

    /// Следить за списком устройств (воткнули/вынули Boya, сели AirPods): колбэк на main
    static func watchDevices(_ handler: @escaping () -> Void) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main) { _, _ in handler() }
        AppLog.log(status == noErr
            ? "recorder: слежу за списком аудиоустройств"
            : "recorder: не смог подписаться на список устройств (ошибка \(status))")
    }

    static func transportLabel(_ t: UInt32) -> String {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return "встроенный"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "виртуальный"
        case kAudioDeviceTransportTypeAggregate: return "составной"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "монитор"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeUnknown: return "iPhone/другое"
        default: return "внешний"
        }
    }

    private static func hasInputStreams(_ dev: AudioDeviceID) -> Bool {
        var saddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var ssize: UInt32 = 0
        return AudioObjectGetPropertyDataSize(dev, &saddr, 0, nil, &ssize) == noErr && ssize > 0
    }

    private static func stringProp(_ dev: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        // CoreAudio отдаёт CFString с +1 (caller owns) — берём через Unmanaged и takeRetained,
        // а не `&value` к CFString: компилятор честно предупреждает, что так указатель
        // формируется к объектной ссылке
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, UnsafeMutableRawPointer(ptr))
        }
        guard status == noErr, let s = value?.takeRetainedValue() as String? else { return nil }
        return s.isEmpty ? nil : s
    }

    func stop(completion: @escaping () -> Void) {
        tearDownEngine()
        guard recording else { DispatchQueue.main.async(execute: completion); return }
        recording = false
        closeArchive(delete: false)
        queue.async {
            if self.samples.count >= self.minChunk {
                self.emitChunk(count: self.samples.count)
            } else {
                self.samples.removeAll()
            }
            DispatchQueue.main.async(execute: completion)
        }
    }

    /// Отмена без распознавания: это был шорткат с ⌘, а не диктовка — звук выбрасываем
    func cancel() {
        tearDownEngine()
        guard recording else { return }
        recording = false
        closeArchive(delete: true)
        queue.async { self.samples.removeAll() }
    }

    // MARK: - Аудиограф

    /// Свежий движок + тап (и при старте, и при пере-подключении на лету).
    /// Формат тапа НЕ навязываем (format: nil): после смен Bluetooth-устройств
    /// inputNode отдаёт протухший кэш формата (24 кГц призрака-наушников при
    /// реальном железе 48 кГц) и старт падает «format.sampleRate == hwFormat».
    /// Конвертер в 16 кГц подстраивается под фактический поток уже в тапе.
    private func engineUp(device: InputDevice?) throws {
        removeConfigObserver()
        // КРИТИЧНО (фикс segfault 07.08): снять тап и дать аудио-потоку CoreAudio
        // остановиться ДО замены движка. Иначе при пере-подключении входа (Bluetooth,
        // -10868) старый IO-поток дёргает уже освобождённый tap-колбэк → прыжок на
        // 0x0 в HALC_ProxyIOContext::IOWorkLoop → падение всего приложения.
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        // КРИТИЧНО (фикс зависания 04.09): последняя ссылка на старый движок умирала прямо
        // здесь, на главном потоке, а -[AVAudioEngine dealloc] делает dispatch_sync на общую
        // очередь AVFAudio. Пока RatePlayer держит свой движок на озвучке (AirPods переключают
        // выход), очередь занята — главный поток встаёт НАМЕРТВО: иконка в баре крутится, меню
        // не открывается, помогает только kill. Хороним старый движок в фоновой очереди.
        // ⚠️ Фикс 24.09: `let dead` + `withExtendedLifetime` в блоке НЕ гарантировал, что
        // последняя ссылка умрёт на кладбище — пустой блок успевал отработать раньше, и
        // локальная `dead` отпускалась уже на главном (сэмпл 24.09 09:42: engineUp →
        // -[AVAudioEngine dealloc] → dispatch_sync, 60 с до перезапуска сторожем).
        // Unmanaged: +1 берём здесь, на главном управляемых ссылок не остаётся вовсе.
        let dead = Unmanaged.passRetained(engine)
        engine = AVAudioEngine()
        reaper.async { dead.release() }
        converter = nil
        let input = engine.inputNode
        if let device { pin(device, to: input) }
        activeDevice = device ?? Self.defaultInputDevice()
        let inFormat = input.outputFormat(forBus: 0)
        let who = activeDevice.map { "\($0.name) · \($0.transportLabel)" } ?? "дефолтный"
        AppLog.log("recorder: вход \(Int(inFormat.sampleRate)) Гц, \(inFormat.channelCount) кан. (\(who)\(device == nil ? ", без пина" : ""))")
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: Double(sampleRate),
                                            channels: 1, interleaved: false) else {
            throw NSError(domain: "Diktovka", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "не удалось настроить конвертер аудио"])
        }
        // NSException отсюда (рассинхрон аудио-устройств) Swift не ловит —
        // оборачиваем в ObjC-ловушку, превращаем в честную ошибку
        var startError: Error?
        let exception = DiktovkaTryBlock {
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                self?.handleTap(buffer: buffer, outFormat: outFormat)
            }
            self.engine.prepare()
            do { try self.engine.start() } catch { startError = error }
        }
        if exception != nil || startError != nil {
            input.removeTap(onBus: 0)
            engine.stop()
            let msg = exception ?? startError!.localizedDescription
            AppLog.log("recorder: старт аудио сорвался: \(msg)")
            throw NSError(domain: "Diktovka", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "аудио-система не стартовала (переключи вход и попробуй ещё)"])
        }
        lastBufferAt = Date()
        // queue: nil + прыжок на main (фикс 24.09): с queue: .main очередь движка AVFAudio
        // ждала главный поток (waitUntilFinished), пока главный ждал её — взаимная блокировка
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.configChanged() }
        }
    }

    /// Пишем с КОНКРЕТНОГО устройства, а не с дефолтного входа: дефолт скачет за
    /// Bluetooth-наушниками (нули вместо звука, фантомные форматы). Не прибилось —
    /// остаётся дефолт, об этом в логе.
    private func pin(_ device: InputDevice, to input: AVAudioInputNode) {
        guard let au = input.audioUnit else { return }
        var dev = device.id
        let status = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            AppLog.log("recorder: не смог прибить «\(device.name)» (ошибка \(status)) — пишу с дефолтного входа")
        }
    }

    private func tearDownEngine() {
        removeConfigObserver()
        restartWork?.cancel()
        restartWork = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func removeConfigObserver() {
        if let o = configObserver {
            NotificationCenter.default.removeObserver(o)
            configObserver = nil
        }
    }

    /// Вход переключился (Cursor-диалог/гарнитура): изменения прилетают пачкой —
    /// дебаунс 0.3 с, потом пробуем пере-подключиться, не роняя сессию
    private func configChanged() {
        guard recording else { return }
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reconnectIfNeeded() }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// С прибитым микрофоном система шлёт конфиг-сигналы и без реальной
    /// смены входа (Bluetooth-наушники дёргают дефолтные устройства). Ложная тревога
    /// (движок работает, буферы текут) — игнор; смену формата на лету переживает
    /// ленивый конвертер прямо в тапе, рестарт нужен только если поток встал.
    private func reconnectIfNeeded() {
        guard recording else { return }
        let flowing = Date().timeIntervalSince(lastBufferAt) < 1.0
        if engine.isRunning, flowing {
            restartCount = 0
            AppLog.log("аудио-конфиг дёрнулся, но вход жив — игнорирую")
            return
        }
        attemptRestart()
    }

    private func attemptRestart() {
        guard recording else { return }
        restartCount += 1
        guard restartCount <= 3 else {
            AppLog.log("вход скачет без остановки — завершаю сессию")
            onInterrupted?()
            return
        }
        do {
            try engineUpWithFallback()
            AppLog.log("вход пере-подключён на лету (№\(restartCount)), запись продолжается")
        } catch {
            AppLog.log("не смог пере-подключить вход: \(error.localizedDescription)")
            onInterrupted?()
        }
    }

    // MARK: - Аудио-поток

    private func handleTap(buffer: AVAudioPCMBuffer, outFormat: AVAudioFormat) {
        // конвертер под фактический формат потока; при его смене (48↔24 кГц
        // в диалоге Cursor) просто пересоздаём — сессия живёт дальше
        if converter == nil || converter!.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
            AppLog.log("recorder: поток идёт: \(Int(buffer.format.sampleRate)) Гц, \(buffer.format.channelCount) кан.")
        }
        guard let converter else { return }
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
        var gave = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if gave {
                status.pointee = .noDataNow
                return nil
            }
            gave = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let ch = out.floatChannelData else { return }
        lastBufferAt = Date()
        let n = Int(out.frameLength)
        let arr = Array(UnsafeBufferPointer(start: ch[0], count: n))

        let level = min(1, Self.rms(arr[0..<arr.count]) * 12)
        DispatchQueue.main.async { self.onLevel?(level) }

        queue.async {
            self.append(arr)
            self.archiveWrite(out)
        }
    }

    private func append(_ arr: [Float]) {
        samples.append(contentsOf: arr)
        guard samples.count >= softLimit else { return }
        if samples.count >= hardLimit {
            // не рубим слово на ровно 24 с — ищем самое тихое окно после softLimit
            AppLog.log("кусок: паузы не дождался — жёсткий рез по самому тихому окну")
            emitChunk(count: quietestCutPoint() ?? samples.count)
            return
        }
        if Self.rms(samples.suffix(cutSilence)) < silenceThreshold {
            emitChunk(count: samples.count)
        }
    }

    /// Конец самого тихого 0.3с-окна в диапазоне softLimit…конец буфера
    private func quietestCutPoint() -> Int? {
        var best: (rms: Float, end: Int)?
        var i = softLimit
        while i + silenceWindow <= samples.count {
            let r = Self.rms(samples[i..<(i + silenceWindow)])
            if best == nil || r < best!.rms { best = (r, i + silenceWindow) }
            i += silenceWindow / 2
        }
        return best?.end
    }

    private func emitChunk(count: Int) {
        var chunk = Array(samples.prefix(count))
        samples.removeFirst(count)
        guard chunk.count >= minChunk else {
            AppLog.log("кусок выброшен: короче \(minChunk) сэмплов (\(chunk.count))")
            return
        }

        // кусок сплошной тишины не шлём; критерий — САМОЕ ГРОМКОЕ 0.3с-окно
        // (средний RMS за весь кусок съедал бы короткую фразу в длинной паузе)
        var loudest: Float = 0
        var i = 0
        while i < chunk.count {
            let end = min(i + silenceWindow, chunk.count)
            loudest = max(loudest, Self.rms(chunk[i..<end]))
            i += silenceWindow
        }
        guard loudest >= dropThreshold else {
            AppLog.log(String(format: "кусок выброшен как тишина: %.1f с, пик RMS %.4f < %.4f",
                              Double(chunk.count) / Double(sampleRate), loudest, dropThreshold))
            return
        }

        // АВТОУСИЛЕНИЕ (правка 13.09.2026): автор говорит негромко с расстояния предплечья —
        // пики RMS 0.02–0.035 против 0.1–0.25 у обычной речи, и движок на тихом одиночном
        // слове гадал («раз» → «Кран»). Подтягиваем кусок к целевому уровню: не больше
        // чем в 8 раз и без клиппинга. Архив звука пишется как есть, до усиления.
        let target: Float = 0.12
        if loudest < target {
            let peak = chunk.reduce(0) { max($0, abs($1)) }
            var gain = min(target / loudest, 8)
            if peak > 0 { gain = min(gain, 0.98 / peak) }
            if gain > 1.05 {
                for i in chunk.indices { chunk[i] *= gain }
                AppLog.log(String(format: "кусок: тихо (пик RMS %.3f) — усилил в %.1f раза", loudest, gain))
            }
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("diktovka-\(UUID().uuidString).wav")
        do { try WavWriter.write(samples: chunk, sampleRate: sampleRate, to: url) } catch {
            AppLog.log("не записался wav: \(error.localizedDescription)")
            return
        }
        AppLog.log(String(format: "кусок готов: %.1f с, пик RMS %.4f → %@",
                          Double(chunk.count) / Double(sampleRate), loudest, url.lastPathComponent))
        DispatchQueue.main.async { self.onChunk?(url) }
    }

    private static func rms<C: Collection>(_ c: C) -> Float where C.Element == Float {
        guard !c.isEmpty else { return 0 }
        var acc: Float = 0
        for v in c { acc += v * v }
        return (acc / Float(c.count)).squareRoot()
    }
}
