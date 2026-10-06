import Foundation

/// Decides what a number-row chord addresses, before the search field eats it.
/// Pure so the harness covers the whole matrix without AppKit.
enum PaletteDigitAction: Equatable {
    /// Select the Nth row (0-based); past the row count it is a no-op downstream.
    case row(Int)
    /// The Nth favorite/pinned slot, now one modifier over.
    case favoriteSlot(Int)

    static func resolve(
        keyCode: UInt16, commandOnly: Bool, commandOption: Bool, mode: PaletteMode
    ) -> Self? {
        guard let slot = FavoriteSlots.index(forKeyCode: keyCode) else { return nil }
        if commandOption, mode == .launcher || mode == .clipboard {
            return .favoriteSlot(slot)
        }
        guard commandOnly, mode.answersRowDigits else { return nil }
        return .row(slot)
    }
}
