# Gom – Schedule downloads by free connections per server

Date: 2026-10-08 · Status: draft

## 1. Goal

Run more downloads at once when connections are free, instead of a fixed three files. Downloads from different servers no longer wait for each other; downloads from the same server start as that server's earlier downloads wind down.

**Out of scope:** a Settings control, re-splitting a running download into more segments, tracking redirects to another host.

## 2. Background

- `DownloadQueue.schedule()` starts queued downloads while `running.count < maxConcurrent` (3), whatever they are.
- A download of ≥ 2 MB from a server that accepts ranges runs 8 segments; otherwise 1 connection. The engine only knows which after probing. Finished segments are not re-split, so a download's last minutes often use few connections.
- `HTTPStreamer` uses one `URLSession` with the default `httpMaximumConnectionsPerHost` (6). Requests beyond that wait inside URLSession, where a long wait can end in a timeout that looks like a server failure. So "start everything and requeue on timeout" was rejected: the restart would wait again, and that timeout can't be told apart from a real one.

## 3. Design

- `maxConcurrent` is replaced by a per-host budget, `connectionsPerHost = defaultSegmentCount` (8).
- Connections a running download uses, read from its latest record:
  - video (yt-dlp): 1;
  - not probed yet (no segments): 8, the most it can open;
  - segmented (`resumable`): its unfinished segments;
  - otherwise: 1.
- `schedule()` starts a queued download when its host (`record.url.host()`) uses fewer than 8 connections, counting downloads started earlier in the same pass. Scheduled downloads still wait for their window.
- `schedule()` also runs on every progress report, so a download starts as soon as a segment of another one on its host finishes.
- A host can briefly exceed 8 (up to 7 + 8 = 15) when a new download starts beside one that is winding down. `HTTPStreamer` sets `httpMaximumConnectionsPerHost` to `2 × connectionsPerHost` (16), so those requests never wait inside URLSession. The spare slot covers the save dialog's filename probe.
- `activeCount` stays as the number of running downloads.

ponytail: hosts are the URL as added; a redirect to a CDN counts against the original host. Track the final host if that matters.

## 4. Testing

`DownloadQueueTests` (the mock server gets an optional `host` so several files can share one):

1. Five large slow files on five hosts all run at once (replaces `runsAtMostThreeAtOnce`).
2. Three large slow files on one host: one runs, the others stay queued until its segments finish; all complete.
3. Ten small (single-connection) slow files on one host: eight run at once.

Then the full suite, and a manual check on the debug build with a few real downloads.
