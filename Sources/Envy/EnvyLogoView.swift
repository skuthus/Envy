import SwiftUI

/// The app mark: a lowered red brow over a cream almond eye with a green
/// iris, on warm charcoal — the "green-eyed monster" of envy, drawn as five
/// flat shapes with no gradient, bevel, shadow or texture.
///
/// Mirrors the AppKit rendering in Sources/IconGenerator/main.swift, which
/// produces the packaged .icns — keep the two in sync if either changes.
/// Geometry is authored in the same 512-unit space as the design's SVG, and
/// needs no y-axis conversion here: SwiftUI's Canvas is top-down like SVG,
/// where AppKit is bottom-up.
struct EnvyLogoView: View {
    var size: CGFloat = 88

    /// The green other views borrow — the tag/checkbox colour, and the only
    /// hue in the mark that also appears in the app's own chrome. Reserved
    /// for things that are literally that green somewhere in the UI.
    static let irisColor = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)

    /// The brand red. Carries the NV of the wordmark, here and on the site —
    /// the Notational Velocity lineage the name is built around.
    static let markColor = Color(red: 0xFF / 255, green: 0x4B / 255, blue: 0x39 / 255)

    private let fieldColor = Color(red: 0x28 / 255, green: 0x25 / 255, blue: 0x20 / 255)
    private let scleraColor = Color(red: 0xFA / 255, green: 0xFA / 255, blue: 0xF8 / 255)

    var body: some View {
        Canvas { context, canvasSize in
            draw(in: context, canvasSize: canvasSize)
        }
        .frame(width: size, height: size)
    }

    private func draw(in context: GraphicsContext, canvasSize: CGSize) {
        let side = min(canvasSize.width, canvasSize.height)
        // Everything below is written in 512-unit design coordinates.
        let s = side / 512
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

        // Field. 22.37% corner radius is the macOS icon proportion — a
        // circular arc, not Apple's continuous curve, so it reads a touch
        // tighter than a system-drawn one.
        let field = Path(roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                         cornerRadius: side * 0.2237)
        context.fill(field, with: .color(fieldColor))

        // Brow: a stroked arc with round caps, so it holds an even thickness
        // end to end. An outlined crescent would taper to nothing at its
        // tips, which is where small sizes lose it first.
        var brow = Path()
        brow.move(to: p(84, 182))
        brow.addQuadCurve(to: p(428, 182), control: p(256, 96))
        context.stroke(
            brow,
            with: .color(Self.markColor),
            style: StrokeStyle(lineWidth: 58 * s, lineCap: .round)
        )

        // Almond: two quadratic curves meeting at a point. Structural, not
        // decorative — it's the only thing keeping the red and the green
        // from sharing an edge, and complementaries that touch shimmer.
        var almond = Path()
        almond.move(to: p(40, 290))
        almond.addQuadCurve(to: p(472, 290), control: p(256, 110))
        almond.addQuadCurve(to: p(40, 290), control: p(256, 470))
        almond.closeSubpath()
        context.fill(almond, with: .color(scleraColor))

        // Iris.
        let irisRect = CGRect(x: (256 - 70) * s, y: (290 - 70) * s, width: 140 * s, height: 140 * s)
        context.fill(Path(ellipseIn: irisRect), with: .color(Self.irisColor))

        // Pupil is the field colour, not a separate black — it reads as a
        // hole punched through to the background rather than as a sixth
        // shape, which is also why changing the field doesn't flatten it.
        let pupilRect = CGRect(x: (256 - 28) * s, y: (290 - 28) * s, width: 56 * s, height: 56 * s)
        context.fill(Path(ellipseIn: pupilRect), with: .color(fieldColor))
    }
}
