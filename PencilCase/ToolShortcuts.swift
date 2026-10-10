import AppKit
import Carbon
import Combine
import SwiftUI

enum ShortcutTool: String, CaseIterable, Identifiable, Codable {
    case ruler, markers, loupe, clearMarkings

    var id: String { rawValue }
    var title: String { self == .clearMarkings ? "Clear All Markings" : rawValue.capitalized }
    var hotKeyID: UInt32 { self == .ruler ? 1 : self == .markers ? 2 : self == .loupe ? 6 : 7 }
    var defaultShortcut: ToolShortcut? {
        guard self != .clearMarkings else { return nil }
        return ToolShortcut(keyCode: self == .ruler ? 15 : self == .markers ? 46 : 37,
                     modifiers: UInt32(cmdKey | shiftKey), character: String(rawValue.prefix(1)))
    }
}

struct ToolShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let character: String

    var label: String {
        (modifiers & UInt32(controlKey) != 0 ? "⌃" : "") +
        (modifiers & UInt32(optionKey) != 0 ? "⌥" : "") +
        (modifiers & UInt32(shiftKey) != 0 ? "⇧" : "") +
        (modifiers & UInt32(cmdKey) != 0 ? "⌘" : "") + character.uppercased()
    }

    var menuShortcut: KeyboardShortcut {
        var flags: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return KeyboardShortcut(KeyEquivalent(Character(character)), modifiers: flags)
    }

    static func from(_ event: NSEvent) -> ToolShortcut? {
        guard let text = event.characters(byApplyingModifiers: [])?.lowercased(), text.count == 1,
              let scalar = text.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(scalar) else { return nil }
        var flags: UInt32 = 0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        return ToolShortcut(keyCode: UInt32(event.keyCode), modifiers: flags, character: text)
    }
}

@MainActor
final class ToolShortcuts: ObservableObject {
    static let shared = ToolShortcuts()
    @Published private(set) var values: [String: ToolShortcut]
    @Published var error: String?
    @Published private(set) var recording: ShortcutTool?
    private var references: [ShortcutTool: EventHotKeyRef] = [:]
    private let defaults: UserDefaults
    private let registersHotKeys: Bool
    private var started = false

    init(defaults: UserDefaults = .standard, registersHotKeys: Bool = true) {
        self.defaults = defaults
        self.registersHotKeys = registersHotKeys
        if let data = defaults.data(forKey: "toolShortcuts"),
           let saved = try? JSONDecoder().decode([String: ToolShortcut].self, from: data) {
            values = saved
        } else {
            values = Dictionary(uniqueKeysWithValues: ShortcutTool.allCases.compactMap { tool in tool.defaultShortcut.map { (tool.rawValue, $0) } })
        }
    }

    func shortcut(for tool: ShortcutTool) -> ToolShortcut? { values[tool.rawValue] }

    func start() {
        guard !started else { return }
        started = true
        registerAll()
    }

    func beginRecording(_ tool: ShortcutTool) {
        unregisterAll()
        recording = tool
        error = nil
    }

    func endRecording() {
        guard recording != nil else { return }
        recording = nil
        registerAll()
    }

    func validationError(_ shortcut: ToolShortcut, for tool: ShortcutTool) -> String? {
        guard shortcut.character.count == 1,
              shortcut.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            return "Use a letter or number with Command, Option, or Control."
        }
        let reserved: [(UInt32, UInt32)] = [(6, UInt32(cmdKey)), (6, UInt32(cmdKey | shiftKey)),
            (12, UInt32(cmdKey)), (13, UInt32(cmdKey)), (43, UInt32(cmdKey)),
            (48, UInt32(cmdKey)), (49, UInt32(cmdKey)), (49, UInt32(cmdKey | optionKey))]
        if reserved.contains(where: { $0.0 == shortcut.keyCode && $0.1 == shortcut.modifiers }) {
            return "This shortcut is reserved for a standard macOS or drawing command."
        }
        if let other = ShortcutTool.allCases.first(where: {
            $0 != tool && values[$0.rawValue].map { $0.keyCode == shortcut.keyCode && $0.modifiers == shortcut.modifiers } == true
        }) { return "This shortcut is already used by \(other.title)." }
        return nil
    }

    @discardableResult
    func assign(_ shortcut: ToolShortcut?, to tool: ShortcutTool) -> Bool {
        if let shortcut, let message = validationError(shortcut, for: tool) {
            error = message
            return false
        }
        let previous = values
        unregisterAll()
        values[tool.rawValue] = shortcut
        recording = nil
        error = nil
        if !registerAll() {
            values = previous
            let message = error
            unregisterAll()
            registerAll()
            error = message
            return false
        }
        persist()
        return true
    }

    func restoreDefaults() {
        let previous = values
        unregisterAll()
        recording = nil
        error = nil
        values = Dictionary(uniqueKeysWithValues: ShortcutTool.allCases.compactMap { tool in tool.defaultShortcut.map { (tool.rawValue, $0) } })
        if !registerAll() {
            let message = error
            unregisterAll()
            values = previous
            registerAll()
            error = message
            return
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: "toolShortcuts") }
    }

    private func unregisterAll() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    @discardableResult
    private func registerAll() -> Bool {
        guard registersHotKeys, started else { return true }
        var success = true
        for tool in ShortcutTool.allCases {
            guard let shortcut = values[tool.rawValue], references[tool] == nil else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                EventHotKeyID(signature: 0x50434C52, id: tool.hotKeyID), GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references[tool] = reference }
            else {
                success = false
                error = "\(tool.title): \(shortcut.label) is unavailable. Try another shortcut."
            }
        }
        return success
    }
}
