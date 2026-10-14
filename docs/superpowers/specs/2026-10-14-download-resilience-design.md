# Gom – Download resilience

Date: 2026-10-14 · Status: approved in chat, not implemented

Source: a comparison of Gom's engine with [Plexo](https://github.com/anmolkapil/plexo), a multi-network download manager. Three small gaps came out of it. Bigger ideas from the same comparison (dynamic segment splitting, per-connection refusal handling) are tracked as brainstorming prompts in `docs/superpowers/prompts/2026-10-14-plexo-learnings.md`, not here.

## 1. Goal

Large downloads over flaky links, near-full disks, or an idle Mac should finish or fail early with a clear reason, instead of failing late or stalling.

**Out of scope:** changing the segment count or layout, multi-network downloads, video downloads (yt-dlp has its own retry and disk handling).

## 2. Retries count only attempts that got nowhere

Today `withRetry` gives each segment 6 attempts for the whole download. A segment that loses its connection 6 times over hours, while making progress each time, fails the whole download.

- A segment attempt that wrote new bytes before failing resets that segment's attempt counter (and so its backoff, back to ~1 s).
- An attempt that wrote nothing counts as before: 6 such attempts in a row give up.
- Single-connection downloads (no ranges) restart from zero on every attempt, so progress there proves nothing. They keep today's fixed budget.
- The probe keeps today's fixed budget.

Plexo does the same: a stream's `failures` resets whenever it receives bytes.

## 3. Check free space before downloading

Today the temp file is created sparse with `truncate`, so a full disk shows up only as a write error partway through.

- When a download is prepared (first start, or a restart after the file changed) and its size is known, compare it to the free space of the target directory's volume (`volumeAvailableCapacityForImportantUsage`).
- Not enough room: the download fails at once, without retries, with `Not enough disk space: needs <size>, <size> free`, sizes in the same `ByteCountFormatter` `.file` style the rows use. No temp file is left behind.
- Unknown size (no `Content-Length`), or a volume that doesn't report free space: no check, as today.
- Resuming a paused download doesn't check again: its temp file already holds its full size.

## 4. Keep the Mac awake while downloading

Today nothing stops idle sleep, so an overnight download can stop when the Mac sleeps.

- While at least one download is running, Gom holds a `ProcessInfo` activity with `.idleSystemSleepDisabled` (reason "Downloading files"). The display may still sleep.
- The activity ends as soon as no download is running: completed, failed, paused, or stopped by the schedule window.
- The existing "sleep when scheduled downloads finish" action is unaffected: it sleeps explicitly, and the activity has already ended by then.

## 5. Testing

- Engine tests against `MockServer`: a connection that drops mid-body more than 6 times still completes; a too-small volume fails with the message and leaves no temp file.
- Queue test: the queue reports keeping the Mac awake while a download runs and stops once it ends.
- Manual: `pmset -g assertions` shows Gom's assertion during a download and not after.
