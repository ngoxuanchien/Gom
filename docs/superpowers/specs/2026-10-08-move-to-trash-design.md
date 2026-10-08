# Gom – Move downloaded files to the Trash

Date: 2026-10-08 · Status: draft

## 1. Goal

Let the user get rid of downloaded files from inside Gom, safely and in bulk:

1. Deleting a finished download's file moves it to the Trash instead of erasing it.
2. A finished row has a visible "Move to Trash" button.
3. Several rows can be selected and removed at once with ⌘⌫.

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
- ⌘⌫ acts on the selection: finished rows are removed with their file moved to the Trash; unfinished rows are cancelled and removed (their temp file is deleted, same as "Remove").
- If enabling selection breaks the row's double-click-to-open gesture, double-click moves to `contextMenu(forSelectionType:primaryAction:)`, and the context menu then applies to every selected row.
- Selected ids no longer in `queue.items` are ignored by `remove`, so the selection needs no pruning.

## 3. Testing

Unit (`DownloadQueueTests`): a finished download removed with `deleteFile: true` is gone from its folder and present in the Trash; the test removes it from the Trash afterwards.

Manual, debug build driven with cua-driver:

1. Right-click a finished row → "Move to Trash" → row gone, file in `~/.Trash`.
2. Trash button on a finished row → same result.
3. ⌘-click two finished rows and one paused row, press ⌘⌫ → all three rows gone, both files in the Trash, paused temp file deleted.
4. Double-click on a finished row still opens the file.
