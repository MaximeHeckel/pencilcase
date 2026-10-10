import AppKit
import SwiftUI

struct MarkerColor: Identifiable {
    let name: String
    let color: NSColor
    var id: String { name }

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
