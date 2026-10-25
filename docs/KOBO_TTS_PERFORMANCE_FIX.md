# Kobo TTS UI-stall patch

## Scope

Local investigation of audiobook.koplugin v0.6.3 on a Kobo Clara B&W.
The fork was based on v0.6.4 when this patch was prepared; its unrelated
Kindle keepalive change is retained. These are Lua changes, not rebuilt TTS
binaries. No quantitative on-device performance improvement is claimed.

## Changes

- TTS no longer reserves live CRE page margins by default. The playback bar
  overlays the page, avoiding the full EPUB reflow at TTS start/stop. Set
  `audiobook_settings.reserve_tts_bar_space = true` to restore the old layout.
  Storyteller/media-overlay margin handling is unchanged.
- TTS audioout startup, playback, queue-full recovery, pause/resume, stop,
  and release no longer wait for daemon replies in the UI thread.
- `AudioOut:commandAsync` uses Linux nonblocking Unix sockets, bounded work
  per timer tick, partial-write handling, buffered newline-framed JSON,
  wall-clock deadlines, cancellation, and closed-peer handling.
- TTS polls `statusCached`: at most one request is in flight, requests are
  limited to 10 Hz, cached values expire after 750 ms, and playback epochs
  reject old replies. The original synchronous `status` API is retained for
  media-engine capability probes and existing daemon integration tests.
- Espeak fallback synthesis runs in a background process. Current playback
  state is not overwritten by lookahead synthesis; duplicate prefetch work
  is suppressed and stale callbacks are discarded. Completion markers are
  published atomically; timeout/stop cancels background jobs.
- Piper startup's 200 ms grace period uses a scheduled continuation instead
  of `os.execute("usleep 200000")`. Stopped startup callbacks cannot launch
  a new server. FIFO readiness uses `O_NONBLOCK`, avoiding a permanent wait
  if the FIFO's writer has died.

Generation checks protect pending playback, delayed daemon shutdown, and
server startup from reviving or killing a newer reading session. A pause
requested during startup is applied after the play acknowledgement.

## Host tests

Requires LuaJIT and a POSIX shell:

```sh
sh dev/test_tts_performance.sh
```

The suite currently has 21 checks plus LuaJIT syntax compilation. Socket
transport and KOReader scheduling are mocked; espeak worker tests run an
actual background shell with a fake synthesizer. These tests do **not**
verify real Bluetooth, Linux socket integration, EPUB rendering, or device
responsiveness. No Kobo binary runs on the host.

## Device acceptance test (still required)

1. Back up the four modified Lua files and `settings.reader.lua`.
2. Copy the patched Lua files into the existing plugin; retain all bundled
   engines, voices, settings, and other plugins.
3. Safely eject the Kobo and restart KOReader.
4. Open the EPUB which previously stalled. Start/stop TTS several times;
   the TTS panel should overlay the text without changing page margins.
5. Try espeak, sanoTTS Kristin on English text, and Piper Amy. Test pause
   during startup, resume, page transitions, and rapid stop/start.
6. Disconnect the headset during playback. Confirm a clean failure rather
   than a frozen UI. Reconnect and restart playback.
7. Save `crash.log` and the plugin's `debug.log` for comparison.

The overlay may cover the bottom lines of a page; this is the intentional
tradeoff for avoiding a reflow. This patch does not make Piper synthesis
itself faster, and it does not remove every synchronous shell/file operation
from the plugin. Independent audiobook/media-engine startup still uses its
existing synchronous API.

## Rollback and updates

Restore the backed-up Lua files and restart KOReader. Restore settings only
if you explicitly changed them. Plugin updates can overwrite this local
patch; rebase and rerun tests before applying it to another release.
