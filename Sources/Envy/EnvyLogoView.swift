import SwiftUI

/// The app mark: a green eye (the "green-eyed monster" of envy) with a
/// V-chevron pupil (a nod to Notational Velocity).
struct EnvyLogoView: View {
    var size: CGFloat = 88

    static let irisColor = Color(red: 0.1804, green: 0.4902, blue: 0.1961)

    private var badgeColor: Color { Color(red: 0.1098, green: 0.1098, blue: 0.1176) }
    private var eyeColor: Color { Color(red: 0.9608, green: 0.9608, blue: 0.9608) }
    private var irisColor: Color { Self.irisColor }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(badgeColor)

            EyeShape()
                .fill(eyeColor)
                .frame(width: size * 0.725, height: size * 0.4)

            Circle()
                .fill(irisColor)
                .frame(width: size * 0.325, height: size * 0.325)

            ChevronShape()
                .stroke(eyeColor, style: StrokeStyle(lineWidth: size * 0.08, lineCap: .round, lineJoin: .round))
                .frame(width: size * 0.15, height: size * 0.15)
        }
        .frame(width: size, height: size)
    }
}

private struct EyeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.midY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}

private struct ChevronShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
