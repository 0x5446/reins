/// Draw the wireframe that stands in for a photograph of one.
///
/// The photo screenshot needs something worth sending to an agent, and a
/// dashboard scribbled on paper is the honest example — it is the thing a
/// phone can put into a codebase that a keyboard cannot. Drawing it here
/// rather than committing a JPEG keeps the shot reproducible on any machine.
///
///   swift Tools/Sketch.swift [out.png]

import AppKit

let w = 1400.0, h = 1000.0
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()
NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()
let ink = NSColor(calibratedWhite: 0.15, alpha: 1)
ink.setStroke()

func jitter(_ p: NSPoint, _ a: Double = 3) -> NSPoint {
    NSPoint(x: p.x + Double.random(in: -a...a), y: p.y + Double.random(in: -a...a))
}
func line(_ a: NSPoint, _ b: NSPoint, _ width: Double = 3.5) {
    let p = NSBezierPath()
    p.lineWidth = width
    p.lineCapStyle = .round
    p.move(to: jitter(a))
    p.curve(to: jitter(b),
            controlPoint1: jitter(NSPoint(x: (a.x * 2 + b.x) / 3, y: (a.y * 2 + b.y) / 3), 6),
            controlPoint2: jitter(NSPoint(x: (a.x + b.x * 2) / 3, y: (a.y + b.y * 2) / 3), 6))
    p.stroke()
}
func box(_ x: Double, _ y: Double, _ bw: Double, _ bh: Double) {
    line(NSPoint(x: x, y: y), NSPoint(x: x + bw, y: y))
    line(NSPoint(x: x + bw, y: y), NSPoint(x: x + bw, y: y + bh))
    line(NSPoint(x: x + bw, y: y + bh), NSPoint(x: x, y: y + bh))
    line(NSPoint(x: x, y: y + bh), NSPoint(x: x, y: y))
}
func squiggle(_ x: Double, _ y: Double, _ len: Double) {
    line(NSPoint(x: x, y: y), NSPoint(x: x + len, y: y), 2.5)
}

// outer frame
box(70, 70, w - 140, h - 140)
// header bar
squiggle(130, h - 170, 380)
squiggle(130, h - 220, 240)
// three stat cards
for i in 0..<3 {
    let x = 130 + Double(i) * 400
    box(x, 520, 340, 200)
    squiggle(x + 30, 660, 150)
    squiggle(x + 30, 600, 220)
}
// chart area
box(130, 170, 1140, 290)
for i in 0..<9 {
    let x = 190 + Double(i) * 120
    let barHeight = Double.random(in: 60...220)
    box(x, 200, 60, barHeight)
}
// annotation arrow + caption strokes
line(NSPoint(x: 900, y: 780), NSPoint(x: 1050, y: 690))
line(NSPoint(x: 1050, y: 690), NSPoint(x: 1020, y: 700), 2.5)
line(NSPoint(x: 1050, y: 690), NSPoint(x: 1040, y: 720), 2.5)
squiggle(760, 800, 130)

img.unlockFocus()
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/reins-sketch.png"
try! png.write(to: URL(fileURLWithPath: target))
print("wrote \(target)")
