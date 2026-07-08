import AppKit
import Foundation

// Standalone re-implementation of EnvyLogoView's shapes using AppKit drawing —
// executable targets can't import each other in SwiftPM, and this is a
// build-time-only tool, so duplicating the shapes here beats restructuring
// the app's module graph just for icon generation.

func quadToCubic(from p0: NSPoint, to p1: NSPoint, control c: NSPoint) -> (NSPoint, NSPoint) {
    let cp1 = NSPoint(x: p0.x + (c.x - p0.x) * 2 / 3, y: p0.y + (c.y - p0.y) * 2 / 3)
    let cp2 = NSPoint(x: p1.x + (c.x - p1.x) * 2 / 3, y: p1.y + (c.y - p1.y) * 2 / 3)
    return (cp1, cp2)
}

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let badgeTop = NSColor(red: 0.408, green: 0.204, blue: 0.545, alpha: 1)
let badgeBottom = NSColor(red: 0.220, green: 0.098, blue: 0.322, alpha: 1)
let scaleColorLight = NSColor(red: 0.482, green: 0.278, blue: 0.643, alpha: 0.32)
let scaleColorDark = NSColor(red: 0.161, green: 0.067, blue: 0.235, alpha: 0.28)
let eyeColor = NSColor(red: 0.9608, green: 0.9608, blue: 0.9608, alpha: 1)
let irisEdgeColor = NSColor(red: 0.243, green: 0.667, blue: 0.278, alpha: 1)
let irisMidColor = NSColor(red: 0.086, green: 0.318, blue: 0.129, alpha: 1)
let irisCenterColor = NSColor(red: 0.02, green: 0.035, blue: 0.02, alpha: 1)
let irisRimColor = NSColor(red: 0.035, green: 0.098, blue: 0.043, alpha: 1)
let pupilColor = NSColor(red: 0.965, green: 0.988, blue: 0.949, alpha: 1)

// Badge background (rounded square, matches modern macOS icon convention),
// filled with a purple gradient and a tiled scale texture — the "green-eyed
// monster" is purple and scaly, not just an eye on a plain background.
let badgeRect = NSRect(x: 0, y: 0, width: size, height: size)
let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: size * 0.225, yRadius: size * 0.225)

NSGraphicsContext.saveGraphicsState()
badgePath.addClip()

let gradient = NSGradient(starting: badgeTop, ending: badgeBottom)
gradient?.draw(in: badgeRect, angle: -90)

// Scaly texture: overlapping rows of U-shaped scales (flat top edge, round
// bend at the bottom), each row offset by half a scale-width from the one
// below so the flat top of every scale is hidden under the scales of the
// row above it — the classic overlapping fish/reptile scale tiling.
let cols = 15
let rowHeight = size / 17
let scaleWidth = size / CGFloat(cols) * 1.15
let scaleRadius = scaleWidth / 2

// Rows/columns run well past the canvas in every direction (negative start,
// generous end) so the tiling always covers the full badge including the
// rounded corners — clipping to badgePath trims the excess, rather than
// relying on the loop bounds to land exactly on the edge.
var row = -1
while CGFloat(row) * rowHeight < size + rowHeight * 2 {
    let y = CGFloat(row) * rowHeight
    let offsetX = (row % 2 == 0) ? 0 : -scaleWidth / 2
    let color = (row % 2 == 0) ? scaleColorDark : scaleColorLight
    var col = -2
    while CGFloat(col) * scaleWidth + offsetX < size + scaleWidth * 2 {
        let cx = CGFloat(col) * scaleWidth + offsetX + scaleRadius
        let scalePath = NSBezierPath()
        scalePath.move(to: NSPoint(x: cx + scaleRadius, y: y))
        scalePath.appendArc(
            withCenter: NSPoint(x: cx, y: y),
            radius: scaleRadius,
            startAngle: 0,
            endAngle: 180,
            clockwise: true
        )
        scalePath.close()
        color.setFill()
        scalePath.fill()
        col += 1
    }
    row += 1
}

NSGraphicsContext.restoreGraphicsState()

// Eye (almond) shape — symmetric, quadratic Bezier control points converted
// to cubic (AppKit's NSBezierPath has no native quad-curve method).
let eyeWidth = size * 0.725
let eyeHeight = size * 0.4
let eyeRect = NSRect(x: (size - eyeWidth) / 2, y: (size - eyeHeight) / 2, width: eyeWidth, height: eyeHeight)
let leftPt = NSPoint(x: eyeRect.minX, y: eyeRect.midY)
let rightPt = NSPoint(x: eyeRect.maxX, y: eyeRect.midY)
let topCtrl = NSPoint(x: eyeRect.midX, y: eyeRect.maxY)
let bottomCtrl = NSPoint(x: eyeRect.midX, y: eyeRect.minY)

let eyePath = NSBezierPath()
eyePath.move(to: leftPt)
let (up1, up2) = quadToCubic(from: leftPt, to: rightPt, control: topCtrl)
eyePath.curve(to: rightPt, controlPoint1: up1, controlPoint2: up2)
let (down1, down2) = quadToCubic(from: rightPt, to: leftPt, control: bottomCtrl)
eyePath.curve(to: leftPt, controlPoint1: down1, controlPoint2: down2)
eyePath.close()
eyeColor.setFill()
eyePath.fill()
eyePath.lineWidth = size * 0.016
NSColor.black.withAlphaComponent(0.75).setStroke()
eyePath.stroke()

// Iris + pupil are clipped to the eye (almond) shape so the iris is larger
// than the almond's vertical opening and its top/bottom get cropped by the
// lid curve — reads as the iris tucked partly under the eyelids, rather
// than floating as a full uncropped circle inside the white.
NSGraphicsContext.saveGraphicsState()
eyePath.addClip()

let irisDiameter = eyeHeight * 1.12
let irisRect = NSRect(x: (size - irisDiameter) / 2, y: (size - irisDiameter) / 2, width: irisDiameter, height: irisDiameter)
let irisPath = NSBezierPath(ovalIn: irisRect)
let irisCenter = NSPoint(x: irisRect.midX, y: irisRect.midY)
let irisRadius = irisDiameter / 2

// Natural iris shading: radial gradient fading from near-black at the pupil
// outward through mid and bright green, darkening again at the outer rim
// (limbal ring) where the iris meets the sclera — like a real eye rather
// than a flat color disc.
let irisGradient = NSGradient(colors: [irisCenterColor, irisMidColor, irisEdgeColor, irisRimColor],
                               atLocations: [0.0, 0.4, 0.82, 1.0],
                               colorSpace: .deviceRGB)
irisGradient?.draw(in: irisPath, relativeCenterPosition: .zero)

// Fine radial fiber striations, like real iris texture: thin lines from
// near the pupil out toward the rim, alternating light/dark for subtle
// contrast, clipped to the iris disc so none of them poke outside it.
NSGraphicsContext.saveGraphicsState()
irisPath.addClip()
let fiberCount = 56
for i in 0..<fiberCount {
    let angle = (CGFloat(i) / CGFloat(fiberCount)) * 2 * .pi
    let jitter = sin(angle * 5.3) * 0.06
    let innerR = irisRadius * (0.18 + jitter)
    let outerR = irisRadius * (0.98 + jitter * 0.4)
    let dx = cos(angle)
    let dy = sin(angle)
    let p0 = NSPoint(x: irisCenter.x + dx * innerR, y: irisCenter.y + dy * innerR)
    let p1 = NSPoint(x: irisCenter.x + dx * outerR, y: irisCenter.y + dy * outerR)
    let fiber = NSBezierPath()
    fiber.move(to: p0)
    fiber.line(to: p1)
    fiber.lineWidth = size * (i % 2 == 0 ? 0.0035 : 0.002)
    let isLight = i % 3 == 0
    (isLight ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.22)).setStroke()
    fiber.stroke()
}
// Limbal ring: a crisp dark ring right at the outer edge of the iris, where
// it meets the white — real eyes have this and it's what most reads as
// "iris" at a glance rather than a plain colored disc.
let ringPath = NSBezierPath(ovalIn: irisRect.insetBy(dx: size * 0.006, dy: size * 0.006))
ringPath.lineWidth = size * 0.018
NSColor.black.withAlphaComponent(0.6).setStroke()
ringPath.stroke()

NSGraphicsContext.restoreGraphicsState()

// Pupil mark: a plain, symmetric chevron ("V").
let chevSize = size * 0.15
let chevRect = NSRect(x: (size - chevSize) / 2, y: (size - chevSize) / 2, width: chevSize, height: chevSize)
let chevPath = NSBezierPath()
chevPath.move(to: NSPoint(x: chevRect.minX, y: chevRect.maxY))
chevPath.line(to: NSPoint(x: chevRect.midX, y: chevRect.minY))
chevPath.line(to: NSPoint(x: chevRect.maxX, y: chevRect.maxY))
chevPath.lineWidth = size * 0.08
chevPath.lineCapStyle = .round
chevPath.lineJoinStyle = .round
pupilColor.setStroke()
chevPath.stroke()

NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()

guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("Failed to render icon PNG\n".data(using: .utf8)!)
    exit(1)
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
