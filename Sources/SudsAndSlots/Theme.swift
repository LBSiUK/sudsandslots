import SwiftUI

enum Theme {
    static let background = LinearGradient(
        colors: [Color(red: 0.16, green: 0.07, blue: 0.30), Color(red: 0.05, green: 0.06, blue: 0.16)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let panel = Color.white.opacity(0.06)
    static let panelStroke = Color.white.opacity(0.10)
    static let control = Color.black.opacity(0.28)
    static let controlStroke = Color.white.opacity(0.12)
    static let secondaryText = Color.white.opacity(0.6)
}

/// A rounded, faintly bordered panel: the two main columns.
struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Theme.panelStroke))
    }
}

extension View {
    func panel() -> some View { modifier(PanelBackground()) }
}

/// Small grey uppercase section heading, e.g. "WHO'S WASHING?".
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .semibold))
            .tracking(0.4)
            .foregroundColor(Theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Dark rounded tile used for durations and days. Takes the selected person's
/// colour when chosen.
struct TileButtonStyle: ButtonStyle {
    var selected: Bool
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .background(selected ? tint : Theme.control, in: shape)
            .overlay(shape.stroke(selected ? Color.white.opacity(0.9) : Theme.controlStroke,
                                  lineWidth: selected ? 2 : 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Lab flask drawn as a shape (there's no flask SF Symbol on iOS 15).
struct FlaskShape: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height
        var p = Path()
        let neckL = r.minX + w * 0.36, neckR = r.minX + w * 0.64
        let top = r.minY + h * 0.08, shoulder = r.minY + h * 0.42
        let bottom = r.minY + h * 0.92
        p.move(to: CGPoint(x: neckL, y: top))
        p.addLine(to: CGPoint(x: neckL, y: shoulder))
        p.addLine(to: CGPoint(x: r.minX + w * 0.12, y: bottom - h * 0.06))
        p.addQuadCurve(to: CGPoint(x: r.minX + w * 0.2, y: bottom),
                       control: CGPoint(x: r.minX + w * 0.1, y: bottom))
        p.addLine(to: CGPoint(x: r.minX + w * 0.8, y: bottom))
        p.addQuadCurve(to: CGPoint(x: r.minX + w * 0.88, y: bottom - h * 0.06),
                       control: CGPoint(x: r.minX + w * 0.9, y: bottom))
        p.addLine(to: CGPoint(x: neckR, y: shoulder))
        p.addLine(to: CGPoint(x: neckR, y: top))
        // Lip of the flask.
        p.move(to: CGPoint(x: r.minX + w * 0.28, y: top))
        p.addLine(to: CGPoint(x: r.minX + w * 0.72, y: top))
        // Liquid line.
        p.move(to: CGPoint(x: r.minX + w * 0.24, y: r.minY + h * 0.68))
        p.addLine(to: CGPoint(x: r.minX + w * 0.76, y: r.minY + h * 0.68))
        return p
    }
}

struct AppBadge: View {
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 1.0),
                                          Color(red: 0.42, green: 0.22, blue: 0.86)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                FlaskShape()
                    .stroke(Color.white, style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round, lineJoin: .round))
                    .padding(size * 0.2)
            )
    }
}
