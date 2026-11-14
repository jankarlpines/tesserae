// Draws Tesserae's app icon (1024pt) and writes icon.png. Run: swift make_icon.swift
// Black and white: a black tile with a thin white frame split into five areas (a tiny box map).
import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // top-left origin (gradients flip: 90° = lighter at top)

func w(_ v: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(white: v, alpha: a) }

// macOS icon body: 824pt rounded square centred on the canvas, with a soft shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = w(0, 0.5); sh.shadowBlurRadius = 28; sh.shadowOffset = NSSize(width: 0, height: -12)
sh.set()
w(0.05).setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: w(0.13), ending: w(0.03))!.draw(in: shape, angle: 90)

// One rounded frame with the same shape as the icon (scaled down), split into five areas
// by divider lines along the gaps. Each line is drawn once.
let frame = body.insetBy(dx: 120, dy: 120)
let radius = 185 * frame.width / body.width
let line: CGFloat = 12

// Dividers on a 0..1 grid inside the frame: (x1, y1, x2, y2).
let dividers: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (0.00, 0.62, 1.00, 0.62),   // across the middle
    (0.60, 0.00, 0.60, 0.62),   // splits the top: big box | right column
    (0.60, 0.38, 1.00, 0.38),   // splits the right column
    (0.38, 0.62, 0.38, 1.00),   // splits the bottom row
]
func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height) }

// All the lines as one filled shape, so a single metal gradient runs across them.
let lines = CGMutablePath()
lines.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    .copy(strokingWithWidth: line, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
for (x1, y1, x2, y2) in dividers {
    let seg = CGMutablePath(); seg.move(to: pt(x1, y1)); seg.addLine(to: pt(x2, y2))
    lines.addPath(seg.copy(strokingWithWidth: line, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
}

// Soft shadow under the lines so they sit slightly raised.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 5), blur: 8, color: w(0, 0.8).cgColor)
ctx.addPath(lines); ctx.setFillColor(w(0.5).cgColor); ctx.fillPath()
ctx.restoreGState()

// Flat light gray, a little darker than white.
ctx.addPath(lines); ctx.setFillColor(w(0.78).cgColor); ctx.fillPath()

// Thin rim on the icon body.
w(1, 0.12).setStroke(); shape.lineWidth = 3; shape.stroke()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon.png"))
print("wrote icon.png")
