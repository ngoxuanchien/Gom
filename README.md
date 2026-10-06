<p align="center"><img src="docs/logo.svg" width="128" alt="Gom logo"></p>

<h1 align="center">Gom</h1>

<p align="center">A small, fast download manager for macOS, with a browser extension that hands your downloads to it.</p>

## Features

- Download queue with a concurrency limit; state survives app restarts.
- Multi-connection HTTP downloads (8 segments) with pause/resume and automatic retry.
- Add downloads by pasting a URL or dragging a link into the window.
- Chrome / Arc / Brave / Edge extension that intercepts downloads (optionally only above a size threshold) and sends them to Gom, with cookies and Referer so logged-in downloads work. If Gom is not running, the browser downloads the file itself.
- Downloads from the browser bring Gom to the front and ask which folder to save into.
- macOS notifications when a download completes (click to reveal it in Finder) or fails; can be turned off in Settings.
- Sorts downloads into subfolders by file type (Documents, Compressed, Music, Video, Programs, Images); folders and extensions are editable in Settings.
- No external dependencies: Swift, SwiftUI and Network.framework only.

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

## Roadmap

- Phase 2: video downloads via `yt-dlp`.
- Phase 3: scheduled downloads.
