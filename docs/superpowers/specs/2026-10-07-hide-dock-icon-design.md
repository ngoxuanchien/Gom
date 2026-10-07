# Gom – Hide the Dock icon in the background

Date: 2026-10-07 · Status: implemented

## 1. Goal

When the main window is closed, Gom keeps running (menu bar item, browser bridge, schedule) but no longer shows a Dock icon. The icon comes back whenever the main window does, e.g. when the extension hands over a download.

**Out of scope:** a setting to turn this off, starting hidden at launch or login.

## 2. Design

- `NSWindow.willCloseNotification` for the main window → `NSApp.setActivationPolicy(.accessory)` (no Dock icon, no app menu).
- `NSWindow.didBecomeKeyNotification` for the main window → `.regular`. This covers reopening Gom from Finder or Spotlight.
- `AppDelegate.showMainWindow()` also switches to `.regular` before activating. All in-app paths (extension hand-off, menu bar "Open Gom", failed-download notification) go through it, and the save panel takes key first, so the main window may never become key on a hand-off.
- The main window is matched by its identifier prefix `main`, same as `showMainWindow()`; the Settings window does not affect the Dock icon.

## 3. Testing

Manual, debug build driven with cua-driver; `lsappinfo list` shows `type="Foreground"` (Dock icon) or `type="UIElement"` (none):

1. Launch → `Foreground`.
2. Window › Close → `UIElement`, process still running.
3. `POST /add` on the bridge → main window and save panel shown, `Foreground`.
4. Cancel the panel, close the window again → `UIElement`.
