# Gom – Sorting downloads into folders by file type

Date: 2026-10-06 · Status: implemented

## 1. Goal

Keep the download folder tidy: every download lands in a subfolder chosen by its file extension, IDM-style. The folder tree and the extensions are editable in Settings.

**Out of scope:** moving files that were already downloaded, matching on MIME type, nested subfolders, per-site rules.

## 2. Default folder tree

```
<download folder>/
├── Documents   pdf doc docx xls xlsx ppt pptx odt ods odp rtf txt csv md epub pages numbers key
├── Compressed  zip rar 7z tar gz tgz bz2 xz zst
├── Music       mp3 m4a aac flac wav ogg opus
├── Video       mp4 mkv mov avi webm m4v flv wmv
├── Programs    dmg pkg exe msi deb rpm apk iso
├── Images      jpg jpeg png gif webp heic svg bmp tiff
└── (anything else stays at the top)
```

Folders are created only when a file first needs them.

## 3. Behaviour

| Where the download comes from | What happens |
|---|---|
| Pasted or dropped link | Queued with the download folder plus the category list. The engine sorts the file once the name is known, so a name that only comes from `Content-Disposition` (e.g. `download.php?id=…`) is sorted too. |
| Browser extension | The "Save Here" panel opens in the file's category folder (created if needed). The folder the user picks is final. |
| Sorting turned off | Everything goes to the download folder, as before. |

Rules:

- The match uses the last extension, case-insensitive (`backup.tar.GZ` → Compressed).
- If several categories list the same extension, the first one wins.
- A category with a blank folder name sorts nothing.
- Folder names go through `sanitizeFilename`, so `../x` becomes `x` and files never leave the download folder.
- Sorting happens once: the engine clears `DownloadRecord.categories` after applying it, so a restart or retry keeps the same folder.

## 4. Settings

- **Downloads → Sort into folders by file type**: on by default (`sortByType` in UserDefaults).
- **Folders by File Type**: one row per category (folder name and extensions separated by spaces or commas, a leading dot is fine), plus **Add Folder**, a remove button per row, and **Restore Defaults**. The section is disabled while sorting is off.
- Categories are stored as JSON under the `fileCategories` UserDefaults key and fall back to the defaults when the key is missing or can't be decoded.

## 5. Code

- `GomCore/FileNaming.swift`: `FileCategory`, `defaultFileCategories`, `categoryFolder(for:in:)`.
- `DownloadRecord.categories` (optional, so saved queues from older versions still decode).
- `DownloadEngine.prepare`: appends the category folder to `directory` right after the filename is resolved.
- `DownloadQueue.add(…, categories:)`.
- App: `AppSettings.sortByType`, `AppSettings.categories`, `AppSettings.directory(for:)`, plus the Settings UI.

## 6. Tests

- `FileNamingTests`: default matching, edited categories (blank folder, leading dots and commas, `../` folder names).
- `DownloadEngineTests.sortsIntoCategoryOnceServerNamesTheFile`: a download of `/report.pdf` ends up in `Documents/` and the record's `categories` is cleared.
- Not covered by automated tests: the Settings UI and the extension panel's starting folder. Check these by hand.
