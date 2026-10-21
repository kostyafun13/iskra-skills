import AppKit
import SwiftUI

/// Плавающий виджет: эквалайзер при записи, спиннер при распознавании, плашка при ошибке.
final class HUDController {
    enum Mode {
        case recording
        case processing
        case error(String)
    }

    private var panel: NSPanel?
    private let model = HUDModel()
    private var errorToken = 0
    private var recordingActive = false   // идёт запись: плашки-уведомления её не гасят
    private var processingActive = false  // хвост ещё распознаётся: плашки его тоже не гасят

    func showRecording(latched: Bool = false) {
        errorToken += 1
        model.mode = .recording
        model.latched = latched
        model.level = 0
        recordingActive = true
        show()
    }

    func showProcessing() {
        errorToken += 1
        recordingActive = false
        processingActive = true
        model.latched = false
        model.mode = .processing
        show()
    }

    /// Сессия кончилась (правка 13.09.2026): плашка записи больше не «возвращается»
    /// после уведомления. Раньше «Не расслышал» / «Часть не распозналась» ПОСЛЕ конца
    /// сессии отживали своё и по recordingActive возвращали ЭКВАЛАЙЗЕР — он висел без
    /// замка, пока автор не скажет «раз» новой сессией (08:32:45 в логе: «сессия пуста» →
    /// «Не расслышал» → эквалайзер завис)
    func endRecording() {
        recordingActive = false
        model.latched = false
        if case .recording = model.mode { hide() }
    }

    /// Хвост распознан и вставлен целиком — спиннеру больше не к чему возвращаться.
    /// Зовётся ДО финальной плашки («Не расслышал», «Часть не распозналась»), иначе
    /// та по истечении вернёт «Распознаю…», и он повиснет без работы
    func endProcessing() {
        processingActive = false
        if case .processing = model.mode { hide() }
    }

    /// Плашка поверх записи (прогрелся голос, Bluetooth, подсказки) больше НЕ убивает
    /// эквалайзер: пожила отведённое — и вернулись в запись (правка автора 03.09.2026,
    /// «уведомления сбивают диктовку»). Запись при этом не прерывалась никогда — гасла
    /// только индикация, и выглядело как обрыв.
    func showError(_ text: String, autoHide: TimeInterval = 2.5) {
        errorToken += 1
        let token = errorToken
        let wasLatched = model.latched
        model.mode = .error(text)
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHide) { [weak self] in
            guard let self, self.errorToken == token else { return }
            guard case .error = self.model.mode else { return }
            if self.recordingActive {
                self.model.mode = .recording
                self.model.latched = wasLatched
                self.show()
            } else if self.processingActive {
                // ХВОСТ ЕЩЁ РАСПОЗНАЁТСЯ (баг 25.09.2026): плашка «↩︎ вернул в Cursor»
                // перекрывала «Распознаю…» и через 1,6 с гасила окошко целиком, а хвост
                // допечатывался ещё 12 с. Автор видел пустой экран, считал, что всё
                // вставилось, и жал ⌥ «докинуть остаток». Теперь — назад к спиннеру
                self.model.mode = .processing
                self.show()
            } else {
                self.hide()
            }
        }
    }

    /// Короткая пометка о том, что приложение сделало САМО (заказ автора 19.09.2026:
    /// «я не знал, что фича есть»). Невидимая работа для него не существует — якорь
    /// вернул фокус три раза и ни разу об этом не сказал, поэтому он просил сделать
    /// то, что уже работало. Рисуется тем же способом, что и уведомление об ошибке.
    func showNote(_ text: String, autoHide: TimeInterval = 1.6) {
        showError(text, autoHide: autoHide)
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    /// Подпись «🎙 с какого микрофона пишем» под эквалайзером (правка автора 13.09.2026:
    /// «хочу видеть, что разговариваю с Boya»). nil — не показывать (тумблер в меню).
    /// Ставится ДО showRecording, чтобы полосы с первого кадра стояли на своём месте
    func setDevice(_ label: String?) {
        model.deviceLabel = label
    }

    func hide() {
        recordingActive = false
        processingActive = false
        model.latched = false
        panel?.orderOut(nil)
    }

    // MARK: - Панель

    private func show() {
        if panel == nil { panel = makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: HUDView(model: model))
        return p
    }

    private func position() {
        guard let p = panel else { return }
        // приложение фоновое (key window не наше) — берём экран, где курсор мыши
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let f = screen?.visibleFrame else { return }
        p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.minY + 120))
    }
}

final class HUDModel: ObservableObject {
    @Published var mode: HUDController.Mode = .recording
    @Published var level: Float = 0
    @Published var latched = false   // запись держится без пальца
    @Published var deviceLabel: String?   // с какого микрофона пишем (nil — не показывать)
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        ZStack {
            BlurBackground()
            content
                .padding(.horizontal, 16)
        }
        .frame(width: 320, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var content: some View {
        switch model.mode {
        case .recording:
            // замок — НАКЛАДКОЙ справа (правка автора 04.09.2026): в общей строке он
            // подвинул бы эквалайзер, и запись «дёргалась» на глаз в момент фиксации.
            // Полосы остаются ровно там же, замок просто появляется рядом
            // подпись микрофона — ПОД полосами, задаётся до показа плашки: за сессию
            // геометрия не меняется, полосы не «дёргаются» (то же правило, что и с замком)
            VStack(spacing: 2) {
                HStack(spacing: 12) {
                    BlinkingDot()
                    EqualizerBars(level: model.level)
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    if model.latched {
                        VStack(spacing: 1) {
                            Text("🔒").font(.system(size: 13))
                            Text("⌘ стоп")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let d = model.deviceLabel {
                    Text("🎙 \(d)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        case .processing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Распознаю…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
            }
        case .error(let text):
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
    }
}

struct EqualizerBars: View {
    var level: Float
    private let mults: [CGFloat] = [0.35, 0.6, 0.85, 1.0, 0.7, 0.9, 0.55, 1.0, 0.8, 0.65, 0.45, 0.3]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<12, id: \.self) { i in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 6 + CGFloat(min(max(level, 0), 1)) * 36 * mults[i])
            }
        }
        .frame(height: 44, alignment: .center)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

struct BlinkingDot: View {
    @State private var on = true

    var body: some View {
        Circle()
            .fill(Color.red)
            .frame(width: 8, height: 8)
            .opacity(on ? 1 : 0.25)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on.toggle()
                }
            }
    }
}

struct BlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.state = .active
        v.blendingMode = .behindWindow
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
