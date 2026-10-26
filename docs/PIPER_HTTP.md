# Piper HTTP backend

A separate `piper-http` TTS backend. The server synthesizes WAV audio; KOReader
still plays it through its existing local audio/Bluetooth path. Local Piper,
espeak, and sanoTTS remain separate engine choices.

## Configuration on the reader

1. Enable Wi-Fi and connect to the same trusted network as the server.
2. Open a book and go to **Tools > Audiobook Read-Along > Voice settings**.
3. Select **TTS engine > Piper HTTP (network server)**.
4. Open **Server URL** and enter your own base URL, including the port.
5. Choose **HTTP voice**:
   - `ru_RU-irina-medium` (Russian female, medium)
   - `en_US-amy-medium` (US English female, medium)
   - `de_DE-ramona-low` (German female, low)
   - `en_US-lessac-medium` (US English, medium)
   - `en_US-lessac-high` (US English, high)
   - `en_US-libritts-high` (US English, high; server default speaker)
6. Choose **Reading mode**: **Sentences** (default) or **Page + next page** (experimental).
7. In sentence mode, choose **Cache ahead** (0–8 sentences; default 3). Zero disables sentence lookahead. Page mode instead prepares exactly one next page.
8. Start read-aloud normally.

There is **no default server address**, discovery, or fallback server. An empty
URL stops reading with an error. Save normalizes whitespace and trailing slashes.
The address must be a base `http://hostname:port` URL, not a `/synthesize` path.
HTTPS, credentials, and path-prefixed reverse proxies are not supported in this
initial version. Text goes to the configured server unencrypted: use a trusted
LAN or VPN and do not expose an unauthenticated server to the internet.

Settings are stored under `audiobook_settings`:

| Key | Default | Purpose |
| --- | --- | --- |
| `tts_backend` | existing engine | Set to `piper-http` by selecting the engine |
| `piper_http_url` | empty | Edited with the on-reader keyboard |
| `piper_http_voice` | `ru_RU-irina-medium` | Chosen in the voice menu |
| `piper_http_mode` | `sentences` | On-reader choice: `sentences` or `page` |
| `piper_http_timeout` | 30 | Sentence request deadline in seconds, clamped to 5–120; advanced file setting |
| `piper_http_page_timeout` | 90 | Page request deadline in seconds, clamped to 5–120; advanced file setting |
| `piper_http_lookahead` | 3 | Number of future parsed sentences to cache, editable on-device (0–8) |

Changing the address or voice stops the current reading session. Start playback
again to apply it. Remote selection ignores the local espeak-only override.
LibriTTS high contains 904 speakers, but this menu currently selects the model
only: no `speaker_id` is sent, so Piper uses its default speaker. The new menu
entries do not download models or change the saved voice automatically.

## Server contract

The server must accept `POST /synthesize` with JSON fields `text`, `voice`, and
`length_scale`, and return a nonempty RIFF/WAVE body with HTTP 200. Piper's
`python -m piper.http_server` from `piper-tts[http]==1.8.0` provides this API.
This is **not** the OpenAI `/v1/audio/speech` API. Models must already be on the
server. Speech-rate control maps to `length_scale = 1 / rate`.

## Responsiveness and failure behavior

HTTP runs in KOReader's `ffi/util.runInSubProcess` worker, not in the UI thread.
The parent polls at 100 ms and enforces a total deadline, including stuck DNS.
Stop, engine switch, and shutdown kill the worker synchronously; they do not
rely on the UI loop continuing after exit. A direct PID kill also covers early
cancellation before the child creates its process group. Cancelled callbacks
cannot begin playback. WAV responses are limited to 16 MiB; text to 32768 bytes.

### Bounded lookahead

While a sentence plays, the next N parsed sentences are downloaded in order.
There is exactly one HTTP worker, including both foreground and lookahead.
A ready WAV is consumed without another network request. If the next sentence
is already being downloaded, that request is promoted to foreground rather
than duplicated. An unrelated speculative request is cancelled when the
current sentence needs priority.

The sliding window is limited to eight future sentences and 32 MiB of ready
WAV files in temporary storage, plus the current download/playing audio.
Out-of-window files are deleted. Stop, seek, URL/voice changes, and speech
setting restarts clear the cache. Keys include full text, server URL, voice,
speed, and software gain, so audio from another configuration cannot be reused.
Prefetch failures do not skip text: the foreground request gets a fresh retry.
A full byte budget does not trigger a continuous redownload loop. Setting N to
zero clears speculation without interrupting an active foreground request.

The window currently covers the parsed page, including any existing wrapped
sentence. It is replenished after page transitions; it does not pre-render the
whole book. Word timing is estimated and scaled to WAV duration, not
server-provided alignment. A failed foreground request stops read-aloud and
shows an error rather than silently skipping content or switching to a local
synthesizer.

### Playback blocks on Kobo MTK / legacy gst-bt

Ready adjacent sentences are merged into one canonical PCM16 mono WAV before
launching the legacy Bluetooth player. A block includes at most five sentences;
additional sentences are not included if their combined audio would exceed the
existing 30-second concat threshold. A single long sentence is not truncated.
This removes per-sentence GStreamer/Bluetooth restarts **inside** a ready block
without re-enabling audioout. Configured sentence/paragraph silence is padded
once, and word/sentence boundaries use the existing concat timing machinery.

Assembly only borrows already-ready WAVs: it never waits for HTTP or synthesizes
in the UI. A miss starts the available sentence/block immediately. Lookahead
then starts after the last sentence in that block, not after its first sentence.
The cache transfers file ownership to block cleanup; a cache reset cannot delete
files which the player is using. Different sample rates/formats or noncanonical
headers are not merged. Other audio-player paths retain single-file playback.

The first sentence may start before any lookahead is ready. Player-startup gaps
can remain between blocks and on page transitions; this is not a persistent or
fully gapless streaming player. Logs include `HTTP playback block` and its
sentence range so actual on-reader grouping can be checked.

### Whole-page audio + next-page preparation

Page mode sends the complete normalized visible-page text in one request,
without the local synthesizer's 300/1000-character chunk limits. The existing
32768-byte text and 16 MiB WAV limits still apply: an oversized request fails
explicitly rather than silently truncating the book. A page is one playback
unit, including pages longer than the sentence block mode's 30-second cap.
This is an **opt-in experimental mode**: long WAV playback still needs physical
Kobo/Bluetooth validation; switch back to sentence mode if it is unstable.
Natural pauses emitted by the model remain.

While page audio plays, a deferred snapshot of the next view is normalized
and queued through the same single-worker cache. There are no visible UI page
turns for the snapshot; rolling page mode follows the visible page count and
hidden-flow successors, while scrolling accounts for footer and overlap height.
The original document view is restored even after extraction/navigation errors.
If restoration fails or the active view changes unexpectedly, reading stops.

The preview is only a cache hint. On automatic advance the **actual settled
next-page text** is captured again; only an exact normalized text/cache-key
match reuses its WAV. A wrong or incomplete preview causes a fresh request,
never reading the wrong cached page. No next-page request is made when
`auto_advance` is disabled. Page mode does not append the beginning of the next
page to complete a sentence, or skip a prefix as if it had already been spoken.

Word positions are retained and timings are estimated over the whole WAV,
then scaled to its duration; they are not exact server alignments. Page-wide
sentence highlighting is suppressed while word highlighting remains available.
Progress is word-based. Volume/rate restarts and scrubbing request the remaining
page starting at the current/selected word instead of repeating the page start.

Manual page changes stop old page audio and cancel pending network work,
including while loading. Restart read-aloud on the newly visible page. Rotation
or a changed layout stops the session rather than trying to remap a whole-page
utterance to differently split sentences. Paged EPUB view is recommended; scroll
view's intentionally overlapping lines may be spoken again across view changes.

This eliminates player restarts **inside** a page, not the Bluetooth startup
gap between pages. Preview mismatches, slow synthesis, Wi-Fi loss, and page
layout changes may still cause waits. The NAS/container API does not change.

### Volume with audioout disabled

When `audioout_enabled` is false, the HTTP worker attenuates PCM16 WAV samples
before returning audio to the player. This does not require GStreamer's volume
element and avoids applying the same gain twice. Zero percent is digital silence.
In sentence mode, changing volume while playing restarts the current sentence
with the new gain; while loading it restarts the pending sentence. Page mode
restarts the remaining page at the current word instead. Adjusting a paused
session does not resume it: the new gain applies when the user resumes. With audioout enabled,
the existing live daemon gain control remains in use.

Moving synthesis to a server does not replace the reader's Bluetooth player or
fix every possible local audio/firmware failure.

## Installation and verification

Back up the installed plugin first. The changed runtime files are:

- `piperhttp.lua`
- `piperhttpqueue.lua` (lookahead queue)
- `piperhttppage.lua` (whole-page preparation/view identity)
- `main.lua` (safe preview and manual-view-change hook)
- `ttsengine.lua`
- `menubuilder.lua`
- `synccontroller.lua`

The release packager also includes the new module. Existing voices and settings
need not be deleted; no address is automatically written to the reader.

Host checks (LuaJIT):

```sh
luajit dev/test_piper_http.lua
luajit dev/test_piper_http_queue.lua
luajit dev/test_piper_http_blocks.lua
luajit dev/test_piper_http_pages.lua
luajit dev/test_piper_http_menu.lua
luajit dev/test_piper_http_volume.lua
luajit dev/test_audioout_deadline.lua
luajit dev/test_tts_kobo_safety.lua
```

These are isolated/mocked backend, transport, menu, and audio-lifecycle checks.
Separate live NAS probes verified HTTP synthesis returns WAV, including a
single page-sized request producing more than 30 seconds of audio, but end-to-end
KOReader subprocess behavior, physical keyboard/menu, Bluetooth playback, close
button, and USB teardown still require a real-reader acceptance test.

Device acceptance: save/restore a manually entered URL, play each language,
change voice, stop while a request is loading, close while playing and paused,
make the server unreachable, and enter USB mode after stopping. Test N=0, 3,
and 8, immediate stop while prefetching, changes to voice/rate/volume, and page
transitions. Confirm no text is silently skipped and local engines remain
selectable. Host queue tests use a controlled fake worker; cache behavior on
physical Kobo still requires this acceptance test. Block tests exercise actual
WAV merging and controller completion/ownership with a fake audio player; verify
the audible gaps and real Bluetooth startup on the reader after installation.
For page mode also verify a long page, cached automatic advance, from-here
reading, a wrong-preview cache miss, manual turning while loading, stop/USB,
rotation, word-based seek, and volume/rate changes partway through the page.
Host tests exercise real WAV parsing/merging and fake document/worker lifecycle,
not the physical e-ink controller or Bluetooth hardware.
