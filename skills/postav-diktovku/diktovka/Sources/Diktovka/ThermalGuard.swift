import Foundation

/// Термозащита: на .serious (≈2/3 нагрева, «вентиляторы на максимуме») и .critical
/// распознавание блокируется. Уведомление системы приходит на глобальной очереди —
/// подписка через OperationQueue.main отдаёт колбэк уже на главной.
final class ThermalGuard {
    var onChange: ((ProcessInfo.ThermalState) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.onChange?(ProcessInfo.processInfo.thermalState)
        }
    }

    var state: ProcessInfo.ThermalState { ProcessInfo.processInfo.thermalState }

    var isTooHot: Bool {
        let s = state
        return s == .serious || s == .critical
    }

    static func label(for s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "норма ❄️"
        case .fair: return "тёплый, работаем"
        case .serious: return "ГОРЯЧИЙ 🥵 — распознавание отключено"
        case .critical: return "ПЕРЕГРЕВ ⛔️ — распознавание отключено"
        @unknown default: return "неизвестно"
        }
    }
}
