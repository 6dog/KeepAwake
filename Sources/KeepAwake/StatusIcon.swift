import AppKit

enum StatusIcon {
    static func make(
        percent: Int?,
        keepsDisplayAwake: Bool,
        preventsSystemSleep: Bool
    ) -> NSImage {
        let size = NSSize(width: 30, height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            let primary = NSColor.black
            let activeScreenColor = NSColor.black
            let inactive = primary.withAlphaComponent(0.62)
            let screenRect = NSRect(x: 2.0, y: 5.0, width: 26.0, height: 13.0)
            let standRect = NSRect(x: 13.3, y: 2.5, width: 3.4, height: 2.8)
            let baseRect = NSRect(x: 9.2, y: 1.0, width: 11.6, height: 1.8)
            let strokeColor = keepsDisplayAwake ? activeScreenColor : inactive
            let baseColor = primary.withAlphaComponent(preventsSystemSleep ? 1.0 : 0.38)

            if keepsDisplayAwake {
                activeScreenColor.setFill()
                NSBezierPath(roundedRect: screenRect.insetBy(dx: 1.0, dy: 1.0), xRadius: 2.0, yRadius: 2.0).fill()
            }

            strokeColor.setStroke()
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2.7, yRadius: 2.7)
            screenPath.lineWidth = keepsDisplayAwake ? 1.65 : 1.25
            screenPath.stroke()

            baseColor.setFill()
            NSBezierPath(roundedRect: standRect, xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: baseRect, xRadius: 0.9, yRadius: 0.9).fill()

            if preventsSystemSleep {
                let indicatorRect = NSRect(x: 3.7, y: 2.0, width: 3.8, height: 2.0)
                NSBezierPath(roundedRect: indicatorRect, xRadius: 1.0, yRadius: 1.0).fill()
            }

            let percentText = percent.map { "\($0)" } ?? "?"
            let fontSize: CGFloat = percentText.count >= 3 ? 6.1 : 7.2
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: primary
            ]
            let textSize = percentText.size(withAttributes: attributes)
            let textRect = NSRect(
                x: screenRect.midX - textSize.width / 2.0,
                y: screenRect.midY - textSize.height / 2.0 - 0.2,
                width: textSize.width,
                height: textSize.height
            )

            if keepsDisplayAwake, let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .destinationOut
                percentText.draw(in: textRect, withAttributes: attributes)
                context.restoreGraphicsState()
            } else {
                percentText.draw(in: textRect, withAttributes: attributes)
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}
