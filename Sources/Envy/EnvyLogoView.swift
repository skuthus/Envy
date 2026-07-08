import SwiftUI

/// The app mark: a purple, scaly monster's eye — a green iris (the
/// "green-eyed monster" of envy) with a V-chevron pupil (a nod to
/// Notational Velocity). Mirrors the AppKit rendering in
/// Sources/IconGenerator/main.swift, which produces the packaged .icns —
/// keep the two in sync if either changes.
struct EnvyLogoView: View {
    var size: CGFloat = 88

    static let irisColor = Color(red: 0.243, green: 0.667, blue: 0.278)

    private let badgeTop = Color(red: 0.408, green: 0.204, blue: 0.545)
    private let badgeBottom = Color(red: 0.220, green: 0.098, blue: 0.322)
    private let scaleColorLight = Color(red: 0.482, green: 0.278, blue: 0.643).opacity(0.32)
    private let scaleColorDark = Color(red: 0.161, green: 0.067, blue: 0.235).opacity(0.28)
    private let eyeColor = Color(red: 0.9608, green: 0.9608, blue: 0.9608)
    private let irisMidColor = Color(red: 0.086, green: 0.318, blue: 0.129)
    private let irisCenterColor = Color(red: 0.02, green: 0.035, blue: 0.02)
    private let irisRimColor = Color(red: 0.035, green: 0.098, blue: 0.043)

    var body: some View {
        Canvas { context, canvasSize in
            draw(in: context, canvasSize: canvasSize)
        }
        .frame(width: size, height: size)
    }

    private func draw(in context: GraphicsContext, canvasSize: CGSize) {
        let size = min(canvasSize.width, canvasSize.height)
        let badgeRect = CGRect(x: 0, y: 0, width: size, height: size)
        let badgePath = Path(roundedRect: badgeRect, cornerRadius: size * 0.225)

        context.drawLayer { ctx in
            ctx.clip(to: badgePath)
            ctx.fill(
                Path(badgeRect),
                with: .linearGradient(
                    Gradient(colors: [badgeTop, badgeBottom]),
                    startPoint: CGPoint(x: size / 2, y: 0),
                    endPoint: CGPoint(x: size / 2, y: size)
                )
            )

            // Scaly texture: overlapping rows of U-shaped scales, each row
            // offset by half a scale-width from the one below. See the
            // AppKit version for the full explanation of the tiling.
            let cols = 15
            let rowHeight = size / 17
            let scaleWidth = size / CGFloat(cols) * 1.15
            let scaleRadius = scaleWidth / 2

            var row = -1
            while CGFloat(row) * rowHeight < size + rowHeight * 2 {
                let y = CGFloat(row) * rowHeight
                let offsetX = (row % 2 == 0) ? 0 : -scaleWidth / 2
                let color = (row % 2 == 0) ? scaleColorDark : scaleColorLight
                var col = -2
                while CGFloat(col) * scaleWidth + offsetX < size + scaleWidth * 2 {
                    let cx = CGFloat(col) * scaleWidth + offsetX + scaleRadius
                    var scalePath = Path()
                    scalePath.move(to: CGPoint(x: cx - scaleRadius, y: y))
                    scalePath.addQuadCurve(
                        to: CGPoint(x: cx + scaleRadius, y: y),
                        control: CGPoint(x: cx, y: y + scaleRadius * 1.33)
                    )
                    scalePath.closeSubpath()
                    ctx.fill(scalePath, with: .color(color))
                    col += 1
                }
                row += 1
            }
        }

        // Eye (almond) shape — symmetric, with a dark eyelid outline.
        let eyeWidth = size * 0.725
        let eyeHeight = size * 0.4
        let eyeRect = CGRect(x: (size - eyeWidth) / 2, y: (size - eyeHeight) / 2, width: eyeWidth, height: eyeHeight)
        var eyePath = Path()
        eyePath.move(to: CGPoint(x: eyeRect.minX, y: eyeRect.midY))
        eyePath.addQuadCurve(to: CGPoint(x: eyeRect.maxX, y: eyeRect.midY), control: CGPoint(x: eyeRect.midX, y: eyeRect.minY))
        eyePath.addQuadCurve(to: CGPoint(x: eyeRect.minX, y: eyeRect.midY), control: CGPoint(x: eyeRect.midX, y: eyeRect.maxY))
        context.fill(eyePath, with: .color(eyeColor))
        context.stroke(eyePath, with: .color(.black.opacity(0.75)), lineWidth: size * 0.016)

        // Iris + pupil are clipped to the eye shape so the iris (larger than
        // the almond's vertical opening) reads as tucked under the eyelids.
        context.drawLayer { ctx in
            ctx.clip(to: eyePath)

            let irisDiameter = eyeHeight * 1.12
            let irisRect = CGRect(x: (size - irisDiameter) / 2, y: (size - irisDiameter) / 2, width: irisDiameter, height: irisDiameter)
            let irisPath = Path(ellipseIn: irisRect)
            let irisCenter = CGPoint(x: irisRect.midX, y: irisRect.midY)
            let irisRadius = irisDiameter / 2

            ctx.fill(
                irisPath,
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: irisCenterColor, location: 0.0),
                        .init(color: irisMidColor, location: 0.4),
                        .init(color: Self.irisColor, location: 0.82),
                        .init(color: irisRimColor, location: 1.0),
                    ]),
                    center: irisCenter,
                    startRadius: 0,
                    endRadius: irisRadius
                )
            )

            // Fine radial fiber striations, clipped to the iris disc.
            ctx.drawLayer { fiberCtx in
                fiberCtx.clip(to: irisPath)
                let fiberCount = 56
                for i in 0..<fiberCount {
                    let angle = (CGFloat(i) / CGFloat(fiberCount)) * 2 * .pi
                    let jitter = sin(angle * 5.3) * 0.06
                    let innerR = irisRadius * (0.18 + jitter)
                    let outerR = irisRadius * (0.98 + jitter * 0.4)
                    let dx = cos(angle)
                    let dy = sin(angle)
                    var fiber = Path()
                    fiber.move(to: CGPoint(x: irisCenter.x + dx * innerR, y: irisCenter.y + dy * innerR))
                    fiber.addLine(to: CGPoint(x: irisCenter.x + dx * outerR, y: irisCenter.y + dy * outerR))
                    let isLight = i % 3 == 0
                    let lineWidth = size * (i % 2 == 0 ? 0.0035 : 0.002)
                    fiberCtx.stroke(
                        fiber,
                        with: .color(isLight ? .white.opacity(0.10) : .black.opacity(0.22)),
                        lineWidth: lineWidth
                    )
                }
            }

            // Limbal ring: a crisp dark ring at the outer edge of the iris.
            let ringPath = Path(ellipseIn: irisRect.insetBy(dx: size * 0.006, dy: size * 0.006))
            ctx.stroke(ringPath, with: .color(.black.opacity(0.6)), lineWidth: size * 0.018)

            // Pupil mark: a plain, symmetric chevron ("V").
            let chevSize = size * 0.15
            let chevRect = CGRect(x: (size - chevSize) / 2, y: (size - chevSize) / 2, width: chevSize, height: chevSize)
            var chevPath = Path()
            chevPath.move(to: CGPoint(x: chevRect.minX, y: chevRect.minY))
            chevPath.addLine(to: CGPoint(x: chevRect.midX, y: chevRect.maxY))
            chevPath.addLine(to: CGPoint(x: chevRect.maxX, y: chevRect.minY))
            ctx.stroke(
                chevPath,
                with: .color(eyeColor),
                style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round)
            )
        }
    }
}
