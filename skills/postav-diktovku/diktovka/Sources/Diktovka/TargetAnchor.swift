import AppKit
import ApplicationServices

/// ЯКОРЬ ПОЛЯ — текст уходит туда, где диктовка началась (заказ автора 18.09.2026).
///
/// Дословно: «я вот кликнул в поле, где курсор мигает, и зажал диктовку. Эта диктовка
/// в это же поле и уйдёт? Даже если я курсором куда-то ещё в другое место кликнул.
/// Это мне бы очень помогало». (Курсор у автора всегда означает мышь.)
///
/// **Зачем.** Он диктует и в это же время листает другое окно — смотрит то, о чём говорит.
/// Вставка идёт печатью символов в то приложение, которое активно В МОМЕНТ ВСТАВКИ, поэтому
/// текст улетал в чужое окно: в лучшем случае в никуда, в худшем — в чужое поле ввода.
///
/// **Как.** При старте записи запоминаем два якоря: приложение (по pid) и сам элемент
/// ввода через Accessibility. Перед вставкой, если фокус уехал, возвращаем приложение
/// вперёд и просим элемент снова стать focused — тогда каретка встаёт ровно туда, где была.
/// Элемент важен отдельно от приложения: в одном окне может быть несколько полей, и без
/// него текст ушёл бы в то поле, куда автор кликнул мышью последним.
final class TargetAnchor {

    private var app: NSRunningApplication?
    private var element: AXUIElement?
    private(set) var podpis = ""     // человекочитаемо, для лога

    /// Запомнить, где мы начинали. Зовётся на старте записи.
    func capture() {
        app = NSWorkspace.shared.frontmostApplication
        element = nil
        podpis = app?.localizedName ?? "—"
        guard let pid = app?.processIdentifier else { return }
        let axApp = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() {
            element = (f as! AXUIElement)
        }
        AppLog.log("якорь: диктовка началась в «\(podpis)»" + (element == nil ? " (поле не определилось)" : ""))
    }

    func forget() {
        app = nil
        element = nil
        podpis = ""
    }

    /// Фокус уехал в другое приложение?
    var needsRestore: Bool {
        guard let app else { return false }
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        return front.processIdentifier != app.processIdentifier
    }

    /// Вернуть фокус туда, где начинали, и позвать completion (всегда на main).
    /// Не получилось — зовём всё равно: текст важнее, пусть уйдёт хоть куда-то,
    /// чем не уйдёт вовсе и потеряется.
    func restore(completion: @escaping () -> Void) {
        guard let app else { completion(); return }
        if !needsRestore {
            focusElement()
            completion()
            return
        }
        AppLog.log("якорь: фокус ушёл — возвращаю в «\(podpis)»")
        app.activate(options: [.activateIgnoringOtherApps])
        // окну нужно время подняться; двух тактов хватает, а ждать дольше значит
        // держать текст в воздухе — он и так уже распознан
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            self?.focusElement()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { completion() }
        }
    }

    private func focusElement() {
        guard let element else { return }
        let r = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if r != .success { AppLog.log("якорь: поле не вернулось в фокус (код \(r.rawValue)) — печатаю как есть") }
    }
}
