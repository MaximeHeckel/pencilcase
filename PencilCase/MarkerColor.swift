import AppKit
import SwiftUI

struct MarkerColor: Identifiable {
    let name: String
    let color: NSColor
    var id: String { name }

    /// A non-template image keeps its actual ink color in native macOS menus.
    func menuSwatch(selected: Bool) -> NSImage {
        let ink = color.usingColorSpace(.sRGB) ?? color
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            ink.setFill()
            circle.fill()
            NSColor.gray.withAlphaComponent(0.65).setStroke()
            circle.lineWidth = 0.6
            circle.stroke()

            if selected {
                let luminance = 0.2126 * ink.redComponent + 0.7152 * ink.greenComponent + 0.0722 * ink.blueComponent
                (luminance > 0.6 ? NSColor.black : NSColor.white).setStroke()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: 5, y: 9))
                check.line(to: CGPoint(x: 8, y: 6))
                check.line(to: CGPoint(x: 13, y: 12))
                check.lineWidth = 1.7
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    static let presets: [MarkerColor] = [
        MarkerColor(name: "Red", color: NSColor(srgbRed: 0.95, green: 0.23, blue: 0.25, alpha: 1)),
        MarkerColor(name: "Blue", color: NSColor(srgbRed: 0, green: 122.0 / 255, blue: 1, alpha: 1)),
        MarkerColor(name: "Green", color: NSColor(srgbRed: 52.0 / 255, green: 199.0 / 255, blue: 89.0 / 255, alpha: 1)),
        MarkerColor(name: "Yellow", color: NSColor(srgbRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)),
        MarkerColor(name: "Black", color: NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1)),
        MarkerColor(name: "White", color: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ]
}

struct MarkerColorPalette: View {
    @ObservedObject var marker: MarkerController
    let toolID: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(marker.tools[toolID].name).font(.headline)
            HStack(spacing: 8) {
                ForEach(MarkerColor.presets) { preset in
                    Button { marker.choosePaletteColor(preset.color, for: toolID) } label: {
                        Circle()
                            .fill(Color(nsColor: preset.color))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                            .padding(4)
                            .overlay(Circle().strokeBorder(marker.isSelected(preset.color, for: toolID) ? Color.primary : Color.clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(preset.name)
                    .accessibilityValue(marker.isSelected(preset.color, for: toolID) ? "Selected" : "")
                    .help(preset.name)
                }
            }
            Divider()
            Button("Custom Color…") { marker.showCustomColor(for: toolID) }
            Divider()
            Text("Click tip to draw · Drag barrel to move\n⌥ Drag to rotate · ⇧ to snap · Escape to finish")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .fixedSize()
    }
}
