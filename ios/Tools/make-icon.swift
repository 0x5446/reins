// Renders the app icon.
//
// Generated rather than drawn in a design tool so it is reviewable, diffable,
// and reproducible: the geometry below is the source, and the PNG is output.
//
//   swift ios/Tools/make-icon.swift ios/Rowel/Assets.xcassets/AppIcon.appiconset/icon-1024.png
//
// The mark is a tether: a filled dot (the phone in your hand), a ring (the
// machine doing the work), and one taut rein between them. Two objects and a
// line survive being 40 points tall, which is the size this is actually seen at
// — anything with more parts turns to mush on a home screen.
//
// Everything is expressed as a fraction of the canvas so the proportions hold if
// the size ever changes, and drawn on an opaque square: iOS applies its own
// corner mask, and a source image that rounds its own corners gets clipped twice.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024.0
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "icon-1024.png")

guard let context = CGContext(
    data: nil,
    width: Int(side),
    height: Int(side),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create the drawing context\n".utf8))
    exit(1)
}

context.setAllowsAntialiasing(true)
context.interpolationQuality = .high

// MARK: - Ground

// A diagonal gradient rather than a flat fill. Flat reads as a placeholder next
// to the icons it sits beside; a gradient this shallow is not decoration, it is
// what makes the tile look intentional at a glance.
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ground = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(srgbRed: 0.259, green: 0.451, blue: 1.0, alpha: 1),
        CGColor(srgbRed: 0.078, green: 0.184, blue: 0.706, alpha: 1),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    ground,
    start: CGPoint(x: side * 0.12, y: side),
    end: CGPoint(x: side * 0.88, y: 0),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

// A faint highlight where the light would fall, so the tile has a top and a
// bottom. Without it the gradient alone can look like a flat swatch.
let sheen = CGGradient(
    colorsSpace: space,
    colors: [
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16),
        CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0),
    ] as CFArray,
    locations: [0, 1]
)!
context.drawRadialGradient(
    sheen,
    startCenter: CGPoint(x: side * 0.28, y: side * 0.86), startRadius: 0,
    endCenter: CGPoint(x: side * 0.28, y: side * 0.86), endRadius: side * 0.62,
    options: []
)

// MARK: - Mark

// CoreGraphics puts the origin at the bottom left. Fractions read from the top
// the way the eye does, so this flips once and everything below is top-down.
func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: side * x, y: side * (1 - y)) }
func length(_ f: Double) -> Double { side * f }

let stroke = length(0.082)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

// The mark carries a shadow so it stays separate from the ground on a light
// wallpaper. Kept tight and low-opacity: a soft glow would read as blur.
context.setShadow(
    offset: CGSize(width: 0, height: -length(0.010)),
    blur: length(0.028),
    color: CGColor(srgbRed: 0.02, green: 0.06, blue: 0.28, alpha: 0.26)
)
context.setFillColor(white)

/// A cubic bezier evaluated at `t`.
func curve(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: Double) -> CGPoint {
    let u = 1 - t
    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
    return CGPoint(
        x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
        y: a * p0.y + b * p1.y + c * p2.y + d * p3.y
    )
}

/// Fill a stroke that narrows along its length.
///
/// Rowel are leather and taper; a constant-width stroke reads as a post, which
/// is what turned the first attempt at this mark into a piece of furniture. The
/// taper is also the perspective: wide is the end in your hand, narrow is the
/// end that has gone off into the distance.
///
/// Built by walking the centreline and offsetting along the normal, rather than
/// by stroking, because CoreGraphics has no variable-width pen.
func taperedRein(from p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, to p3: CGPoint, wide: Double, narrow: Double, capStart: Bool = true) {
    let steps = 96
    var left: [CGPoint] = []
    var right: [CGPoint] = []
    for index in 0...steps {
        let t = Double(index) / Double(steps)
        let here = curve(p0, p1, p2, p3, t)
        let ahead = curve(p0, p1, p2, p3, min(1, t + 0.001))
        let behind = curve(p0, p1, p2, p3, max(0, t - 0.001))
        let dx = ahead.x - behind.x, dy = ahead.y - behind.y
        let norm = max(0.0001, (dx * dx + dy * dy).squareRoot())
        // Ease the taper so the wide end stays wide for a moment before it
        // starts narrowing. A linear taper looks like a triangle.
        let half = (wide + (narrow - wide) * (t * t * (3 - 2 * t))) / 2
        let ox = -dy / norm * half, oy = dx / norm * half
        left.append(CGPoint(x: here.x + ox, y: here.y + oy))
        right.append(CGPoint(x: here.x - ox, y: here.y - oy))
    }
    // One continuous outline: up the left edge, back down the right. Two calls
    // to `addLines(between:)` would start two subpaths and fill two slivers with
    // a hole between them, which is exactly what a ribbon must not be.
    let path = CGMutablePath()
    path.move(to: left[0])
    for p in left.dropFirst() { path.addLine(to: p) }
    for p in right.reversed() { path.addLine(to: p) }
    path.closeSubpath()
    context.addPath(path)
    context.fillPath()
    // Round the ends. Without these a blunt cut on a curve reads as clipped
    // rather than finished. The wide end skips its cap when it starts inside
    // another shape, where a disc that size surfaces as a lump.
    if capStart {
        context.fillEllipse(in: CGRect(x: p0.x - wide / 2, y: p0.y - wide / 2, width: wide, height: wide))
    }
    context.fillEllipse(in: CGRect(x: p3.x - narrow / 2, y: p3.y - narrow / 2, width: narrow, height: narrow))
}

// An R whose leg keeps going.
//
// Four literal attempts came before this and every one read as something else at
// icon size: a ring on a handle is a magnifying glass, two posts under a bar is a
// stool, two thin tapers are whiskers, one gestural sweep is a tadpole. A
// harness is not a silhouette anyone recognises, so the mark stops trying to be
// one.
//
// What is left is the letter, drawn rather than typeset — Apple does not license
// the system faces for icons — with the one liberty that carries the idea: the
// leg does not stop where the letterform ends. It tapers and runs off toward the
// machine.

let bar = length(0.104)
context.setStrokeColor(white)
context.setLineWidth(bar)
context.setLineCap(.round)
context.setLineJoin(.round)

// Stem.
let stem = CGMutablePath()
stem.move(to: point(0.330, 0.208))
stem.addLine(to: point(0.330, 0.792))
context.addPath(stem)
context.strokePath()

// Bowl. Two curves out and back, so the counter is a proper rounded aperture
// rather than a semicircle stuck on the side of the stem.
let bowl = CGMutablePath()
bowl.move(to: point(0.330, 0.208))
bowl.addLine(to: point(0.474, 0.208))
bowl.addCurve(
    to: point(0.474, 0.494),
    control1: point(0.680, 0.208),
    control2: point(0.680, 0.494)
)
bowl.addLine(to: point(0.330, 0.494))
context.addPath(bowl)
context.strokePath()

// The leg, tapering past where the letter would end. It starts inside the bowl
// so the junction is a joint rather than a seam, and stops short of the corner:
// a mark that reaches the edge looks like it was cropped.
taperedRein(
    from: point(0.452, 0.482),
    point(0.548, 0.578),
    point(0.622, 0.652),
    to: point(0.764, 0.792),
    wide: bar,
    narrow: length(0.054),
    capStart: false
)

// MARK: - Write

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    FileHandle.standardError.write(Data("could not encode the image\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(output.path)\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
