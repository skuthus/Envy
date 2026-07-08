import AppKit
import Foundation

// Standalone re-implementation of EnvyLogoView's shapes using AppKit drawing —
// executable targets can't import each other in SwiftPM, and this is a
// build-time-only tool, so duplicating the ~40 lines here beats restructuring
// the app's module graph just for icon generation.

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let badgeColor = NSColor(red: 0.1098, green: 0.1098, blue: 0.1176, alpha: 1)
let eyeColor = NSColor(red: 0.9608, green: 0.9608, blue: 0.9608, alpha: 1)
let irisColor = NSColor(red: 0.1804, green: 0.4902, blue: 0.1961, alpha: 1)

// Badge background (rounded square, matches modern macOS icon convention).
let badgeRect = NSRect(x: 0, y: 0, width: size, height: size)
badgeColor.setFill()
NSBezierPath(roundedRect: badgeRect, xRadius: size * 0.225, yRadius: size * 0.225).fill()

// Eye (almond) shape — quadratic Bezier control points converted to cubic
// (AppKit's NSBezierPath has no native quad-curve method).
func quadToCubic(from p0: NSPoint, to p1: NSPoint, control c: NSPoint) -> (NSPoint, NSPoint) {
    let cp1 = NSPoint(x: p0.x + (c.x - p0.x) * 2 / 3, y: p0.y + (c.y - p0.y) * 2 / 3)
    let cp2 = NSPoint(x: p1.x + (c.x - p1.x) * 2 / 3, y: p1.y + (c.y - p1.y) * 2 / 3)
    return (cp1, cp2)
}

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

// Iris (green circle, centered).
let irisDiameter = size * 0.325
let irisRect = NSRect(x: (size - irisDiameter) / 2, y: (size - irisDiameter) / 2, width: irisDiameter, height: irisDiameter)
irisColor.setFill()
NSBezierPath(ovalIn: irisRect).fill()

// Pupil (V chevron stroke).
let chevSize = size * 0.15
let chevRect = NSRect(x: (size - chevSize) / 2, y: (size - chevSize) / 2, width: chevSize, height: chevSize)
let chevPath = NSBezierPath()
chevPath.move(to: NSPoint(x: chevRect.minX, y: chevRect.maxY))
chevPath.line(to: NSPoint(x: chevRect.midX, y: chevRect.minY))
chevPath.line(to: NSPoint(x: chevRect.maxX, y: chevRect.maxY))
chevPath.lineWidth = size * 0.08
chevPath.lineCapStyle = .round
chevPath.lineJoinStyle = .round
eyeColor.setStroke()
chevPath.stroke()

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
