import AppKit
import SwiftUI
import Combine

@MainActor
final class SettingsWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    @Published var tab = 0
    private var window: NSWindow?
    private var keyMonitor: Any?

    func show() {
        MarkerController.shared.setDrawing(false)
        ToolShortcuts.shared.endRecording()

        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Pencil Case Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PencilCaseSettings(window: self))
            window.delegate = self
            window.center()
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, event.window === self.window,
                          let tool = ToolShortcuts.shared.recording else { return false }
                    if event.keyCode == 53 {
                        ToolShortcuts.shared.endRecording()
                    } else if let shortcut = ToolShortcut.from(event) {
                        ToolShortcuts.shared.assign(shortcut, to: tool)
                    } else {
                        ToolShortcuts.shared.error = "Use a letter or number with Command, Option, or Control."
                    }
                    return true
                }
                return consumed ? nil : event
            }
        }
    }

    func resizeForTab() {
        guard let window else { return }
        let height: CGFloat = tab == 0 ? 430 : 700
        let contentRect = NSRect(x: 0, y: 0, width: 540, height: height)
        let size = window.frameRect(forContentRect: contentRect).size
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        ToolShortcuts.shared.endRecording()
    }

    func windowWillClose(_ notification: Notification) {
        ToolShortcuts.shared.endRecording()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

struct PencilCaseSettings: View {
    @ObservedObject var window: SettingsWindow
    @ObservedObject private var shortcuts = ToolShortcuts.shared
    @ObservedObject private var drawing = DrawingPreferences.shared
    @AppStorage("rulerMomentumEnabled") private var momentum = true
    @AppStorage("loupeTickSound") private var dialSound = true

    var body: some View {
        TabView(selection: $window.tab) {
            Form {
                Section("Motion") {
                    Toggle("Throwing physics", isOn: $momentum)
                }
                Section("Sound") {
                    Toggle("Loupe dial ticks", isOn: $dialSound)
                }
                Section {
                    Toggle("Automatically remove drawings", isOn: $drawing.automatic)
                    HStack {
                        Text("Disappear after")
                        Spacer()
                        TextField("Seconds", value: Binding(
                            get: { drawing.seconds },
                            set: { drawing.seconds = min(3600, max(1, $0)) }
                        ), format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                        .accessibilityLabel("Drawing lifetime in seconds")
                        Text("seconds").foregroundStyle(.secondary).fixedSize()
                        Stepper("Disappear after", value: $drawing.seconds, in: 1...3600)
                            .labelsHidden().fixedSize()
                    }
                    .disabled(!drawing.automatic)
                } header: {
                    Text("Drawings")
                } footer: {
                    Text("When turned off, drawings stay until you clear or undo them.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }.tag(0)

            Form {
                Section {
                    shortcutRow(.ruler, symbol: "ruler")
                    shortcutRow(.markers, symbol: "pencil.tip")
                    shortcutRow(.loupe, symbol: "magnifyingglass")
                    shortcutRow(.clearMarkings, symbol: "eraser")
                } header: {
                    HStack {
                        Text("Keyboard shortcuts")
                        Spacer()
                        Button("Restore Defaults") { shortcuts.restoreDefaults() }
                            .buttonStyle(.link)
                            .font(.body)
                    }
                } footer: {
                    if let error = shortcuts.error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text(shortcuts.recording == nil
                             ? "Click a shortcut to record. These work from any app."
                             : "Press a key combination, or Escape to cancel.")
                    }
                }

                Section("Tool gestures") {
                    referenceRow("Rotate ruler or marker") {
                        keycap("⌥")
                        Text("while dragging")
                    }
                    referenceRow("Snap rotation") {
                        keycap("⇧")
                        Text("while rotating")
                    }
                    referenceRow("Resize ruler") { Text("Drag either end") }
                    referenceRow("Zoom loupe") { Text("Turn the dial") }
                    referenceRow("Start or stop drawing") { Text("Click marker tip") }
                }

                Section("While drawing") {
                    HStack {
                        drawingCommand("Stop drawing", keys: ["Esc"])
                        Spacer()
                        drawingCommand("Undo stroke", keys: ["⌘", "Z"])
                        Spacer()
                        drawingCommand("Redo stroke", keys: ["⇧", "⌘", "Z"])
                    }
                    .padding(.vertical, 2)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Shortcuts", systemImage: "command") }.tag(1)
        }
        .frame(width: 540)
        .onChange(of: window.tab) { _, _ in
            shortcuts.endRecording()
            window.resizeForTab()
        }
    }

    private func shortcutRow(_ tool: ShortcutTool, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(tool.title)
            Spacer()
            ZStack(alignment: .trailing) {
                Button {
                    if shortcuts.recording == tool { shortcuts.endRecording() }
                    else { shortcuts.beginRecording(tool) }
                } label: {
                    Text(shortcuts.recording == tool ? "Press keys…" : shortcuts.shortcut(for: tool)?.label ?? "Record shortcut")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(shortcuts.recording == tool ? Color.accentColor : Color.primary)
                        .frame(width: 92)
                        .padding(.horizontal, 24)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Shortcut for \(tool.title)")
                .accessibilityValue(shortcuts.shortcut(for: tool)?.label ?? "Not assigned")

                Button { shortcuts.assign(nil, to: tool) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(shortcuts.shortcut(for: tool) == nil)
                .accessibilityLabel("Clear shortcut for \(tool.title)")
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(shortcuts.recording == tool ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .padding(.vertical, 2)
    }

    private func referenceRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 16)
            HStack(spacing: 4, content: content)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 23)
    }

    private func drawingCommand(_ title: String, keys: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { keycap($0) }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 5)
            .frame(minWidth: 22, minHeight: 22)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 0.5)
            }
    }
}
