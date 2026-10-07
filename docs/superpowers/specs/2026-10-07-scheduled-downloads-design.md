# Gom – Scheduled downloads (phase 3)

Date: 2026-10-07 · Status: approved design

## 1. Goal

Let the user leave big downloads for a time window, typically overnight off-peak hours (e.g. 01:00–06:00), and optionally quit Gom or put the Mac to sleep once they are done.

- One **global window** in Settings. Each download can be marked **scheduled**; a scheduled download only runs while the window is open.
- When the window closes, running scheduled downloads are paused and continue the next time it opens.
- Optional **end action** (Do nothing / Quit Gom / Sleep Mac) once all scheduled downloads are finished, after a cancellable 60-second countdown.
- Everything survives app restarts.

**Out of scope:** waking the Mac at the window start (`pmset schedule` needs admin), per-download windows, several windows, scheduling downloads that arrive from the extension (they still ask for a folder and start right away; they can be marked scheduled afterwards from the row).

Gom must be running and the Mac awake for the window to take effect.

## 2. Model

### `ScheduleWindow` (GomCore, new file `Schedule.swift`)

```swift
public struct ScheduleWindow: Equatable, Sendable {
    public var start: Int   // minutes since midnight, 0..<1440
    public var end: Int
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool
}
```

- `start < end`: open for `start <= t < end`.
- `start > end`: crosses midnight, open for `t >= start || t < end` (22:00–06:00).
- `start == end`: open all day.
- `t` is the local wall-clock minute of `date` in `calendar` (hour * 60 + minute), so DST and clock changes are handled by re-evaluating, not by computing instants.

### `DownloadRecord.scheduled: Bool?`

New stored property: `true` = scheduled, `nil` = not (never `false`). Optional like `video` and `categories`, so synthesized `Codable` loads `downloads.json` files written before phase 3 and writes no key for unscheduled records. Persisted through `DownloadStore` with the rest of the record. It stays set after the download completes (harmless) and is cleared by "Start Now".

The engine works on a copy of the record taken at start, so when its progress and result are written back the queue keeps the record's current `scheduled` value; a toggle made while the download runs is not lost.

### Settings (`UserDefaults`, via `AppSettings`)

The window and the end action are app settings, like the speed limit, not queue data: storing them in `downloads.json` would turn the file from an array into an object and need a migration.

- `scheduleStart`, `scheduleEnd`: minutes since midnight, defaults 60 (01:00) and 360 (06:00).
- `scheduleAction`: `"none" | "quit" | "sleep"`, default `"none"`.

## 3. Queue behaviour (`DownloadQueue`)

New surface:

```swift
public var scheduleWindow: ScheduleWindow?          // nil = scheduled downloads never start
public var onScheduleFinished: (() -> Void)?        // @ObservationIgnored
public func refreshSchedule(now: Date = .now)
public func setScheduled(_ id: UUID, _ scheduled: Bool)
public func add(..., scheduled: Bool = false) -> UUID
```

- **Window state.** `refreshSchedule(now:)` sets a private `windowOpen = scheduleWindow?.contains(now) ?? false`. It is stateless and idempotent: calling it twice with the same time does nothing new.
- **Starting.** `schedule()` starts a `queued` record only if `!record.scheduled || windowOpen`. So a scheduled download added outside the window shows "Scheduled" and waits; one added inside the window starts at once.
- **Closing.** When `refreshSchedule` finds the window closed, every running scheduled download is cancelled and goes back to `queued` (not `paused`), the same way `shutdown()` does it, keeping its segments. It starts again when the window next opens.
- **Restart.** At init `scheduleWindow` is nil, so persisted scheduled downloads don't start until the app sets the window and calls `refreshSchedule()`. A download that was interrupted mid-window starts again if the window is still open.
- **`setScheduled(id, false)`** ("Start Now") clears the flag and calls `schedule()`. **`setScheduled(id, true)`** sets it; if the download is running and the window is closed it is moved back to `queued` like at close. Paused, failed and completed records just get the flag.
- **End action trigger.** A private `scheduledRunPending` flag is set when a scheduled download completes or fails (pausing is not finishing), and cleared when the window closes with scheduled work left, so a leftover run can't fire the action later in the day. After any download finishes, if the flag is set, nothing is running (`activeCount == 0`), and no scheduled record is `queued` or `downloading`, the flag is cleared and `onScheduleFinished` is called. Consequences:
  - Fires once per run, after the last scheduled download completes or fails.
  - Never fires while any download (scheduled or not) is still running.
  - Does not fire when the window closes with work left: those records are back to `queued`.
  - Scheduled downloads the user paused by hand don't block it.
  - Never fires during `shutdown()` (app quit).

## 4. App

- **Timer.** `AppDelegate` sets `queue.scheduleWindow` from `AppSettings` at launch and calls `refreshSchedule()`; then every 30 s from a `Timer`, and on `NSWorkspace.didWakeNotification`. Up to 30 s lag at the window edges is accepted.
- **Settings → Schedule section.** "Start at" and "Pause at" `DatePicker`s (hour and minute), and "When scheduled downloads finish: Do nothing / Quit Gom / Sleep Mac". `onChange` updates `queue.scheduleWindow` and calls `refreshSchedule()`.
- **Row.** Context menu: "Start in Schedule" on unscheduled unfinished records, "Start Now" on scheduled ones. A queued scheduled record shows "Scheduled · starts 01:00" instead of "Queued".
- **Add bar.** A "Schedule" toggle (`@AppStorage("scheduleNew")`, default off); pasted and dropped links are added with `scheduled: toggle`.
- **End action.** `onScheduleFinished` reads `AppSettings.scheduleAction`. For `none` it does nothing. Otherwise it shows an alert: "Scheduled downloads finished. Gom will quit / put the Mac to sleep in 60 seconds." with buttons "Quit Now" / "Sleep Now" and "Cancel"; a 1-second timer updates the countdown and acts at 0. Quit is `NSApp.terminate(nil)` (the queue saves through `shutdown()`); sleep runs `/usr/bin/pmset sleepnow`, which needs neither admin rights nor Automation permission.
- **README.** Feature bullet; Roadmap marks phase 3 done.

## 5. Error handling

- `pmset` failing (non-zero exit or launch error) is logged; the app stays up.
- A window with `start == end` is valid (all day), so the pickers can't produce an invalid value.
- Decoding an old store without `scheduled` gives `nil` (not scheduled).

## 6. Testing

GomCore, `ScheduleTests.swift` (Swift Testing, like the rest):

- `ScheduleWindow.contains`: inside / outside a normal window; a midnight-crossing window at 23:00, 03:00, 12:00; start minute included, end minute excluded; `start == end` open at any time. Dates are built in a fixed `Calendar` with a fixed time zone.
- `DownloadQueue` against `MockServer` with an injected `now`:
  - a scheduled download added outside the window stays `queued`; `refreshSchedule` inside the window starts it; an unscheduled one starts right away;
  - closing the window moves a running scheduled download back to `queued` with its progress kept, and leaves unscheduled downloads running;
  - `onScheduleFinished` fires exactly once after the last scheduled download completes, not while an unscheduled download is still running, and not when the window closes with work left;
  - `setScheduled(id, false)` starts a waiting download outside the window;
  - `scheduled` survives a save/load round trip, and a relaunched queue without a window set does not start it.

Manual: a window a few minutes ahead with the debug build. The download waits, starts at the window start, pauses at the window end, and the countdown alert appears when it is done; "Cancel" leaves Gom running.
