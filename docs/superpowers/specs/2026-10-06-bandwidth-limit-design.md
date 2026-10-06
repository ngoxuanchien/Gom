# Gom – Global bandwidth limit

Date: 2026-10-06 · Status: implemented (revised: paced range requests)

## 1. Goal

Let the user cap how much network bandwidth Gom uses, so a big download doesn't starve video calls or browsing. One number in Settings, in KB/s, caps the **combined** speed of every segment of every download. `0` means unlimited (the default). Changing it applies immediately to running downloads; nothing restarts.

**Out of scope:** per-download limits, schedules ("unlimited at night"), upload limits.

## 2. Units

1 KB = 1000 bytes, the same unit the download rows use for speed (`ByteCountFormatter`, `.file` style), so a limit of 500 shows up as about "500 KB/s".

## 3. Design

### Where to throttle

Throttling has to slow the **network**, not just the disk writes. `HTTPStreamer` buffers whatever URLSession delivers without bound, so making readers wait on an open response would leave URLSession downloading at full speed into memory.

So when a limit is set, a segment no longer fetches its whole range in one request. It fetches it in **pieces**: one `Range` request per piece, and before each request it waits until the shared token bucket has room for that piece's bytes. The network can then never be more than one piece per segment ahead of the cap, and memory holds at most one piece per segment.

- Piece size: `max(64 KB, rate / 4)`, i.e. about a quarter second of the whole budget. At 500 KB/s that is 125 KB, so all segments together issue about four requests a second over kept-alive connections.
- Unlimited (`0`): one request for the rest of the segment, as before.
- A limit set while a segment is in an unlimited request: the segment stops reading that response and continues in pieces from where it is.
- Servers without range support (single connection, restarted from zero on retry) can't be split; there the reader waits on the bucket after each chunk. Memory may grow when the network is much faster than the cap; noted in a `ponytail:` comment.

Every download in a `DownloadQueue` uses the queue's single `HTTPStreamer`, which owns the bucket, so the limit is global. Probe requests aren't throttled; they are one byte.

### Rejected first version: suspending URLSession tasks

The first implementation charged every received chunk to the bucket in the URLSession delegate and `suspend()`ed the data task while overdrawn. Measured against a local server with 8 connections it did not work: ~95% of bytes were still delivered while tasks were suspended (socket read-ahead), the combined speed ran ~30% over the cap, and after repeated suspend/resume cycles most connections stalled until URLSession's 60 s timeout, whose retries brought fresh bursts. `MockURLProtocol` could not reproduce any of this.

### Token bucket

`BandwidthLimiter`, a GCRA-style reservation clock guarded by a `Mutex`:

- `bytesPerSecond` (`0` = unlimited), `nextFree: ContinuousClock.Instant`, `generation`.
- Reserving `n` bytes: `nextFree = max(now - burst, nextFree) + n / rate`; the caller proceeds once `nextFree` (its slot's end) is reached. Waiting for the end, not the start, matters for the no-ranges path, where URLSession may hand over most of a file in one chunk.
- `burst` = 0.25 s, so short idle gaps can be made up without exceeding the cap noticeably.
- `acquire(n) async throws` sleeps until its slot ends, in slices of at most 100 ms. Cancellation (pause) ends the wait at once.

### Changing the limit live

Setting `bytesPerSecond` resets `nextFree` to now and bumps `generation`. A waiter that sees a new generation drops its reservation and reserves again at the new rate, or proceeds at once if the limit is now `0`. So raising the limit never waits out a delay computed at the old rate, and lowering it applies to the next piece.

### Surface

- **GomCore** – `HTTPStreamer.bytesPerSecond: Int` (0 = unlimited), backed by its `BandwidthLimiter`. `DownloadQueue.bandwidthLimit: Int` (bytes/s) forwards to its streamer.
- **App** – `@AppStorage("speedLimitKB")`, default 0. Settings → Downloads gets a "Speed limit" number field with a "KB/s" suffix and the footer note "0 = unlimited". `AppSettings.speedLimitKB` reads it; `AppDelegate` applies it to the queue at launch, and `SettingsView` (given the queue) applies it in `onChange`.
- **README** – feature bullet.

## 4. Error handling

- Negative input is clamped to 0.
- A piece that fails or arrives short is retried like any segment failure (`withRetry`), resuming from the bytes already written.
- A `200` answer to a piece's range request means the file changed, as before.

## 5. Testing

- `BandwidthLimitTests`, against `MockServer`:
  - **Throughput:** a 2 MiB file (the smallest size that is split, so 8 segments) at 500 000 B/s finishes in about 4.2 s (assert 3.5–5.0 s), byte-identical, and no request asks for more than one piece.
  - **Live raise:** at 100 000 B/s, still running after 0.5 s; set 0 → finishes in under 3 s (the old limit would need ~21 s).
  - **Live lower:** a slow unlimited download gets a limit after 0.3 s → later requests are piece-sized.
  - **Pause while throttled** stops within 1 s.
- Manual: a local Range-capable server with a 300 MB file. Measured: 495 KB/s steady at a 500 KB/s cap (the row shows 499–501 KB/s); 197 KB/s after lowering to 200 live; memory flat (~138–160 MB); setting 0 finished the remaining ~250 MB in under 4 s; SHA-256 matches.
