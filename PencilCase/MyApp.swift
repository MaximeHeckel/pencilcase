import SwiftUI

@main
struct PencilCaseApp: App {
    @StateObject private var shortcuts = ToolShortcuts.shared
    @StateObject private var ruler = RulerController.shared
    @StateObject private var loupe = LoupeController.shared
    @StateObject private var marker = MarkerController.shared

    var body: some Scene {
        MenuBarExtra("Pencil Case", systemImage: "pencil.and.ruler") {
            Toggle("Ruler", isOn: Binding(
                get: { ruler.isVisible },
                set: { ruler.setVisible($0) }
            ))
            .keyboardShortcut(shortcuts.shortcut(for: .ruler)?.menuShortcut)

            Toggle("Markers", isOn: Binding(
                get: { marker.isVisible }, set: { marker.setVisible($0) }
            ))
            .keyboardShortcut(shortcuts.shortcut(for: .markers)?.menuShortcut)

            Toggle("Loupe", isOn: Binding(
                get: { loupe.isVisible }, set: { loupe.setVisible($0) }
            ))
            .keyboardShortcut(shortcuts.shortcut(for: .loupe)?.menuShortcut)

            Divider()

            Button("Undo Stroke") { marker.undoStroke() }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!marker.canUndo)
            Button("Redo Stroke") { marker.redoStroke() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!marker.canRedo)
            Button("Clear All Markings") { marker.clearMarkings() }
                .keyboardShortcut(shortcuts.shortcut(for: .clearMarkings)?.menuShortcut)
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
                                        Label {
                                            Text(preset.name)
                                        } icon: {
                                            Image(nsImage: preset.menuSwatch(selected: marker.isSelected(preset.color, for: tool.id)))
                                                .renderingMode(.original)
                                        }
                                    }
                                }
                                Divider()
                                Button("Custom Color…") { marker.showCustomColor(for: tool.id) }
                            }

                        }
                    }
                }

                Button("Reset Ruler Size and Angle") { ruler.resetSizeAndAngle() }

            }


            if let error = loupe.error {
                Divider()
                Text(error)
                Button("Retry Loupe Capture") { loupe.retryCapture() }
                Button("Screen Recording Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
            if let error = shortcuts.error { Text(error) }
            if let error = ruler.shortcutError { Text(error) }
            if let error = marker.escapeShortcutError { Text(error) }
            if let error = marker.historyShortcutError { Text(error) }

            Divider()

            Button("Settings…") { SettingsWindow.shared.show() }

            Button("Quit Pencil Case") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
