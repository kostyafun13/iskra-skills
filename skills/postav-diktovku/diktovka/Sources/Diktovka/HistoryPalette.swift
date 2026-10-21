import AppKit

/// БУФЕР ДИКТОВОК — панель последних наговорённых кусков (просьба автора 18.09.2026).
///
/// Дословно: «когда я зажимаю Option… я хочу, чтобы ты показывал последние четыре — как
/// в буфере обмена, знаешь, когда скачивается на Mac. Я нажимаю на Option, и он
/// перещёлкивается на второй, третий, четвёртый, дальше опять первый… И я также могу
/// курсором навести и, например, Shift зажать и выбрать первый и третий вставить. Или
/// наоборот — третий и первый. В порядке, в котором я это делаю».
///
/// **Две границы на одной клавише.** Короткий правый ⌥ (0.2 с) вставляет последнюю
/// диктовку — как было всегда. Удержание ⌥ (0.45 с) открывает эту панель. Так старая
/// привычка не ломается: «зажал чуть-чуть — вставился, как раньше».
///
/// **Панель не забирает фокус.** `.nonactivatingPanel` + `orderFrontRegardless()`: курсор
/// остаётся в чужом поле ввода, куда мы и вставляем. Обычное окно украло бы фокус, и
/// вставка ушла бы в никуда — ради этого панель и borderless, и не key.
///
/// **Порядок выбора — это данные, а не подсветка.** При Shift-кликах копим индексы в том
/// порядке, в котором автор щёлкал: выбрал третий, потом первый — вставится третий, потом
/// первый. Поэтому набор хранится массивом, а не множеством.
final class HistoryPalette {

    private var panel: NSPanel?
    private var entries: [String] = []
    private var selected = 0            // подсвеченный (перещёлкивается ⌥)
    private var picked: [Int] = []      // Shift-набор В ПОРЯДКЕ кликов
    private var rows: [RowView] = []
    private var flagsMonitor: Any?
    private var clickMonitor: Any?
    private var autoClose: DispatchWorkItem?

    /// Куда отдать выбранное. Склейка пробелом — как в старом реплее ⌥.
    var onPick: ((String) -> Void)?

    var isOpen: Bool { panel != nil }

    private let maxItems = 4
    private let rowWidth: CGFloat = 520
    private let rowHeight: CGFloat = 62
    private let padding: CGFloat = 10
    private let idleClose: TimeInterval = 15

    // MARK: - Открыть / закрыть

    func open(with texts: [String]) {
        close(insert: false)
        entries = Array(texts.prefix(maxItems))
        guard !entries.isEmpty else { return }
        selected = 0
        picked = []

        let h = CGFloat(entries.count) * rowHeight + padding * 2 + 22
        let rect = NSRect(x: 0, y: 0, width: rowWidth + padding * 2, height: h)
        let p = NSPanel(contentRect: rect,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView(frame: rect)
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: "⌥ — следующая · ⌥ подольше — вставить · ⇧+клик — набрать несколько")
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: padding, y: 6, width: rowWidth, height: 14)
        blur.addSubview(hint)

        rows = []
        for (i, text) in entries.enumerated() {
            // сверху — самая свежая: у верхнего ряда наибольший y
            let y = h - padding - CGFloat(i + 1) * rowHeight
            let row = RowView(frame: NSRect(x: padding, y: y, width: rowWidth, height: rowHeight - 4),
                              number: i + 1, text: text)
            row.onClick = { [weak self] shift in self?.handleClick(index: i, shift: shift) }
            blur.addSubview(row)
            rows.append(row)
        }
        p.contentView = blur
        p.setFrameTopLeftPoint(originPoint(height: h))
        p.orderFrontRegardless()
        panel = p
        refresh()
        watchModifiers()
        armAutoClose()
        AppLog.log("буфер диктовок: открыт, \(entries.count) шт.")
    }

    /// Панель у курсора, но целиком на экране — иначе на втором мониторе уезжает за край.
    private func originPoint(height: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let vis = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = rowWidth + padding * 2
        var x = mouse.x + 12
        var y = mouse.y - 12
        if x + w > vis.maxX { x = vis.maxX - w - 8 }
        if x < vis.minX { x = vis.minX + 8 }
        if y - height < vis.minY { y = vis.minY + height + 8 }
        if y > vis.maxY { y = vis.maxY - 8 }
        return NSPoint(x: x, y: y)
    }

    func close(insert: Bool) {
        autoClose?.cancel(); autoClose = nil
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        let toInsert = insert ? assembled() : nil
        panel?.orderOut(nil)
        panel = nil
        rows = []
        if let t = toInsert, !t.isEmpty {
            AppLog.log("буфер диктовок: вставляю \(picked.isEmpty ? "выбранную №\(selected + 1)" : "набор \(picked.map { $0 + 1 })")")
            onPick?(t)
        }
        entries = []; picked = []; selected = 0
    }

    /// Текст к вставке: набор в порядке кликов, иначе — подсвеченная.
    private func assembled() -> String {
        let idx = picked.isEmpty ? [selected] : picked
        return idx.compactMap { $0 < entries.count ? entries[$0] : nil }
                  .joined(separator: " ")
    }

    // MARK: - Жесты

    /// Короткий ⌥ при открытой панели: следующая по кругу (четвёртая → снова первая).
    func cycle() {
        guard isOpen, !entries.isEmpty else { return }
        selected = (selected + 1) % entries.count
        refresh()
        armAutoClose()
    }

    /// Удержание ⌥ при открытой панели: вставить и закрыть.
    func commit() { close(insert: true) }

    private func handleClick(index: Int, shift: Bool) {
        guard index < entries.count else { return }
        if shift {
            if let at = picked.firstIndex(of: index) { picked.remove(at: at) } else { picked.append(index) }
            selected = index
            refresh()
            armAutoClose()
        } else {
            selected = index
            picked = []
            close(insert: true)
        }
    }

    /// Пока Shift зажат — копим; отпустил Shift с непустым набором — вставляем.
    /// Так «выбрал третью и первую» заканчивается само, без отдельной клавиши «ок».
    private func watchModifiers() {
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] ev in
            guard let self, self.isOpen else { return }
            if !ev.modifierFlags.contains(.shift), !self.picked.isEmpty {
                self.close(insert: true)
            }
        }
        // клик мимо панели — закрыть без вставки
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isOpen else { return }
            self.close(insert: false)
        }
    }

    private func armAutoClose() {
        autoClose?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.close(insert: false) }
        autoClose = w
        DispatchQueue.main.asyncAfter(deadline: .now() + idleClose, execute: w)
    }

    private func refresh() {
        for (i, row) in rows.enumerated() {
            row.setState(highlighted: i == selected, order: picked.firstIndex(of: i).map { $0 + 1 })
        }
    }

    // MARK: - Ряд

    private final class RowView: NSView {
        var onClick: ((Bool) -> Void)?
        private let numLabel = NSTextField(labelWithString: "")
        private let textLabel = NSTextField(labelWithString: "")
        private let orderLabel = NSTextField(labelWithString: "")

        init(frame: NSRect, number: Int, text: String) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 8

            numLabel.stringValue = "\(number)"
            numLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            numLabel.textColor = .secondaryLabelColor
            numLabel.frame = NSRect(x: 10, y: frame.height / 2 - 9, width: 18, height: 18)
            addSubview(numLabel)

            // одна строка без переносов: панель — навигация, а не чтение
            let odna = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            textLabel.stringValue = odna.count > 150 ? String(odna.prefix(150)) + "…" : odna
            textLabel.font = .systemFont(ofSize: 12)
            textLabel.textColor = .labelColor
            textLabel.lineBreakMode = .byTruncatingTail
            textLabel.maximumNumberOfLines = 2
            textLabel.frame = NSRect(x: 34, y: 6, width: frame.width - 74, height: frame.height - 12)
            addSubview(textLabel)

            orderLabel.font = .systemFont(ofSize: 11, weight: .bold)
            orderLabel.alignment = .center
            orderLabel.frame = NSRect(x: frame.width - 32, y: frame.height / 2 - 9, width: 22, height: 18)
            orderLabel.wantsLayer = true
            orderLabel.layer?.cornerRadius = 9
            orderLabel.isHidden = true
            addSubview(orderLabel)
        }

        required init?(coder: NSCoder) { nil }

        func setState(highlighted: Bool, order: Int?) {
            layer?.backgroundColor = highlighted
                ? NSColor.controlAccentColor.withAlphaComponent(0.28).cgColor
                : NSColor.clear.cgColor
            if let order {
                orderLabel.isHidden = false
                orderLabel.stringValue = "\(order)"
                orderLabel.textColor = .white
                orderLabel.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            } else {
                orderLabel.isHidden = true
            }
        }

        override func mouseDown(with event: NSEvent) {
            onClick?(event.modifierFlags.contains(.shift))
        }
    }
}
