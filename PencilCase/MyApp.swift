import SwiftUI

@main
struct PencilCaseApp: App {
    @AppStorage("rulerMomentumEnabled") private var momentumEnabled = true
    @StateObject private var ruler = RulerController.shared
    @AppStorage("loupeTickSound") private var loupeTickSound = true
    @StateObject private var loupe = LoupeController.shared
    @StateObject private var marker = MarkerController.shared

    var body: some Scene {
        MenuBarExtra("Pencil Case", systemImage: "pencil.and.ruler") {
            Toggle("Ruler", isOn: Binding(
                get: { ruler.isVisible },
                set: { ruler.setVisible($0) }
            ))
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Toggle("Markers", isOn: Binding(
                get: { marker.isVisible }, set: { marker.setVisible($0) }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Toggle("Loupe", isOn: Binding(
                get: { loupe.isVisible }, set: { loupe.setVisible($0) }
            ))
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()

            Toggle("Draw on Screen", isOn: Binding(
                get: { marker.isDrawing }, set: { marker.setDrawing($0) }
            ))
            Button("Undo Stroke") { marker.undoStroke() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!marker.canUndo)
            Button("Redo Stroke") { marker.redoStroke() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!marker.canRedo)
            Button("Clear All Markings") { marker.clearMarkings() }
                .disabled(!marker.hasMarkings)

            Divider()

            Menu("Tool Options") {
                Menu("Markers") {
                    ForEach(marker.tools) { tool in
                        Menu("\(tool.id + 1). \(tool.name)") {
                            Button("Use for Drawing") {
                                marker.selectTool(tool.id)
                                marker.setDrawing(true)
                            }
                            Menu("Color") {
                                ForEach(MarkerColor.presets) { preset in
                                    Button { marker.selectColor(preset.color, for: tool.id) } label: {
                                        Label(preset.name, systemImage: marker.isSelected(preset.color, for: tool.id) ? "checkmark.circle.fill" : "circle.fill")
                                    }
                                }
                                Divider()
                                Button("Custom Color…") { marker.showCustomColor(for: tool.id) }
                            }

                        }
                    }
                }

                Button("Reset Ruler Size and Angle") { ruler.resetSizeAndAngle() }

                Divider()

                Toggle("Throwing Momentum", isOn: $momentumEnabled)
                Toggle("Loupe Dial Sound", isOn: $loupeTickSound)
            }

            Menu("Help") {
                Menu("Ruler Controls") {
                    Text("Drag the ruler to move or throw it")
                    Text("Drag ends to resize")
                    Text("⌥ Drag to rotate · ⇧ to snap")
                }
                Menu("Loupe Controls") {
                    Text("Drag the lens to move or throw it")
                    Text("Rotate the ring to adjust zoom")
                }
            }

            if let error = loupe.error {
                Divider()
                Text(error)
                Button("Retry Loupe Capture") { loupe.retryCapture() }
                Button("Screen Recording Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            if let error = ruler.shortcutError { Text(error) }
            if let error = marker.escapeShortcutError { Text(error) }
            if let error = marker.historyShortcutError { Text(error) }

            Divider()

            Button("Quit Pencil Case") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
