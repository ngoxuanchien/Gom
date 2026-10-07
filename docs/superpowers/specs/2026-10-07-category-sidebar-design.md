# Gom – Category sidebar and save-panel folder

Date: 2026-10-07 · Status: implemented

## 1. Goal

- Filter the download list by file type from a sidebar, IDM-style.
- Browser downloads always offer the file's category folder inside the download folder, even when the URL has no extension. Whatever folder the user picks is final.

Builds on [download folders](2026-10-06-download-folders-design.md).

## 2. Sidebar

```
All          26
Folders
  Documents  12
  Compressed  1
  Music
  Video
  Programs
  Images
  Other      13
```

- `ContentView` is a `NavigationSplitView`. The sidebar lists **All**, one row per folder in Settings → Folders by File Type (same order, blanks and duplicates skipped), and **Other**. Each row shows a count.
- A download's group is `categoryFolder(of:in:)`: the filename, or before it is known the URL's last path component; a video page counts as `.mp4` (`.m4a` for audio only). No match → Other.
- Grouping uses the category list even when "Sort into folders" is off; it only filters the view.
- The selection is kept per window (`@SceneStorage("category")`). It switches back to All when a download is added, so the new row is never hidden behind a filter.
- An empty filter shows "Nothing Here".

## 3. Save panel for browser downloads

| Situation | Panel opens in |
|---|---|
| Chrome sent a filename | Its category folder |
| No filename, sorting on | Gom probes the server (`Range: bytes=0-0`, same as the engine) for the Content-Disposition name, waiting at most 5 s, then opens in that name's category folder |
| Probe failed or timed out | The download folder |

After the panel:

- Any folder the user picks is used as is.
- Picking the download folder itself (only possible when the name is still unknown, or by navigating there) still passes the categories, so the engine sorts the file once the server names it.

## 4. Code

- `GomCore/FileNaming.swift`: `categoryFolder(of: DownloadRecord, in:)`.
- `GomCore/DownloadEngine.swift`: `serverFilename(url:headers:streamer:)`; `DownloadQueue.serverFilename(for:headers:)` uses the queue's streamer.
- `App/GomApp.swift`: probe with a 5 s timeout before `chooseFolder`; categories when saving to the download folder.
- `App/ContentView.swift`: sidebar and filtered list.

## 5. Tests

- `FileNamingTests.categoryFolderOfRecordFallsBackToURLAndVideo`.
- `DownloadEngineTests.serverFilenameReadsContentDisposition` (name from Content-Disposition, nil on 404).
- By hand (debug build, cua-driver): sidebar counts and filtering; a URL without an extension whose server sends `filename="….pdf"` opens the panel in `Downloads/Documents` and saves there; choosing Desktop saves to Desktop.
