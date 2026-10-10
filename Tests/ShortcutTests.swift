import AppKit
import Carbon
import SwiftUI

@main
struct ShortcutTests {
    @MainActor static func main() {
        let suite = "PencilCase.ShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcuts = ToolShortcuts(defaults: defaults, registersHotKeys: false)
        assert(shortcuts.shortcut(for: .ruler)?.label == "⇧⌘R")
        assert(shortcuts.shortcut(for: .markers)?.label == "⇧⌘M")
        assert(shortcuts.shortcut(for: .loupe)?.label == "⇧⌘L")

        assert(shortcuts.shortcut(for: .clearMarkings) == nil)

        shortcuts.beginRecording(.ruler)
        assert(!shortcuts.assign(ShortcutTool.markers.defaultShortcut, to: .ruler))
        assert(shortcuts.recording == .ruler)
        assert(shortcuts.shortcut(for: .ruler) == ShortcutTool.ruler.defaultShortcut)
        shortcuts.endRecording()
        assert(shortcuts.recording == nil)

        let undo = ToolShortcut(keyCode: 6, modifiers: UInt32(cmdKey), character: "z")
        let redo = ToolShortcut(keyCode: 6, modifiers: UInt32(cmdKey | shiftKey), character: "z")
        assert(!shortcuts.assign(undo, to: .ruler))
        assert(!shortcuts.assign(redo, to: .ruler))
        assert(!shortcuts.assign(ToolShortcut(keyCode: 0, modifiers: 0, character: "a"), to: .ruler))

        let custom = ToolShortcut(keyCode: 0, modifiers: UInt32(controlKey | optionKey), character: "a")
        assert(shortcuts.assign(custom, to: .ruler))
        assert(shortcuts.shortcut(for: .ruler)?.label == "⌃⌥A")
        assert(shortcuts.assign(nil, to: .loupe))
        let reloaded = ToolShortcuts(defaults: defaults, registersHotKeys: false)
        assert(reloaded.shortcut(for: .ruler) == custom)
        assert(reloaded.shortcut(for: .loupe) == nil)
        assert(reloaded.shortcut(for: .markers) == ShortcutTool.markers.defaultShortcut)
        let clear = ToolShortcut(keyCode: 8, modifiers: UInt32(controlKey | optionKey), character: "c")
        assert(!reloaded.assign(custom, to: .clearMarkings))
        assert(reloaded.assign(clear, to: .clearMarkings))
        let withClear = ToolShortcuts(defaults: defaults, registersHotKeys: false)
        assert(withClear.shortcut(for: .clearMarkings) == clear)
        assert(withClear.shortcut(for: .clearMarkings)?.menuShortcut.key == KeyEquivalent("c"))
        reloaded.restoreDefaults()
        let restored = ToolShortcuts(defaults: defaults, registersHotKeys: false)
        for tool in ShortcutTool.allCases { assert(restored.shortcut(for: tool) == tool.defaultShortcut) }
        print("Shortcut defaults, conflicts, reserved commands, recording cancellation, persistence, clearing, and reset passed.")
    }
}
