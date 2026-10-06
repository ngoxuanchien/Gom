# Gom – Download notifications

Date: 2026-10-06 · Status: implemented

## 1. Goal

Tell the user when a download finishes while they are in another app: a macOS notification on success (click → reveal the file in Finder) and on failure (click → bring Gom to the front to retry). Notifications can be turned off in Settings.

**Out of scope:** action buttons in the notification (Retry, Open), sounds per event, banners while Gom is the frontmost app (macOS hides them by default; the window already shows the result).

## 2. Starting point

Gom already asks for notification permission on launch and posts "Download complete" through `DownloadQueue.onCompleted`. Missing: failure notifications, click handling, and an off switch.

## 3. Behaviour

| Event | Notification | Click |
|---|---|---|
| Download completes | "Download complete" · file name | Finder opens with the file selected |
| Download fails (after the engine's retries) | "Download failed" · file name — error | Gom comes to the front |
| Paused, cancelled, removed, app quit | none | — |

Permission is requested on first launch, as today. If the user denies it, macOS drops the notifications silently.

## 4. Design

- **GomCore** – `DownloadQueue.onCompleted` becomes `onFinished`, called with the final record when a download that is still in the list ends `.completed` or `.failed`. Pauses (including those from shutdown) and removed downloads don't call it.
- **App** – `AppDelegate` sets `onFinished` and is the `UNUserNotificationCenterDelegate`. The success notification carries the file path in `userInfo`; `didReceive` reveals it with `NSWorkspace.activateFileViewerSelecting`, or shows the main window when there is no path (failure).
- **Settings** – `@AppStorage("notifications")`, default on, toggle "Show notifications" in the Downloads section. Checked when posting, so changes apply immediately.

## 5. Testing

- `DownloadQueueTests`: a failing download (`MockServer` status 403) calls `onFinished` once with `.failed`; a completed one calls it with `.completed`; a pause doesn't call it.
- Manual: download a file with Gom in the background → notification → click reveals it in Finder; break a URL → failure notification; toggle off → nothing.
