# Gom – Menu bar extra

Date: 2026-10-06 · Status: implemented

## 1. Goal

Let the user check and control downloads without opening the main window: a menu bar item that shows how many downloads are running and the total speed, and a popover listing unfinished downloads with **Pause All**, **Resume All**, **Open Gom** and **Quit**.

**Out of scope:** a Settings toggle to hide the menu bar item, hiding the Dock icon (menu-bar-only mode), per-download speed history.

## 2. Behaviour

| Element | Content |
|---|---|
| Menu bar label, idle | `arrow.down.circle` icon only |
| Menu bar label, downloading | icon + `<n> · <speed>/s`, where *n* counts records in `.downloading` and speed is the sum of `DownloadQueue.speeds` |
| Popover list | records in `.downloading`, `.queued` or `.paused`, one `DownloadRow` each (progress, speed, pause/resume, remove); "No active downloads" when empty |
| Pause All | pauses every queued or downloading record |
| Resume All | queues every paused record again; failed records are left alone (retry stays per row) |
| Open Gom | brings the main window to the front, recreating it if it was closed |
| Quit | `NSApp.terminate`, so `DownloadQueue.shutdown()` saves running downloads as before |

## 3. Design

- **GomCore** – `DownloadQueue.pauseAll()` and `resumeAll()` loop over `items` and call the existing `pause(_:)` / `resume(_:)`, so the per-download rules (cancel the running task, persist, schedule) stay in one place.
- **App** – `MenuBarView` reads `DownloadQueue.items` and `speeds` directly (the queue is `@Observable`) and reuses `DownloadRow`. `GomApp` adds a `MenuBarExtra` scene with `.menuBarExtraStyle(.window)`; the `.menu` style can't render progress bars. **Open Gom** calls `AppDelegate.showMainWindow()`, which is no longer `private`.

## 4. Testing

- `DownloadQueueTests`: `pauseAll` pauses both a running and a queued record; `resumeAll` re-queues them and leaves a failed record failed.
- Manual: start several downloads, check the menu bar count and speed, use Pause All / Resume All, close the window and use Open Gom, Quit and relaunch to confirm the downloads resume.
