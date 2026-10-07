# Gom – Video downloads via yt-dlp (phase 2)

Date: 2026-10-07 · Status: implemented

## 1. Goal

Download videos from video pages (YouTube, Vimeo, …) through the same queue as files: progress, speed, pause/resume, remove, notifications and the menu bar all work the same. The user picks a quality (Best / 1080p / 720p / Audio only). Gom drives an installed `yt-dlp` as a subprocess and offers to install it (and `ffmpeg`, plus the optional `deno`) with Homebrew when missing.

**Out of scope:** playlists (one URL = one video), login-only/private videos (no cookies are passed to yt-dlp), bundling or auto-updating yt-dlp, a per-download quality dialog, subtitles/thumbnails/metadata embedding.

## 2. How a video gets into Gom

| Source | Becomes a video download when | Quality | Folder |
|---|---|---|---|
| Pasted / dropped link | host is on the known video-site list (§ 4) | Settings default | category folder of the final file (no dialog) |
| Chrome right-click → **Download video with Gom ▸ Best / 1080p / 720p / Audio only** (on the page or on a link) | always | the submenu item | category folder of the final file (no dialog) |

Links on other hosts keep downloading as files. The right-click menu is the way to send any other site yt-dlp supports.

With "Sort by type" on, video (`mp4`) lands in **Video** and audio-only (`m4a`) in **Music**, by the existing extension rules. With it off, both go to the download folder.

## 3. Quality → yt-dlp arguments

Formats are sorted towards streams macOS plays natively (H.264/AAC in mp4/m4a), never trading away resolution:

| Quality | Arguments |
|---|---|
| Best | `-S res,ext:mp4:m4a --merge-output-format mp4` |
| 1080p | `-S res:1080,ext:mp4:m4a --merge-output-format mp4` |
| 720p | `-S res:720,ext:mp4:m4a --merge-output-format mp4` |
| Audio only | `-f ba/b -x --audio-format m4a` |

`res:1080` means "largest at or below 1080p", so a 720p-only video still downloads.

## 4. Design

### GomCore

- **`DownloadRecord.video: VideoQuality?`** – nil for files. Optional, so queues saved by older versions decode unchanged. `VideoQuality` is a `String`-backed `Codable` enum (`best`, `1080p`, `720p`, `audio`).
- **`isVideoPage(_ url: URL) -> Bool`** – host equals or is a subdomain of: `youtube.com`, `youtu.be`, `vimeo.com`, `dailymotion.com`, `tiktok.com`, `x.com`, `twitter.com`, `facebook.com`, `instagram.com`, `twitch.tv`, `bilibili.com`, `soundcloud.com`. `notyoutube.com` does not match.
- **`AddRequest.video: VideoQuality?`** – the extension sets it; the bridge passes it through `/add` unchanged.
- **`DownloadQueue`** – `start` calls `runVideoDownload` when `record.video != nil`, otherwise `runDownload`. Everything else (scheduling, concurrency cap, speed sampling, persistence, `onFinished`) is shared. `add(…)` gains `video:`; `retryMissingTools()` re-queues every video download that failed with the missing-tool message (§ 5).
- **`runVideoDownload(record, tools, limitRate, onProgress)`** – runs `yt-dlp` with `Process`, cancellation-aware like `runDownload`: returns the record `.completed`, `.failed(reason)` or `.paused` (task cancelled).

### The yt-dlp process

```
yt-dlp --quiet --no-simulate --progress --newline --no-playlist -I 1 --no-mtime
       --progress-template "download:GOM %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(progress.speed)s"
       --print "before_dl:GOMNAME %(title)s"
       --print "after_move:GOMFILE %(filepath)s"
       --ffmpeg-location <ffmpeg> [--limit-rate <bytes>] [--add-header "User-Agent:…"] [--add-header "Referer:…"]
       <quality args> -P <temp folder> -o "%(title).200B [%(id)s].%(ext)s" -- <url>
```

- **One URL = one video:** `-I 1` makes a playlist or channel URL download only its first video.
- **Output protocol:** only stdout lines starting with `GOM` are read; `NA` fields are nil. `GOMNAME` sets the row title while downloading, `GOM …` updates progress, `GOMFILE` is the finished file. The last `ERROR:` line on stderr becomes the failure reason; with none, "yt-dlp exited with status N".
- **Progress mapping:** the record keeps one segment; `segments[0].done` = bytes of streams already finished + current stream's downloaded bytes, `totalBytes` = finished bytes + current total (or estimate). When `downloaded_bytes` drops below the previous value, a new stream began and the previous stream's total moves into "finished bytes". So bytes never go backwards; the bar may jump back once when the second stream's size becomes known (`ponytail:` note). Speed comes from the queue's existing sampling, not yt-dlp's field.
- **Files:** yt-dlp writes into `<download dir>/.gom-<id8>/` (its `.part` files live there too). `tempURL` returns this folder for video records, so the queue's existing remove/cleanup deletes it. On success the `GOMFILE` file is moved into the category folder with the existing `categoryFolder` + `moveToUniqueDestination`, then the temp folder is deleted.
- **yt-dlp's PATH:** the folders of the located tools plus `/usr/bin:/bin:/usr/sbin:/sbin`, so yt-dlp finds `deno` and `ffmpeg` helpers.
- **Duplicates:** the duplicate check includes the quality, so the same URL at another quality is a new download.
- **Pause / quit:** task cancellation sends SIGINT and waits for exit (SIGKILL after 5 s if it hasn't exited); the record is `.paused` with its temp folder kept. Resume reruns the same command; yt-dlp continues from the `.part` file.
- **Speed limit:** Gom's global limit at process start is passed as `--limit-rate`. Video downloads are not part of the combined cap and pick up a changed limit on the next resume (`ponytail:` note).

### Finding the tools

`locateTool(_ name:, candidates:, isExecutable:) -> URL?` checks `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.deno/bin`, then the login shell (`$SHELL -lc 'command -v <name>'`), since GUI apps don't inherit the shell PATH. The app resolves `yt-dlp`, `ffmpeg` and `deno` at launch and after an install, and passes the paths to the queue.

`deno` is optional: downloads work without it, but YouTube then offers fewer formats. A video download starting while yt-dlp or ffmpeg is missing fails immediately with "yt-dlp not installed" / "ffmpeg not installed".

## 5. Installing the tools (app)

- When a video is added and yt-dlp or ffmpeg is missing, an alert: *"Video downloads need yt-dlp and ffmpeg. Install them with Homebrew?"* (names the missing required tools). A missing `deno` alone never prompts automatically; the Settings **Install** button then offers *"YouTube works best with deno"*. → **Install** / **Cancel**.
- **Install** runs `brew install` with all missing tools (deno included), off the main thread; Settings shows "Installing…". On success Gom re-locates the tools and calls `retryMissingTools()`. On failure an alert shows the last lines of brew's output.
- No Homebrew (no `brew` in the candidate paths): the alert shows `brew install` with the missing tools to copy and a **Get Homebrew** button opening brew.sh.

## 6. Settings

New **Video** section:

- **Quality** picker: Best / 1080p / 720p / Audio only (`@AppStorage("videoQuality")`, default Best). Used for pasted links.
- One status line per tool (yt-dlp, ffmpeg, deno): "yt-dlp 2026.08.19 – ~/.local/bin" or "Not installed", and an **Install** button while anything is missing.

## 7. Extension

`contextMenus` permission; a parent item **Download video with Gom** with four children, on `page` and `link` contexts. Click → `POST /add` with `{ url: linkUrl ?? pageUrl, referrer: pageUrl, userAgent, video: "<quality>" }` (no cookies). If Gom isn't running, the badge shows "!" briefly. `extension/README.md` documents the menu.

## 8. Testing

- **GomCore unit tests:** `parseYtDlpLine` (progress with total, with estimate only, with `NA`; `GOMNAME`; `GOMFILE` with spaces; non-`GOM` noise; malformed numbers), the two-stream byte accumulation, `VideoQuality` arguments, `isVideoPage` (subdomains, lookalikes, non-video hosts), `locateTool` with a fake `isExecutable`, decoding a stored record without `video`, bridge `/add` with `video`.
- **Engine test:** `runVideoDownload` against a fake `yt-dlp` shell script that prints scripted lines, writes a file, and exits 0 or 1: completion and move into the category folder, failure message from `ERROR:`, pause via cancellation (script sleeps; record comes back `.paused`).
- **Manual:** the debug build (installed Gom quit) driven with cua-driver: a real YouTube link pasted at 720p and via the right-click menu at Audio only; check progress, speed, pause/resume, and the files landing in Video and Music. The missing-tool alert is checked by pointing the locator at an empty candidate list in a debug run.
- **Docs:** README Features and Roadmap (phase 2 done), extension README.
