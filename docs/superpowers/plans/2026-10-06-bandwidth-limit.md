# Bandwidth Limit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Settings value in KB/s (0 = unlimited) caps the combined network speed of all downloads, changeable live.

**Architecture:** `StreamDelegate` charges every received chunk to a shared GCRA token bucket and suspends the data task until the debt is paid, so the socket itself slows down. `HTTPStreamer.bytesPerSecond` sets the rate; `DownloadQueue.bandwidthLimit` forwards to its streamer; the app writes it from `@AppStorage`.

**Tech Stack:** Swift 6, Swift Testing, URLSession, `Synchronization.Mutex`, SwiftUI.

**Spec:** `docs/superpowers/specs/2026-10-06-bandwidth-limit-design.md`

## Global Constraints

- 1 KB = 1000 bytes. 0 = unlimited, the default. Negative values clamp to 0.
- Burst allowance 0.25 s.
- Changing the limit never restarts a download.
- Tests run with `swift test` in `Gom/GomCore`.

## Review Focus

- Raising the limit while tasks are suspended → they resume immediately (live-change test).
- Pausing a download while its task is suspended → it still pauses promptly (pause-under-limit test).
- Limit 0 → no suspend at all; the existing suite passes unchanged.
- Many segments at once → combined, not per-segment, rate (throughput test uses 8 segments).
- A timed resume firing after the task finished or was already resumed → no-op (generation check).

---

### Task 1: Throttle in HTTPStreamer

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/HTTPStreamer.swift`
- Test: `Gom/GomCore/Tests/GomCoreTests/BandwidthLimitTests.swift`

**Interfaces:**
- Produces: `HTTPStreamer.bytesPerSecond: Int { get set }` (bytes/s, 0 = unlimited).

- [ ] Step 1: Write `BandwidthLimitTests`: throughput (2 MiB, 16 KB chunks, 500 000 B/s → 3.5–5.0 s, identical file), live change (100 000 B/s, set 0 after 0.5 s → < 3 s), pause under limit (cancel after 0.3 s → `.paused` within 1 s).
- [ ] Step 2: `swift test --filter BandwidthLimitTests` → fails to compile (`bytesPerSecond` missing).
- [ ] Step 3: Implement the throttle (rate, nextFree, suspended `[taskID: (task, generation)]`) in `StreamDelegate`; call it from `didReceive data`; drop entries in `didCompleteWithError`; the `bytesPerSecond` setter resets `nextFree` and resumes suspended tasks.
- [ ] Step 4: `swift test` → all pass. If throughput is unthrottled, the mock ignores suspend: make `MockURLProtocol` honour it.
- [ ] Step 5: Commit.

### Task 2: Queue, Settings, README

**Files:**
- Modify: `Gom/GomCore/Sources/GomCore/DownloadQueue.swift` — `public var bandwidthLimit: Int` forwarding to `streamer.bytesPerSecond`.
- Modify: `Gom/App/AppSettings.swift` — `speedLimitKB`.
- Modify: `Gom/App/SettingsView.swift` — "Speed limit" field with KB/s suffix and "0 = unlimited" footer; `onChange` → `queue.bandwidthLimit`.
- Modify: `Gom/App/GomApp.swift` — pass the queue to `SettingsView`, apply the limit at launch.
- Modify: `README.md`.

- [ ] Step 1: Implement; build the app with `xcodebuild`.
- [ ] Step 2: Commit.

### Task 3: Manual verification

- [ ] Run a local Range-capable HTTP server in the scratchpad serving a ~200 MB file.
- [ ] Launch the built app, set 500 KB/s, add the URL; row speed ≈ 500 KB/s, memory flat.
- [ ] Set 0 mid-download → speed jumps. Screenshot.
