<p align="center"><img src="docs/logo.svg" width="128" alt="Gom logo"></p>

<h1 align="center">Gom</h1>

<p align="center">A small, fast download manager for macOS, with a browser extension that hands your downloads to it.</p>

## Features

### Downloading

- Download queue with a concurrency limit; state survives app restarts.
- Multi-connection HTTP downloads (8 segments) with pause/resume and automatic retry.
- Optional speed limit (Settings → Speed limit, in KB/s; 0 = unlimited) that caps all downloads together and applies to running downloads immediately.
- Scheduled downloads: mark downloads (right-click → Start in Schedule, or the Schedule toggle when adding) to run only in a daily window (Settings → Schedule, e.g. 01:00–06:00). They pause when the window closes and continue the next time it opens. Optionally quit Gom or put the Mac to sleep once they finish, after a 60-second countdown you can cancel.
- Add downloads by pasting a URL or dragging a link into the window.

### Browser

- Chrome / Arc / Brave / Edge extension that intercepts downloads (optionally only above a size threshold) and sends them to Gom, with cookies and Referer so logged-in downloads work. If Gom is not running, the browser downloads the file itself.
- Downloads from the browser bring Gom to the front and ask which folder to save into. The folder picker opens in the file's category folder (e.g. `~/Downloads/Documents` for a PDF).

### Organizing

- Sorts downloads into subfolders by file type (Documents, Compressed, Music, Video, Programs, Images); folders and extensions are editable in Settings.
- A sidebar filters the download list by the same file types.
- The download list shows the newest first; open a finished file with its Open button, right-click → Open, or a double-click.

### Video

- Downloads videos from YouTube, Vimeo and other sites with [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Best / 1080p / 720p / Audio only): paste the link or right-click the page in Chrome. Gom finds an installed yt-dlp and ffmpeg, or offers to install them with Homebrew.

### Menu bar and notifications

- Menu bar item showing how many downloads are running and the total speed; its popover lists unfinished downloads with progress and has Pause All, Resume All, Open Gom and Quit.
- macOS notifications when a download completes (click to reveal it in Finder) or fails; can be turned off in Settings.

No external dependencies: Swift, SwiftUI and Network.framework only. Video downloads use yt-dlp and ffmpeg, installed on demand.

## Requirements

- macOS 27 and Xcode 27
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the installer gets it via Homebrew if missing)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/ngoxuanchien/Gom/main/install.sh | bash
```

Or from a checkout:

```sh
git clone https://github.com/ngoxuanchien/Gom.git && cd Gom && ./install.sh
```

The script builds a Release app and copies it to `/Applications` (set `GOM_APP_DIR` to install elsewhere). When run through `curl`, the source is kept in `~/Library/Application Support/Gom/source` (or `GOM_SRC_DIR`) so the Chrome extension loaded from it stays put; running the script again updates it. The app is ad-hoc signed, not notarized.

### Browser extension

1. Open `chrome://extensions` and turn on **Developer mode**.
2. Click **Load unpacked** and choose the `extension/` folder.
3. In the extension's **Options**, paste the token from Gom → Settings → Copy, click **Save**, then **Test connection**.

More details and known limitations: [extension/README.md](extension/README.md).

## Development

```sh
cd Gom
xcodegen generate && open Gom.xcodeproj   # app
swift test --package-path GomCore         # core tests
```

```
Gom/App/       SwiftUI app
Gom/GomCore/   download engine, queue, bridge server (Swift package + tests)
extension/     Manifest V3 browser extension
docs/          design spec and plans
```

The extension talks to the app over `http://127.0.0.1:47615`, authenticated by a token.

