# Gom – Move downloaded files to the Trash

Date: 2026-10-08 · Status: implemented

## 1. Goal

Let the user get rid of downloaded files from inside Gom, safely and in bulk:

1. Deleting a finished download's file moves it to the Trash instead of erasing it.
2. A finished row has a visible "Move to Trash" button.
3. Several rows can be selected and removed at once, with right-click → Move to Trash or ⌫.

**Out of scope:** a confirmation dialog (the Trash is the undo), emptying the Trash, deleting files Gom didn't download.

## 2. Design

### Core

- `DownloadQueue.remove(_:deleteFile:)` uses `FileManager.trashItem(at:resultingItemURL:)` instead of `removeItem` for a finished file. Errors are ignored as before (e.g. the user already moved or deleted the file); the row is removed either way.
- Temp files of unfinished downloads are still deleted outright; they are no use to the user.

### Row

- The context menu item "Remove and Delete File" becomes "Move to Trash".
- Finished rows get a `trash` icon button "Move to Trash" after "Show in Finder". The `xmark` "Remove" button stays and only removes the row from the list.

### Multi-select

- The downloads `List` binds a `Set<UUID>` selection, so click, ⌘-click and ⇧-click select rows.
- The context menu and double-click live on the `List` via `contextMenu(forSelectionType:menu:primaryAction:)` instead of on each row. A per-row `.contextMenu` only knows its own row, so "Move to Trash" removed one row even with several selected. Right-clicking inside the selection now acts on all selected rows; right-clicking another row acts on that row only. Open, Remove from List and Move to Trash work on many rows; Start Now / Start in Schedule only show for a single unfinished row.
- ⌫ (`onDeleteCommand`, also Edit › Delete) acts on the selection: finished rows are removed with their file moved to the Trash; unfinished rows are cancelled and removed (their temp file is deleted, same as "Remove"). ⌫ replaces the ⌘⌫ first planned: `onDeleteCommand` is SwiftUI's own list delete hook, and the `onKeyPress` handler for ⌘⌫ was dropped before the focus fix below, so it was never shown to work.
- Clicking a row selects it but leaves the window, not the list, as first responder, so ⌫ never reached `onDeleteCommand`. A `@FocusState` on the list is set whenever the selection becomes non-empty.
- Selected ids no longer in `queue.items` are ignored by `remove`, so the selection needs no pruning.

## 3. Testing

Unit (`DownloadQueueTests`): a finished download removed with `deleteFile: true` is gone from its folder and present in the Trash; the test removes it from the Trash afterwards.

Manual, debug build:

1. Trash button on a finished row → row gone, file in `~/.Trash` (driven with cua-driver).
2. Right-click a finished row → "Move to Trash" → same result.
3. Select two finished rows with ⌘-click, right-click → Move to Trash → both rows gone, both files in the Trash.
4. Select a finished row, press ⌫ → row gone, file in the Trash; a debug log showed the list as first responder and `onDeleteCommand` firing.
5. Double-click on a finished row still opens the file.

Steps 2–5 were checked by hand: cua-driver could not deliver ⌘-click or ⌫ to the list reliably.
