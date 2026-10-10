import SwiftUI

@main
struct PencilCaseApp: App {
    @AppStorage("rulerMomentumEnabled") private var momentumEnabled = true
    @StateObject private var ruler = RulerController.shared

    var body: some Scene {
        MenuBarExtra("Pencil Case", systemImage: "pencil.and.ruler") {
            Toggle("Ruler", isOn: Binding(
                get: { ruler.isVisible },
                set: { ruler.setVisible($0) }
            ))
            .keyboardShortcut("r", modifiers: [.command, .shift])

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
