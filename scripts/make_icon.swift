// Renders packaging/appicon/icon_*.png from the same FlaskShape the app uses.
// Run: swiftc -parse-as-library scripts/make_icon.swift Sources/SudsAndSlots/Theme.swift -o /tmp/mkicon && /tmp/mkicon
import SwiftUI
import AppKit

@main
struct MakeIcon {
    @MainActor static func main() {
        let icon = ZStack {
            LinearGradient(colors: [Color(red: 0.55, green: 0.36, blue: 1.0), Color(red: 0.36, green: 0.18, blue: 0.80)],
                           startPoint: .top, endPoint: .bottom)
            FlaskShape()
                .stroke(Color.white, style: StrokeStyle(lineWidth: 34, lineCap: .round, lineJoin: .round))
                .padding(140)
        }
        .frame(width: 1024, height: 1024)

        for size in [120, 152, 167, 180, 1024] {
            let renderer = ImageRenderer(content: icon)
            renderer.scale = CGFloat(size) / 1024
            guard let cg = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { continue }
            try! png.write(to: URL(fileURLWithPath: "packaging/appicon/icon_\(size).png"))
        }
    }
}
