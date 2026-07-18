import AppKit
import Foundation

// Draws the "Low Arc" app icon: a lowered red brow over a cream almond eye
// with a green iris, on warm charcoal. Five flat shapes — no gradient, bevel,
// shadow or texture — which is what lets it survive to 16px.
//
// Geometry is authored in a 512-unit square (the same coordinates as the
// design's SVG) and scaled to whatever pixel size is requested, so there's
// one source of truth for the shapes at every size.
//
// Coordinates are converted from the SVG's top-down y-axis to AppKit's
// bottom-up one on the way in: y_appkit = 512 - y_svg. The almond happens to
// be vertically symmetric about its centre, so only the brow actually moves.
//
// Usage: IconGenerator <output.png> [pixelSize]

// MARK: - Palette

let field = NSColor(srgbRed: 0x28 / 255, green: 0x25 / 255, blue: 0x20 / 255, alpha: 1)
let brow  = NSColor(srgbRed: 0xFF / 255, green: 0x4B / 255, blue: 0x39 / 255, alpha: 1)
let sclera = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xF8 / 255, alpha: 1)
let iris  = NSColor(srgbRed: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255, alpha: 1)

// MARK: - Geometry (512-unit design space, AppKit orientation)

let unit: CGFloat = 512

/// AppKit's NSBezierPath has no quadratic-curve method, so the design's
/// quadratic control points are raised to the equivalent cubic pair.
func quadToCubic(from p0: NSPoint, to p1: NSPoint, control c: NSPoint) -> (NSPoint, NSPoint) {
    let cp1 = NSPoint(x: p0.x + (c.x - p0.x) * 2 / 3, y: p0.y + (c.y - p0.y) * 2 / 3)
    let cp2 = NSPoint(x: p1.x + (c.x - p1.x) * 2 / 3, y: p1.y + (c.y - p1.y) * 2 / 3)
    return (cp1, cp2)
}

func quadPath(from p0: NSPoint, to p1: NSPoint, control c: NSPoint) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: p0)
    let (cp1, cp2) = quadToCubic(from: p0, to: p1, control: c)
    path.curve(to: p1, controlPoint1: cp1, controlPoint2: cp2)
    return path
}

/// Small sizes aren't a straight downscale. Below ~32px a 58-unit stroke
/// lands under two pixels and antialiasing eats it, the gap between brow and
/// eye closes up, and the pupil stops being a hole and becomes grey mush. So
/// the brow thickens and lifts, the iris grows, and the pupil is dropped
/// entirely once it can't render as a distinct shape.
struct Tuning {
    var browWidth: CGFloat
    var browLift: CGFloat
    var irisRadius: CGFloat
    var drawsPupil: Bool

    static func forPixelSize(_ px: Int) -> Tuning {
        if px <= 16 {
            return Tuning(browWidth: 70, browLift: 14, irisRadius: 80, drawsPupil: false)
        } else if px <= 32 {
            return Tuning(browWidth: 64, browLift: 10, irisRadius: 76, drawsPupil: true)
        }
        return Tuning(browWidth: 58, browLift: 0, irisRadius: 70, drawsPupil: true)
    }
}

func renderIcon(pixelSize px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }

    let tuning = Tuning.forPixelSize(px)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    // Everything below is written in 512-unit coordinates.
    let scale = CGFloat(px) / unit
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    // Field. Corner radius is 22.37% of the side — the macOS icon proportion.
    // A circular arc, not Apple's continuous curve, so it reads a touch
    // tighter than a system-drawn one.
    let fieldRect = NSRect(x: 0, y: 0, width: unit, height: unit)
    let fieldPath = NSBezierPath(roundedRect: fieldRect, xRadius: unit * 0.2237, yRadius: unit * 0.2237)
    field.setFill()
    fieldPath.fill()

    // Brow: a stroked arc with round caps, so it holds an even thickness the
    // whole way. An outlined crescent would taper to nothing at its ends —
    // exactly where the small sizes lose it first.
    let browPath = quadPath(
        from: NSPoint(x: 84, y: 330 + tuning.browLift),
        to: NSPoint(x: 428, y: 330 + tuning.browLift),
        control: NSPoint(x: 256, y: 416 + tuning.browLift)
    )
    browPath.lineWidth = tuning.browWidth
    browPath.lineCapStyle = .round
    brow.setStroke()
    browPath.stroke()

    // Almond: two quadratic curves meeting at a point. This shape is
    // structural, not decoration — it's the only thing keeping the red and
    // the green from sharing an edge, and complementaries that touch shimmer.
    let left = NSPoint(x: 40, y: 222)
    let right = NSPoint(x: 472, y: 222)
    let almond = NSBezierPath()
    almond.move(to: left)
    let (upper1, upper2) = quadToCubic(from: left, to: right, control: NSPoint(x: 256, y: 402))
    almond.curve(to: right, controlPoint1: upper1, controlPoint2: upper2)
    let (lower1, lower2) = quadToCubic(from: right, to: left, control: NSPoint(x: 256, y: 42))
    almond.curve(to: left, controlPoint1: lower1, controlPoint2: lower2)
    almond.close()
    sclera.setFill()
    almond.fill()

    // Iris.
    let centre = NSPoint(x: 256, y: 222)
    let r = tuning.irisRadius
    iris.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)).fill()

    // Pupil is the field colour, not a separate black — it reads as a hole
    // punched through to the background rather than as a sixth shape, which
    // is also why changing the field doesn't flatten the eye.
    if tuning.drawsPupil {
        let pr: CGFloat = 28
        field.setFill()
        NSBezierPath(ovalIn: NSRect(x: centre.x - pr, y: centre.y - pr, width: pr * 2, height: pr * 2)).fill()
    }

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Entry point

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let pixelSize = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 1024 : 1024

guard pixelSize > 0, let pngData = renderIcon(pixelSize: pixelSize) else {
    FileHandle.standardError.write("Failed to render icon at \(pixelSize)px\n".data(using: .utf8)!)
    exit(1)
}

try pngData.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath) (\(pixelSize)px)")
