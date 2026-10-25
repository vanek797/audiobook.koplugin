# Conservative Kobo TTS patch

## Current behavior

- TTS overlays its playback panel instead of changing live EPUB margins.
  `audiobook_settings.reserve_tts_bar_space = true` restores upstream behavior.
  Storyteller's margin handling is unchanged.
- Piper FIFO readiness uses `O_NONBLOCK`, so a dead writer cannot block the
  readiness check indefinitely.
- Synthesis and synchronous shutdown are retained. Audioout socket transport
  now uses Linux `SOCK_NONBLOCK` with one monotonic deadline spanning connect,
  send, and receive. Partial writes and newline-framed partial replies are
  handled; send uses `MSG_NOSIGNAL`.
- Close/stop allows 250 ms for stop and 500 ms for release. Failure invokes
  synchronous shutdown (200 ms), SIGTERM, then a SIGKILL fallback after 100 ms.
  No shutdown work is deferred to a UI loop that may already be exiting.

## Withdrawn async experiment

Commit b6bbd83 introduced asynchronous audioout transport and teardown. Host
unit tests passed, but the tests did not cover the real daemon or USB teardown.
On-device logs then showed repeated playback failures, and USB setup failed
after KOReader had scheduled stop/release and torn down its UI event loop.
Deferred cleanup cannot be relied on once that event loop exits. The async
experiment has therefore been rolled back rather than presented as safe.
The logs do not independently prove that it was the sole cause of every USB
failure. Further async work requires real-daemon protocol and USB lifecycle
tests before deployment.

On the affected reader, `audiobook_settings.pause_on_menu = false` was set to
avoid repeated `auto-pause, extra UI widget on stack` events. This is a local
setting, not a change to the plugin's default: narration continues while menus
are open. The selected engine and voices were left unchanged.

## Verification

```sh
luajit dev/test_tts_kobo_safety.lua
luajit dev/test_audioout_deadline.lua
```

Four safety checks cover default/opt-in panel layout and source invariants
for FIFO readiness and synchronous teardown. Ten additional checks mock
backlogged connect, stalled send/receive, a shared deadline, fragmented JSON,
closed/refused peers, teardown budgets, and engine fallback. They are not
Linux kernel, Bluetooth, or device integration tests.

The close-button investigation found the device log ending inside engine
stop, before either the audio teardown acknowledgement or panel hide. A
blocking connect before the old receive-only timeout was a concrete risk;
the logs alone do not prove which syscall blocked. Added teardown boundary
logging will distinguish this path on the next device run. Confirm close,
start/stop, pause/resume, and USB connection after restarting KOReader.
Normal rendering, Bluetooth, and synthesis performance still depend on the
upstream implementation. The short release budget intentionally favors a
responsive UI over preserving a slow or stuck Bluetooth pipeline.
