import AppKit
import IOKit.pwr_mgt

/// Две системные заявки вместо таймеров или имитации клавиш.
final class KeepAwake {
    private var assertions: [IOPMAssertionID] = []
    var isEnabled: Bool { !assertions.isEmpty }

    @discardableResult
    func enable() -> Bool {
        guard !isEnabled else { return true }
        for type in [kIOPMAssertionTypePreventUserIdleSystemSleep,
                     kIOPMAssertionTypePreventUserIdleDisplaySleep] {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Диктовка: не давать компьютеру уснуть" as CFString, &id)
            guard result == kIOReturnSuccess else {
                disable()
                AppLog.log("не удалось запретить сон: \(result)")
                return false
            }
            assertions.append(id)
        }
        return true
    }

    func disable() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }

    deinit { disable() }
}

/// Отдельный слой: tint микрофона и template-режим не меняют цвет точки.
final class KeepAwakeDot: NSView {
    func attach(to button: NSStatusBarButton) {
        // У NSStatusBarButton обычно flipped-координаты: y=0 находится СВЕРХУ.
        frame = NSRect(x: button.bounds.maxX - 9,
                       y: button.isFlipped ? button.bounds.minY + 1 : button.bounds.maxY - 9,
                       width: 8, height: 8)
        autoresizingMask = [.minXMargin, button.isFlipped ? .maxYMargin : .minYMargin]
        button.addSubview(self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSColor.labelColor.withAlphaComponent(0.7).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        NSColor.systemGreen.setFill()
        circle.fill()
    }
}

/// Настоящий системный переключатель, а не галочка обычного пункта меню.
final class KeepAwakeMenuRow: NSView {
    let toggle = NSSwitch()
    var onToggle: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 34))
        let label = NSTextField(labelWithString: "Не давать компьютеру уснуть")
        label.font = NSFont.menuFont(ofSize: 0)
        label.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.target = self
        toggle.action = #selector(changed)
        toggle.setAccessibilityLabel("Не давать компьютеру уснуть")
        addSubview(label)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func changed() { onToggle?() }
    override func mouseUp(with event: NSEvent) { toggle.performClick(nil) }
}
