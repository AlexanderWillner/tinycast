import Foundation

/// The number-row matrix: which chord addresses what, in which mode, without AppKit.
@main
@MainActor
struct PaletteDigitTests {
    static var failures = 0
    static var passes = 0

    /// ANSI key codes of the physical number row in visual order 1…9,0.
    static let keyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]

    static func resolve(
        _ position: Int, commandOnly: Bool = false, commandOption: Bool = false,
        mode: PaletteMode = .launcher
    ) -> PaletteDigitAction? {
        PaletteDigitAction.resolve(
            keyCode: keyCodes[position], commandOnly: commandOnly, commandOption: commandOption,
            mode: mode)
    }

    static func main() {
        expect(
            resolve(0, commandOnly: true) == .row(0),
            "bare ⌘1 selects the first row in the launcher")
        expect(
            resolve(9, commandOnly: true) == .row(9),
            "bare ⌘0 selects the tenth row")
        expect(
            PaletteDigitAction.resolve(
                keyCode: 0, commandOnly: true, commandOption: false, mode: .launcher) == nil,
            "a non-number key resolves to nothing")
        expect(
            resolve(0) == nil,
            "a digit without ⌘ stays with the search field")
        expect(
            resolve(0, commandOnly: true, commandOption: true) == .favoriteSlot(0),
            "the slot wins when both flags are set")

        expect(
            resolve(0, commandOption: true) == .favoriteSlot(0),
            "⌥⌘1 keeps the first favorite slot in the launcher")
        expect(
            resolve(3, commandOption: true, mode: .clipboard) == .favoriteSlot(3),
            "⌥⌘4 keeps the fourth pinned slot in the clipboard")
        expect(
            resolve(0, commandOption: true, mode: .fileSearch) == nil,
            "⌥⌘ digits answer nowhere outside launcher and clipboard")
        expect(
            resolve(0, commandOnly: true, mode: .clipboard) == .row(0),
            "bare ⌘1 selects the first row in the clipboard too")

        expect(
            resolve(0, commandOnly: true, mode: .emoji) == nil,
            "⌘1 stays a grid key in emoji mode")
        expect(
            resolve(9, commandOnly: true, mode: .emoji) == nil,
            "⌘0 stays the zoom reset in emoji mode")
        expect(
            resolve(0, commandOnly: true, mode: .extensionCommand) == nil,
            "third-party code keeps its own ⌘1")
        expect(
            resolve(0, commandOption: true, mode: .emoji) == nil,
            "⌥⌘ digits answer nowhere in emoji mode")
        expect(
            resolve(0, commandOnly: true, mode: .fileSearch) == .row(0),
            "every other list mode answers row digits")

        expect(
            PaletteMode.emoji.answersRowDigits == false
                && PaletteMode.extensionCommand.answersRowDigits == false,
            "exactly emoji and extensions opt out")
        expect(
            PaletteMode.launcher.answersRowDigits && PaletteMode.clipboard.answersRowDigits
                && PaletteMode.quicklinks.answersRowDigits,
            "launcher, clipboard and the other lists answer")

        print("\(passes)/\(passes + failures) passed")
        if failures > 0 { exit(1) }
    }

    static func expect(_ condition: Bool, _ label: String) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(label)")
        }
    }
}
