# Gom – Phase 1: Queue + multi-connection HTTP downloads + Chrome download capture

Date: 2026-10-06 · Status: awaiting review

## 1. Goals

A macOS download app for personal use (not distributed yet). Roadmap in 3 phases:

1. **Phase 1 (this spec):** download queue, multi-connection HTTP downloads with pause/resume, and a Chrome extension that automatically intercepts downloads.
2. Phase 2: video downloads via `yt-dlp`, sharing the same queue.
3. Phase 3: scheduled downloads and automatic sorting of files by type.

**Phase 1 is done when:** all Swift tests pass; the manual extension checklist (section 7) passes; a ~1GB ISO downloaded through Gom has the same checksum as the one Chrome downloads.

**Out of scope for phase 1:** yt-dlp, scheduling, sorting by type, menu bar icon, dynamic segment re-splitting, bandwidth limiting, configurable segment count in the UI, Safari/Firefox, code signing/notarization.

## 2. Technology

- Swift 6, SwiftUI, deployment target macOS 27, Xcode 27.
- Only Foundation, SwiftUI and Network.framework. No external dependencies.
- Chrome extension on Manifest V3 (works in Chrome/Arc/Brave/Edge), installed with "Load unpacked".

Repo layout:

```
Gom/          Xcode project (app + test target)
extension/    manifest.json, background.js, options.html, options.js, README.md
docs/
```

## 3. Architecture

```
Extension ──POST 127.0.0.1:47615/add──▶ BridgeServer ─┐
                                                      ├─▶ DownloadQueue ─▶ DownloadTask (one per file)
Paste field / drag-and-drop ──────────────────────────┘          │
                                                                 ▼
                                                    SwiftUI UI (@Observable)
```

| Component | Responsibility | Depends on |
|---|---|---|
| `DownloadTask` | Downloads one URL to one file: probe, segmenting, pause/resume, retry | URLSession, FileHandle |
| `DownloadQueue` | Holds the download list, limits concurrency, saves and restores state | DownloadTask, Codable |
| `BridgeServer` | Receives requests from the extension, authenticates them, pushes them into the queue | Network.framework |
| UI | Download list, paste field, settings | DownloadQueue |
| Extension | Intercepts Chrome downloads and hands them to Gom; if Gom fails, gives them back to Chrome | chrome.downloads, chrome.cookies |

## 4. Download engine (`DownloadTask`)

**Probe.** Send a `GET` with `Range: bytes=0-0`, plus cookie/Referer/User-Agent when provided.
- `206` with `Content-Range: bytes 0-0/<total>` means the server supports ranges, and gives the size.
- `200`, or an unknown size, means a single-connection download that cannot resume. Pausing stops it completely and the next start begins from zero; the UI states this explicitly.
- File name, in order of preference: name sent by the extension → `Content-Disposition` → last path component of the URL.
- Store the `ETag` (or `Last-Modified` if there is no ETag) to validate the file on resume.

**Segmenting.**
- 8 segments by default (a constant). Files under 2MB use 1 segment. Segments cover exactly `[0, total)` with no overlaps and no gaps.
- Write into a temp file `<name>.gomdownload` in the destination folder. Each segment has its own `FileHandle` and writes at its own offset.
- Each segment is one request with `Range: bytes=<start+done>-<end>`. Data arrives in chunks through `URLSessionDataDelegate`. `URLSession.bytes` is not used because it yields one byte at a time, which is slow.
- When complete, rename the temp file to the real name. On a name collision, append ` (1)`, ` (2)`… like Finder.

**Pause / resume.**
- Per-segment progress `{start, end, done}` is saved about every 2 seconds and immediately on pause.
- On resume, each segment requests from where it stopped with `If-Range: <ETag|Last-Modified>`. A `200` instead of `206` means the file changed: delete the temp file and start over.
- On app quit, active downloads are saved as `paused` and resume automatically on the next launch.

**Errors.**
- Each segment retries up to 5 times with waits of 1s, 2s, 4s, 8s, 16s. When retries run out, the whole download becomes `failed(reason)` with a "Retry" button.
- `401`/`403` fail immediately with no retry.

## 5. Queue, persistence, UI

**`DownloadQueue`** (`@Observable`, `@MainActor`, a single instance).
- States: `queued | downloading | paused | completed | failed(String)`.
- At most 3 downloads in `downloading` at once. When a slot frees up, the oldest `queued` item starts.
- Actions: add, pause, resume, retry, remove from list, remove with file.
- Adding a URL that is already in the queue and not `completed` is ignored, and the existing item is highlighted.

**Persistence.** File `~/Library/Application Support/Gom/downloads.json`, using `Codable`, written atomically.
- Each record holds: `id, url, headers, filename, directory, totalBytes, etag, segments, state, addedAt`.
- Cookies are stored in plain text. Acceptable because only the user uses this machine; move them to the Keychain if the app is ever distributed.
- When a download becomes `completed`, its `headers` are removed from the record.

**UI.**
- One window: a multi-line paste field with an Add button, the download list (name, progress bar, %, speed, ⏸/▶/↻/✕/📂 buttons), and drag-and-drop of URLs onto the list.
- Double-click a finished download to open the file; 📂 reveals the file in Finder.
- macOS notification when a download finishes.
- Settings: download folder (default `~/Downloads`), port (default 47615), token (with a copy button).

## 6. BridgeServer and extension

**BridgeServer.**
- `NWListener` listening on `127.0.0.1` only. Minimal HTTP/1.1 parser: request line, headers, body by `Content-Length`.
- `GET /ping` returns `{"ok":true,"app":"Gom"}`.
- `POST /add` accepts `{url, filename?, referrer?, cookies?, userAgent?}` and returns `{"ok":true}`.
- Authentication: `Origin` must start with `chrome-extension://` **and** `X-Gom-Token` must match. Otherwise return `401`.
  - Token: 32 random bytes as hex, generated on first launch, stored in `UserDefaults`.
- No CORS headers are sent. `OPTIONS` returns `403`, so web pages cannot send custom headers.
- Requests over 1MB or with invalid JSON return `400`.

**Extension.**
- Permissions: `downloads`, `cookies`, `storage`; `host_permissions: ["<all_urls>"]`.
- Handling `downloads.onCreated(item)`:
  1. Skip (let Chrome download it) if the extension is disabled, the URL is `blob:`/`data:`, or the size is known and below the threshold (default 5MB).
  2. `chrome.downloads.pause(item.id)`.
  3. Get cookies with `chrome.cookies.getAll({url})` and join them as `name=value; …`. Add `item.referrer` and `navigator.userAgent`.
  4. Send `POST /add` with a 2s timeout (using `AbortController`).
  5. On success, `cancel` then `erase`. On error or timeout, `resume`.
- Options page: on/off toggle, port, token, MB threshold, and a "Test connection" button (calls `/ping`).

**Known limitations.**
- Downloads created by a form POST will break because Gom re-requests them with GET. Temporarily disable the extension on those sites.
- If Chrome's "Ask where to save each file" is enabled, the save dialog may appear before the extension intercepts. Recommend turning that option off.
- Very small files may finish before `pause` takes effect. The 5MB threshold covers this.

## 7. Testing

**Swift Testing.** A fake `URLProtocol` serves an in-memory `Data`. It supports `Range`/`If-Range` and can be configured to: fail the first N requests, return 403, change the ETag.

- Segmenting: covers exactly `[0,total)`; files under 2MB get 1 segment.
- Probe: `206` → segmented, `200` → single connection.
- Full download: SHA256 matches the source data.
- Pause at ~40% then resume: SHA256 matches, and the resume request's `Range` starts exactly where it stopped.
- ETag changed: restarts from zero, SHA256 matches the new data.
- 2 failures then success → `completed`; `403` → `failed` immediately.
- Queue: adding 5 items runs only 3 at once; duplicate URLs are ignored.
- Persistence: write then read back matches; `completed` records contain no cookies.
- HTTP parser: parses a valid request correctly; requests over 1MB are rejected.
- BridgeServer running for real on a random port on `127.0.0.1`: missing token or wrong Origin → 401; `OPTIONS` → 403; a valid request adds the item to the queue.

**Manual extension checklist** (in `extension/README.md`):

1. Download a large ISO → Gom receives it, and it disappears from Chrome's download list.
2. Quit Gom, download a large file → Chrome continues downloading it.
3. A 1MB file → Chrome downloads it, Gom does not interfere.
4. A file that requires login (Google Drive) → Gom downloads it using the cookies.
5. Wrong token → "Test connection" reports an error.
