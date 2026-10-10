import SwiftUI

@main
struct PencilCaseApp: App {
    @AppStorage("rulerMomentumEnabled") private var momentumEnabled = true
    @StateObject private var ruler = RulerController.shared
    @StateObject private var marker = MarkerController.shared

    var body: some Scene {
        MenuBarExtra("Pencil Case", systemImage: "pencil.and.ruler") {
            Toggle("Ruler", isOn: Binding(
                get: { ruler.isVisible },
                set: { ruler.setVisible($0) }
            ))
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Toggle("Marker", isOn: Binding(
                get: { marker.isVisible }, set: { marker.setVisible($0) }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Menu("Marker Color") {
                ForEach(MarkerColor.presets) { preset in
                    Button { marker.selectColor(preset.color) } label: {
                        Label(preset.name, systemImage: marker.isSelected(preset.color) ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
                Divider()
                Button("Custom Color…") { marker.showCustomColor() }
            }

            Toggle("Draw on Screen", isOn: Binding(
                get: { marker.isDrawing }, set: { marker.setDrawing($0) }
            ))
            if marker.isDrawing { Text("Escape to finish drawing") }
            if let error = marker.escapeShortcutError { Text(error) }
            if let error = marker.historyShortcutError { Text(error) }
            Button("Undo Stroke") { marker.undoStroke() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!marker.canUndo)
            Button("Redo Stroke") { marker.redoStroke() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!marker.canRedo)
            Button("Clear All Markings") { marker.clearMarkings() }
                .disabled(!marker.hasMarkings)
            Text("Ink fades after 30 seconds")

            if let shortcutError = ruler.shortcutError {
                Text(shortcutError)
            }

            Divider()
            Toggle("Momentum When Throwing", isOn: $momentumEnabled)
            Text("Drag ends to resize")
            Text("⌥ Drag to rotate · ⇧ to snap")
            Button("Reset Ruler Size and Angle") { ruler.resetSizeAndAngle() }
            Button("Reset Ruler Position") { ruler.resetPosition() }
            Divider()
            Button("Quit Pencil Case") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
