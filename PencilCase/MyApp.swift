import SwiftUI

@main
struct PencilCaseApp: App {
    @AppStorage("rulerMomentumEnabled") private var momentumEnabled = true
    @StateObject private var ruler = RulerController.shared
    @AppStorage("loupeTickSound") private var loupeTickSound = true
    @StateObject private var loupe = LoupeController.shared
    @StateObject private var marker = MarkerController.shared

    private let strokeWidths: [Double] = [1, 2, 3, 4, 6, 8, 12, 16, 20]

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
                Menu("Marker") {
                    Menu("Color") {
                        ForEach(MarkerColor.presets) { preset in
                            Button { marker.selectColor(preset.color) } label: {
                                Label(preset.name, systemImage: marker.isSelected(preset.color) ? "checkmark.circle.fill" : "circle.fill")
                            }
                        }
                        Divider()
                        Button("Custom Color…") { marker.showCustomColor() }
                    }

                    Menu("Stroke Thickness (\(Int(marker.strokeWidth)) pt)") {
                        Picker("Stroke Thickness", selection: $marker.strokeWidth) {
                            // Include slider values between the menu presets so the
                            // current thickness always has an accurate checkmark.
                            ForEach(Array(Set(strokeWidths + [marker.strokeWidth])).sorted(), id: \.self) { width in
                                Text("\(Int(width)) pt").tag(width)
                            }
                        }
                        .pickerStyle(.inline)
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
                Menu("Marker Controls") {
                    Text("Click the tip to toggle drawing")
                    Text("Drag the barrel to move or throw it")
                    Text("Escape to finish drawing")
                    Text("Draw along a ruler edge for straight lines")
                    Text("Ink fades after 30 seconds")
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
