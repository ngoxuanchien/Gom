# Gom – Open at login

Date: 2026-10-07 · Status: implemented

## 1. Goal

Let the user start Gom automatically when they log in, so the menu bar item, scheduled downloads and browser hand-offs work without opening Gom by hand.

**Out of scope:** starting hidden (no window) at login, a separate helper app.

## 2. Design

- Settings gets a **General** section at the top with an **Open at login** toggle.
- The toggle calls `SMAppService.mainApp.register()` / `unregister()` (ServiceManagement). macOS owns the state; Gom stores nothing in `UserDefaults`, so turning Gom off in System Settings → General → Login Items is reflected in the toggle.
- The status is re-read when Settings appears and whenever Gom becomes active again (e.g. after returning from System Settings).
- If the status is `requiresApproval`, the section shows "Gom needs approval in Login Items." with an **Open System Settings** button (`SMAppService.openSystemSettingsLoginItems()`).
- A failed register/unregister shows the error in an alert and the toggle snaps back to the real status.

## 3. Notes

- The login item points at the app bundle that registered it. Turn the toggle on from `/Applications/Gom.app`, not from a debug build.

## 4. Testing

Manual: toggle on → `sfltool dumpbtm` lists Gom as `enabled, allowed`; toggle off → the entry is gone. Toggle reflects changes made in System Settings after switching back to Gom.
