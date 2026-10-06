import Carbon.HIToolbox
import Foundation

/// Alfred records a chord as a Carbon key code plus a raw `CGEventFlags` value; `-1` means unset.
/// See docs/features/alfred-import.md.
enum AlfredHotkeyImport {
    /// Alfred's `mod` is `CGEventFlags`, whose bits sit eight above the Carbon ones.
    private static let modifierMap: [(flag: Int, carbon: Int)] = [
        (1 << 17, shiftKey), (1 << 18, controlKey), (1 << 19, optionKey), (1 << 20, cmdKey),
        (1 << 23, kEventKeyModifierFnMask)
    ]

    /// Alfred's `{key, mod, string}` dict; the string is a layout-dependent glyph and unused.
    static func binding(_ value: Any?) -> HotKeyBinding? {
        guard let hotkey = value as? [String: Any],
            let keyCode = hotkey["key"] as? Int,
            let modifiers = hotkey["mod"] as? Int
        else { return nil }
        return binding(keyCode: keyCode, modifiers: modifiers)
    }

    /// Alfred records a bare key where a chord is needed; ours refuses one, bar the function keys.
    static func binding(keyCode: Int, modifiers: Int) -> HotKeyBinding? {
        guard keyCode >= 0 else { return nil }
        var carbon = 0
        for entry in modifierMap where modifiers & entry.flag != 0 { carbon |= entry.carbon }
        guard carbon != 0 || KeyShortcut.isFunctionKey(keyCode) else { return nil }
        return .combo(KeyShortcut(carbonKeyCode: keyCode, carbonModifiers: carbon))
    }
}
