# Gom – Dynamic segment splitting

Date: 2026-10-14 · Status: proposed, not implemented

Source: prompt 2 of `docs/superpowers/prompts/2026-10-14-plexo-learnings.md`.

## 1. Goal

A segmented download should not crawl on one slow connection while the others sit idle. When a connection finishes its segment, it takes over half of the biggest range still left, so all connections stay busy until the remaining ranges are too small to split.

**Out of scope:** more than the starting number of connections, racing (hedging) a slow range with a duplicate request, per-connection refusal handling (prompt 3), single-connection downloads (no ranges), video downloads.

## 2. Today

`makeSegments` cuts the file into 8 equal segments (1 for files under 2 MiB). `transferSegments` starts one task per unfinished segment; each runs `fetchSegment` under `withRetry`. When 7 segments are done, the download waits on the 8th at one connection's speed, and the queue hands the 7 freed connections to other downloads from the same server (if any).

## 3. Approaches

### A. Split the largest remainder (IDM-style) — recommended

When a connection finishes its segment, it picks the unfinished segment with the most bytes left, cuts that segment's `end` back to the middle of what is left, appends a new segment for the second half, and fetches it.

- Fits `Segment(start, end, done)` as is: segments stay disjoint and together cover the file. The persisted format doesn't change.
- One request per split; no byte is fetched twice except a chunk in flight at the moment of a split (see §4.3).
- Same number of connections as today (§4.6).
- Doesn't help when the slow range is already small (below the split minimum). That tail is under 1 MiB per connection.

### B. Shared block queue + hedging (Plexo)

The file becomes a queue of ≤ 8 MB blocks; each connection pulls the next block; near the end a slow block is fetched again in parallel and the first copy to finish wins.

- One request per block: a 4 GB file is ~500 requests instead of 8 plus a few splits. Each request pays a round trip before data flows.
- `Segment` would still fit (blocks are segments), but a record would persist hundreds of segments, and `DownloadQueue.connections(of:)` (unfinished segments) would have to be capped at 8, because it would see ~500.
- Hedging downloads the same bytes twice and has two writers on one range: it costs bandwidth and needs a "who finished first" rule.
- Its advantage is handling a connection that slows down **at the very end**. Approach A covers most of that until the remainder drops under the minimum.

### C. Small fixed segments (e.g. 32 per file) with 8 workers

Simpler than B (no hedging), but it has B's request count and queue-accounting change without B's tail handling.

**Recommendation: A.** It solves the stated problem (idle connections while one is slow) with no format change, no queue change, and no duplicate traffic. Hedging can be added later on top of A if a slow last megabyte turns out to matter.

## 4. Design (approach A)

### 4.1 Connections are workers, not segments

`transferSegments` starts one task per unfinished segment, as today. Each task is a **connection**: it fetches its segment and, when that segment completes, continues with the segment it got from a split. It ends when no split is possible.

```
connection(index):
    current = index
    while current != nil:
        current = withRetry { fetchSegment(current) }   // returns the split it claimed, or nil
```

So a download never runs more tasks than it had unfinished segments when it started.

### 4.2 Splitting rule

Pure function in `Segment.swift`:

```swift
/// Cuts the unfinished segment with the most bytes left in two and appends the second half.
/// Returns the new segment's index, or nil if no segment has at least `minSplitRemainder` left.
func splitLargest(_ segments: inout [Segment]) -> Int?
```

- Remaining bytes of a segment: `end - nextOffset + 1`.
- `minSplitRemainder = 1 MiB`: only a segment with at least 1 MiB left is split, so each half gets at least 512 KiB. A 100 KB remainder is never split.
- Split point: `mid = nextOffset + remaining / 2`. The old segment becomes `[start, mid - 1]`; the new one is `Segment(start: mid, end: oldEnd)`, appended to the array.
- Ties go to the lowest index (deterministic for tests).
- Indexes of existing segments never change, so a running task's `index` stays valid.

Example: a 16 MiB file has 2 MiB segments. Segment 7 is slow; when segment 0 finishes, segment 7 has 1.8 MiB left. It is cut at `nextOffset + 0.9 MiB`; segment 8 is the second 0.9 MiB, fetched by the connection that just finished segment 0.

Files under 8 MiB start with segments smaller than 1 MiB and are never split. That is intentional: their tail is short anyway.

### 4.3 Split and completion happen under one lock

`ProgressBox` (the mutex-guarded segment array shared by a download's tasks) does the split:

```swift
/// Adds `count` written bytes to segment `index`, never past its end. If that completes the segment,
/// splits the largest remainder in the same critical section and returns the new segment's index
/// for the caller to fetch next.
func add(_ count: Int64, to index: Int) -> Int?
func end(of index: Int) -> Int64
```

Doing both in one critical section means no snapshot ever shows a completed segment without its replacement, so the queue never sees a connection freed and then taken again (§4.6).

**Clamping.** A running request was sent for the old, larger range. `fetchSegment` reads `box.end(of: index)` for each chunk and writes only up to it. A chunk can still be written past the new end if a split lands between that read and `add`. That is safe:

- The bytes are the same bytes the new segment will write at those offsets: every range request carries `If-Range`, so all `206` answers come from the same version of the file (a changed file returns `200`, which restarts the download, as today).
- `add` clamps: `done = min(done + count, end - start + 1)`, so progress never counts past the shrunk end.

Write first, then `add`: if the write fails, nothing was counted, and the retry resumes from `nextOffset` as today.

### 4.4 Running requests stop at the new end

In `fetchSegment`, for each chunk:

```
let stop = min(last, box.end(of: index))
write data.prefix(max(0, stop + 1 - offset))
offset += written; next = box.add(written, to: index)
if next != nil or offset > box.end(of: index): leave the response loop
```

Leaving the `for try await` loop ends the stream, whose `onTermination` cancels the URLSession task, so the old request stops downloading bytes the new segment now owns. The end-of-request check changes from `offset <= last` to `offset <= min(last, box.end(of: index))`, so stopping early at a split isn't mistaken for a short response. The piece loop (`while offset <= segment.end`) re-reads the end each time.

### 4.5 Speed limit

The new segment is fetched by the same `fetchSegment`, so under a limit it goes through the same paced piece loop: `limiter.acquire` before every request. Splitting never sends an unpaced request.

The victim's in-flight piece had already reserved tokens for its whole piece. If it stops early at a split, those tokens are spent without bytes: the download runs slightly **under** the cap for that moment, never over it.

### 4.6 Connections per server

`DownloadQueue.connections(of:)` counts unfinished segments. A split happens only in the same critical section in which a segment completes, so the unfinished count stays the same (one done, one new) or goes down (no split possible). It never goes up. The queue therefore keeps seeing at most 8 connections per segmented download and needs no change. When splitting stops, connections are freed one by one as their last ranges finish, as today.

### 4.7 Persistence and resume

- `Segment` and `DownloadRecord` don't change. A record saved after a split simply has more than 8 segments, some complete; the unfinished ones are disjoint and cover what is left of the file.
- Resume starts one connection per unfinished segment (§4.1), then splits as usual. A download paused with 3 unfinished segments resumes with 3 connections, matching what the queue counts for it.
- Older records (8 segments, never split) load and resume unchanged; there is nothing to migrate.
- An older Gom reading a newer record also works: it starts one task per unfinished segment.

### 4.8 Errors

- A failed request on a segment is retried by `withRetry` for that segment, as today. Its retry counter is per segment, so a connection that moves on to a split starts the new segment with a fresh counter.
- A segment that runs out of retries fails the whole download, as today.
- Cancellation (pause, quit, schedule window closing) stops every connection; the snapshot taken in `transferSegments`'s `defer` keeps every split.

## 5. Changes

- `Segment.swift`: `minSplitRemainder`, `splitLargest(_:)`.
- `DownloadEngine.swift`: `ProgressBox.add` clamps and splits, plus `end(of:)`; `transferSegments` runs a connection loop per task; `fetchSegment` returns the claimed index, stops at the live end, and fixes the short-response check.
- `DownloadQueue.swift`: no change.
- `MockServer.swift` (tests): `delayOnlyAt: Int?`, so one range request can be slow while the others are fast.
- README: "Multi-connection HTTP downloads (8 segments)" becomes "Multi-connection HTTP downloads (8 connections; one that finishes early takes over half of the largest range left)".

This builds on the `download-resilience` branch (its `withRetry(progress:)` is per segment). Implement after that branch merges.

## 6. Testing

- **`splitLargest` (unit):** picks the segment with the most bytes left; splits at `nextOffset + remaining / 2`; result is disjoint and covers the same bytes; returns nil when every remainder is under 1 MiB; ignores completed segments; breaks ties by lowest index.
- **`ProgressBox` (unit):** `add` clamps at a shrunk end; an `add` that completes a segment returns a split index and leaves the unfinished count unchanged; with nothing to split it returns nil and the count drops by one.
- **Engine, unlimited:** a 16 MiB file whose last segment is slow (`delayOnlyAt` its start). Completes byte-identical; more than 8 segments; the segments are disjoint, all complete, and cover the file; a range request starts inside the original last segment.
- **Engine, speed limit:** the same file at 8 MB/s, last segment slow. Completes byte-identical, splits, and no request asks for more than `pieceSize(for: 8_000_000)`.
- **Resume after split:** pause once the record has more than 8 segments, round-trip it through `JSONEncoder`/`JSONDecoder`, resume. Completes byte-identical; each unfinished segment's `nextOffset-end` range is requested, and no resumed request starts inside a range the paused record already had complete (it may split again, so extra requests are allowed).
- Existing tests stay valid: all of them use files under 8 MiB, which never split.
- **Manual:** a local Range-capable server, a 300 MB file, one range throttled. The row's speed stays up after the other segments finish; SHA-256 matches; `downloads.json` after a pause shows the extra segments.
