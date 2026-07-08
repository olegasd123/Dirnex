import AppKit
import DirnexCore

/// Translates the registry's headless `CommandShortcut` into the two AppKit pieces an
/// `NSMenuItem` needs: a key-equivalent string and a modifier mask. Keeping this app-side
/// lets `DirnexCore` stay AppKit-free while the menu bar is still generated from the registry.
extension CommandShortcut {
    /// The `NSMenuItem.keyEquivalent` string — a function-key or arrow scalar for named keys,
    /// otherwise the literal character (lower-cased letters; punctuation as-is). Shift lives
    /// in the modifier mask, so the character itself is never upper-cased here.
    var keyEquivalent: String {
        if let scalar = Self.functionKeyScalar(key) ?? Self.arrowScalar(key) {
            return String(scalar)
        }
        return key.lowercased()
    }

    /// The AppKit modifier flags for this shortcut. `.function` maps to `.function` so the
    /// F-keys and arrow shortcuts match the mask the hand-built menu used before the registry.
    var modifierMask: NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        if modifiers.contains(.function) { mask.insert(.function) }
        return mask
    }

    /// Map "F1"…"F35" onto the contiguous private-use scalars AppKit reserves for them
    /// (`NSF1FunctionKey` = 0xF704). `nil` for any non-"F<number>" token.
    private static func functionKeyScalar(_ key: String) -> UnicodeScalar? {
        guard key.hasPrefix("F"), let number = Int(key.dropFirst()), (1...35).contains(number) else {
            return nil
        }
        return UnicodeScalar(NSF1FunctionKey + number - 1)
    }

    /// Map the arrow glyphs onto their function-key scalars (only ↑ is used today, for ⌘↑
    /// "Go Up", but the four are handled for completeness).
    private static func arrowScalar(_ key: String) -> UnicodeScalar? {
        switch key {
        case "↑": return UnicodeScalar(NSUpArrowFunctionKey)
        case "↓": return UnicodeScalar(NSDownArrowFunctionKey)
        case "←": return UnicodeScalar(NSLeftArrowFunctionKey)
        case "→": return UnicodeScalar(NSRightArrowFunctionKey)
        default: return nil
        }
    }
}
