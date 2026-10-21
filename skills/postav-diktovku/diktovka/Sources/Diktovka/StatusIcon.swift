import AppKit

/// Иконка строки меню: SF Symbol (или микрофон с галочкой красивого голоса) + бейдж-буква в углу.
///
/// Бейдж «Б» (правка автора 13.09.2026): горит, пока звук идёт с ВНЕШНЕГО микрофона (Boya),
/// независимо от диктовки — «я же ещё в Zoom записываю… чтобы маленькая буква Б горела».
/// Всё рисуется в template-режиме (иконка = альфа-маска): под бейдж делается вырез
/// destinationOut, как у галочки, а сама буква — «дырка» в залитом кружке, чтобы читалась
/// и в тёмной, и в светлой теме и оставалась заметной при красном tint записи.
enum StatusIcon {
    static let side: CGFloat = 18

    enum Corner { case bottomLeft, topRight }

    /// symbol — имя SF Symbol; checkmark — галочка красивого голоса (правый нижний угол);
    /// badge — буква в углу (nil — без бейджа); template — false, когда иконку красят tint'ом
    static func make(symbol: String, checkmark: Bool = false, badge: String? = nil,
                     badgeCorner: Corner = .bottomLeft, template: Bool = true) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "Диктовка") else { return nil }
        if !checkmark, badge == nil {
            // чистый символ — как рисовалось до бейджей, размер и вес не трогаем
            base.isTemplate = template
            return base
        }
        let check = checkmark
            ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) : nil
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            drawFit(base, in: check != nil
                    ? NSRect(x: 0, y: 2, width: 14, height: 16)
                    : NSRect(x: 1, y: 1, width: 16, height: 16))
            if let check {
                let r = NSRect(x: 8.5, y: 0, width: 9.5, height: 9.5)
                cutOut(NSBezierPath(ovalIn: r.insetBy(dx: -1.2, dy: -1.2)))
                drawFit(check, in: r)
            }
            if let badge {
                let d: CGFloat = 9
                let r: NSRect
                switch badgeCorner {
                case .bottomLeft: r = NSRect(x: 0, y: 0, width: d, height: d)
                case .topRight:   r = NSRect(x: side - d, y: side - d, width: d, height: d)
                }
                cutOut(NSBezierPath(ovalIn: r.insetBy(dx: -1.0, dy: -1.0)))
                NSColor.black.setFill()
                NSBezierPath(ovalIn: r).fill()
                let str = NSAttributedString(string: badge, attributes: [
                    .font: NSFont.systemFont(ofSize: 7, weight: .black),
                    .foregroundColor: NSColor.black,
                ])
                let sz = str.size()
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                str.draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2 + 0.3))
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            }
            return true
        }
        img.isTemplate = template
        return img
    }

    private static func drawFit(_ image: NSImage, in target: NSRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let k = min(target.width / s.width, target.height / s.height)
        let r = NSRect(x: target.midX - s.width * k / 2, y: target.midY - s.height * k / 2,
                       width: s.width * k, height: s.height * k)
        image.draw(in: r)
    }

    /// Вырез в альфа-маске (в template-режиме иконка = маска)
    private static func cutOut(_ path: NSBezierPath) {
        NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
    }

    /// Диагностика: отрисовать иконку в PNG крупно (scale×), чтобы посмотреть бейдж глазами
    @discardableResult
    static func writePNG(_ image: NSImage, to url: URL, scale: CGFloat = 8) -> Bool {
        let px = Int(side * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: px, height: px).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}
