# RFC 0001: Address a row by digit

Status: implemented. The feature docs above already carry the change.

## Problem

Selecting the fifth result costs four presses of ↓ or a narrowing query. Alfred and Raycast answer
this with ⌘1…⌘9: the digit addresses the row, ⏎ runs it. In Tinycast the number row already means
something else, in exactly the two screens where the habit matters most: in the launcher a Command
digit launches the Nth favorite, in the clipboard history it activates the Nth pinned entry. The
interception happens in one place (`PaletteWindowController.swift:414`), keyed off the physical
number row through `FavoriteSlots.index(forKeyCode:)` so the positions survive QWERTY and AZERTY
alike, and reaches the screens as a `favoriteSlot` token (`PaletteState.swift:185`,
`RootPaletteView.swift:445`). The launcher consumes it in `launchFavorite(at:)`
(`LauncherScreen.swift:305`), the clipboard in `activatePinned(at:)` (`ClipboardScreen.swift:48`).

There is no third reading of ⌘1…⌘9 that keeps both. This RFC moves the digits to the rows and moves
the fixed slots one modifier over.

## Decision

- ⌘1…⌘9 and ⌘0 select the Nth row of the screen's own row list: the same order ↑/↓ walks, where
  section headers take no index. Selecting is all a digit does; ⏎ stays the single way to run the
  selection, ⌘⏎ stays the secondary action, ⌃⌘↵ the tertiary one.
- A digit names an absolute list index, never a screen position: after scrolling, ⌘5 still means
  the fifth result. The palette's follow-scroll already pulls the moved highlight into view
  (`RootPaletteView.swift:361`), so no screen work is needed to keep the row visible.
- A digit past the row count is a no-op. It must not clamp to the last row: a silent last row
  behind an intended ⌘9 is exactly the paste-the-wrong-clip failure this chord exists to avoid.
- Favorites (launcher) and pinned entries (clipboard) keep their ten slots on ⌥⌘1…⌥⌘0. The tooltips
  in the compact favorites strip change with them (`CompactFavoritesRow.swift:40`).
- The chord works in every list mode. Two modes opt out: `emoji` keeps ⌘0 as the grid-zoom reset,
  which is checked before anything else (`PaletteWindowController.swift:409`, `:124`), and
  `extensionCommand` keeps its digits for the third-party code it renders. The compact bar and an
  empty list answer with a no-op, through the existing `requiresExpanded` gate
  (`RootPaletteView.swift:614`).

## Visibility

A hidden chord is a dead chord. Holding ⌘ already reveals chord numbers on the rows that answer to
them after a 400 ms hold (`PaletteState.swift:164`), and the same reveal carries the new meaning:
while ⌘ is held, the rows show `⌘N` for the Nth row. The favorite chips on rows
(`LauncherList.swift:307`, `ClipboardView.swift:155`) become `⌥⌘N` and appear while ⌥ alone is
held, symmetric to the existing `flagsChanged` path (`PalettePanel.swift:169`). `KeyCapChip` keeps
its established grammar: `.outline` for hints on rows, `.filled` for the footer (`docs/ui.md:409`).

## Why the palette owns it

The interception has to live in AppKit: the search field's editor eats ⌘ digits before SwiftUI's
`onKeyPress` ever sees them, which is why digits arrive as a key-code token today
(`docs/features/palette.md:499`). That same fact is why an extension screen cannot keep ⌘1 for
itself once the palette claims the number row — hence the opt-out above instead of a second
mechanism. A per-screen implementation would also drift: the whole point is that the digit means
the same thing on every list.

## Implementation sketch

- New pure file `Tinycast/Palette/PaletteDigitAction.swift`, Foundation only:
  `resolve(keyCode:modifiers:mode:)` returning `.row(Int)` or `.favoriteSlot(Int)`. It absorbs the
  inline `FavoriteSlots.index(forKeyCode:)` call at `PaletteWindowController.swift:414` and the
  mode gate, following the precedent of `PaletteTabAction` (`Palette/PaletteTabAction.swift`), which
  the harnesses already compile standalone.
- `PaletteMode` gains `answersRowDigits`, false for `emoji` and `extensionCommand`.
- `FavoriteSlots` keeps its key-code table and its `digit(at:)` labels; only the chord the slots
  answer to changes from ⌘ to ⌥⌘.
- `PaletteState` gains `noteDigit(_:)` with a `digitToken`, consumed by one `.onChange` in
  `RootPaletteView`: `.row` clamps into `screen.rows` and sets `vm.selection`, `.favoriteSlot`
  keeps flowing through `performShortcut(.favoriteSlot(index))`.
- No new `PaletteShortcut` case. A digit names a row; a shortcut names something done to the
  selection. Mixing the two would blur the one grammar the palette has.

## Rejected alternatives

- Favorites keep ⌘1…⌘0, rows take ⌥⌘1…⌥⌘9. No migration cost, but no Alfred parity either, and the
  `⌘N` chips in the favorites strip would then advertise a chord that addresses something else.
- Rows take ⌘1…⌘9, favorites lose their digits entirely. The most consistent reading of ⌘, but it
  drops a genuinely fast path — launching favorite three with no typing — that the ⌥⌘ move keeps.
- Digits address only screens without their own slots. Two meanings for one chord depending on the
  screen, which contradicts the chord grammar the palette has kept everywhere else.
- Typing the digit into the query, or a select-and-run chord. The first collides with search text;
  the second collides with the select-then-confirm rhythm every other chord follows.

## Costs and risks

- Muscle memory: favorites and pins move one modifier over. This needs one line in the release
  notes and must not be snuck into an unrelated change.
- A row can carry two chip identities, `⌘N` and `⌥⌘N`, revealed by different holds. The ⌥ reveal
  is new state alongside `commandHeld`.
- A global hotkey on ⌘1 keeps firing: Carbon registration is independent of the palette, so a user
  who bound ⌘1 in-app will see both until they rebind one side.
- Only ten rows are addressable; ⌘0 is the tenth, not a repeat of the first.

## Docs the follow-up changes

This RFC changes none of them. When the implementation lands, it rewrites `launcher.md`
§"⌘-digit slots" (`:687`), the pinned-slots paragraph in `clipboard.md` (`:365`), `palette.md`
§"Chords `onKeyPress` never sees" (`:499`), and the KeyCapChip grammar in `ui.md` (`:409`) only if
the ⌥ reveal alters it.

## Test plan

- New `palette-digit-test` harness compiling the pure `PaletteDigitAction` sources, registered as
  one `run` line in `Scripts/run-tests.sh` next to `palette-tab-test`.
- `palette-shortcut-test`, `favorites-test` and `palette-selection-test` gain cases; none lose any.
- Manual sweep: launcher, clipboard, file search, emoji (⌘0 must still reset the zoom), an
  extension command claiming ⌘1, compact mode, and the physical number row on a non-QWERTY layout.

## Non-goals

- No new preference, so no `SettingsFileKey` and no `SettingsFileSchema` binding, and no switch
  back to the old layout. Ten keys are not worth a settings pane.
- No per-screen digit customization and no digits while a control's own list is open
  (`isControlListOpen`).

## Open items

- Digit past the row count: no-op (proposed) or clamp to the last row. Proposed no-op, for the
  wrong-clip reason above.
- Favorite chips on rows: ⌥-hold reveal (proposed) or removed in favor of the compact strip and
  the ⌘K menu. Proposed the reveal, because the strip shows only the first five.
