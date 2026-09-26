import AppKit
let root = CommandLine.arguments[1]
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(red: 0.11, green: 0.31, blue: 0.28, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 30, y: 30, width: 964, height: 964), xRadius: 210, yRadius: 210).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 610, weight: .medium), .foregroundColor: NSColor(red: 0.96, green: 0.95, blue: 0.89, alpha: 1)]
        ("e" as NSString).draw(at: NSPoint(x: 225, y: 145), withAttributes: attrs)
        NSColor(red: 0.76, green: 0.85, blue: 0.63, alpha: 1).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 47
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 608, y: 313)); path.line(to: NSPoint(x: 691, y: 235)); path.line(to: NSPoint(x: 837, y: 408)); path.stroke()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(root)/icon_\(size)x\(size)\(suffix).png"))
    }
}
