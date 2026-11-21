import AppKit

/// The menu bar mark: three small jacks. When something waits, a filled dot and the count in wide figures follow.
/// Drawn, so it is crisp at 1x and 2x. `pop` (0...1) scales the dot for the pop-in.
enum StatusImage {
    static func make(waiting: Int, pop: CGFloat = 1) -> NSImage {
        let text = waiting > 0 ? String(waiting) : ""
        let label = NSAttributedString(string: text, attributes: [.font: wideFont(size: 10.5), .foregroundColor: NSColor.black])
        let textSize = label.size()
        let jacks: CGFloat = 3 * 6 + 2 * 2 + 4
        let extra: CGFloat = waiting > 0 ? 4 + 6 + 3 + ceil(textSize.width) : 0
        let image = NSImage(size: NSSize(width: jacks + extra + 2, height: 16), flipped: false) { rect in
            NSColor.black.setStroke()
            for i in 0..<3 {
                let r = NSRect(x: 2 + CGFloat(i) * 8 + 0.6, y: rect.midY - 3 + 0.6, width: 4.8, height: 4.8)
                let p = NSBezierPath(ovalIn: r); p.lineWidth = 1.2; p.stroke()
            }
            if waiting > 0 {
                let d: CGFloat = 6 * pop, cx = jacks + 4 + 3
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - d / 2, y: rect.midY - d / 2, width: d, height: d)).fill()
                label.draw(at: NSPoint(x: cx + 6, y: (rect.height - textSize.height) / 2 + 0.5))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    static func wideFont(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        let desc = base.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.width: 0.4, NSFontDescriptor.TraitKey.weight: NSFont.Weight.semibold.rawValue]])
        return NSFont(descriptor: desc, size: size) ?? base
    }
}
