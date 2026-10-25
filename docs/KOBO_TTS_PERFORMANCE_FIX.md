# Conservative Kobo TTS patch

## Current behavior

- TTS overlays its playback panel instead of changing live EPUB margins.
  `audiobook_settings.reserve_tts_bar_space = true` restores upstream behavior.
  Storyteller's margin handling is unchanged.
- Piper FIFO readiness uses `O_NONBLOCK`, so a dead writer cannot block the
  readiness check indefinitely.
- Original upstream audioout transport, synthesis, and synchronous shutdown
  are retained.

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
```

The four checks cover default/opt-in panel layout and source invariants for
FIFO readiness and synchronous teardown. They are not device integration
tests. Confirm start/stop, pause/resume, and USB connection on the Kobo after
restarting KOReader. Normal rendering, Bluetooth, and synthesis performance
still depend on the upstream implementation.
