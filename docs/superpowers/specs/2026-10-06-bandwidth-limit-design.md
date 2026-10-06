# Gom – Global bandwidth limit

Date: 2026-10-06 · Status: implemented

## 1. Goal

Let the user cap how much network bandwidth Gom uses, so a big download doesn't starve video calls or browsing. One number in Settings, in KB/s, caps the **combined** speed of every segment of every download. `0` means unlimited (the default). Changing it applies immediately to running downloads; nothing restarts.

**Out of scope:** per-download limits, schedules ("unlimited at night"), upload limits.

## 2. Units

1 KB = 1000 bytes, the same unit the download rows use for speed (`ByteCountFormatter`, `.file` style), so a limit of 500 shows up as about "500 KB/s".

## 3. Design

### Where to throttle

Throttling has to slow the **network**, not just the disk writes. `HTTPStreamer` buffers whatever URLSession delivers without bound, so making the segment readers wait would leave URLSession downloading at full speed into memory. Instead the throttle sits in `StreamDelegate.urlSession(_:dataTask:didReceive:)`:

1. The chunk is yielded to its stream as today.
2. Its size is charged to a token bucket shared by the whole `HTTPStreamer`.
3. If the bucket is overdrawn, the data task is `suspend()`ed and `resume()`d once the debt is paid. While suspended, URLSession stops reading the socket, TCP's receive window fills, and the server slows down.

Every download in a `DownloadQueue` uses the queue's single `HTTPStreamer`, so the limit is global without extra plumbing. Probe requests go through the same bucket; they are tiny.

### Token bucket

A GCRA-style reservation clock, guarded by a `Mutex`:

- `rate` in bytes/s (`0` = unlimited), `nextFree: ContinuousClock.Instant`.
- `reserve(n) -> Duration`: `start = max(now - burst, nextFree)`, `nextFree = start + n / rate`, return `max(0, nextFree - now)`.
- `burst` = 0.25 s, so short idle gaps can be made up without exceeding the cap noticeably.

Each chunk reserves its own slot, so concurrent segments share the rate fairly in arrival order.

### Changing the limit live

`HTTPStreamer.bytesPerSecond` is a get/set property. Setting it resets `nextFree` to now and resumes every task the throttle has suspended, so raising the limit (or setting `0`) doesn't wait out a delay computed at the old, slower rate. Lowering it takes effect on the next chunk. A suspended task's pending resume is ignored if the task was already resumed by a limit change (tracked by a per-task generation number).

### Surface

- **GomCore** – `HTTPStreamer.bytesPerSecond: Int` (0 = unlimited). `DownloadQueue.bandwidthLimit: Int` (bytes/s) forwards to its streamer.
- **App** – `@AppStorage("speedLimitKB")`, default 0. Settings → Downloads gets a "Speed limit" number field with a "KB/s" suffix and the footer note "0 = unlimited". `AppSettings.speedLimitKB` reads it; `AppDelegate` applies it to the queue at launch, and `SettingsView` (now given the queue) applies it in `onChange`.
- **README** – feature bullet and a sentence on the setting.

### Findings from implementation

- `suspend()` calls on a URLSession task are counted, and URLSession keeps delivering already-buffered data to a suspended task. The throttle therefore suspends a task only once and lets the latest timer's single `resume()` win; suspending on every chunk left real tasks stuck until the 60 s request timeout.
- `suspend()` does not stop the socket instantly: data already read ahead (kernel buffer + CFNetwork) is still delivered. Every byte is charged, so the long-run average holds the cap, but speed is bursty: measured against a local server with 8 connections, short spikes of several MB/s were followed by pauses while the debt was paid. A single connection settled at ~495 KB/s for a 500 KB/s cap. Smoother pacing would need a pull-based HTTP client (e.g. Network.framework), which is out of scope.

## 4. Error handling

- Negative input is clamped to 0.
- A task cancelled while suspended: `cancel()` works on suspended tasks; the later `resume()` on a cancelled task is a no-op.
- Tasks that finish are removed from the suspended set in `didCompleteWithError`.

## 5. Testing

- New `BandwidthLimitTests`, against `MockServer`:
  - **Throughput:** a 2 MiB file (the smallest size that is split, so 8 segments), 16 KB chunks, no server delay, limit 500 000 B/s → finishes in about 4.2 s (assert 3.5–5.0 s) and the file is byte-identical.
  - **Live change:** same file at 100 000 B/s, then after 0.5 s set 0 → finishes in under 3 s (the old limit would need ~21 s).
- `MockURLProtocol` ignored suspension, so it now stops delivering while its task is suspended (like a socket that isn't read); the bandwidth tests use a 1 ms chunk pace so there is a gap in which to observe that.
- Manual: a local HTTP server (outside the repo) serving a large file — set 500 KB/s, watch the row speed settle near 500 KB/s and Gom's memory stay flat; change to 0 mid-download and speed jumps at once.
