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
6. Choose **Cache ahead** (0–8 sentences; default 3). Zero disables lookahead.
7. Start read-aloud normally.

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
| `piper_http_timeout` | 30 | Request deadline in seconds, clamped to 5–120; advanced file setting |
| `piper_http_lookahead` | 3 | Number of future parsed sentences to cache, editable on-device (0–8) |

Changing the address or voice stops the current reading session. Start playback
again to apply it. Remote selection ignores the local espeak-only override.

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
whole book. This caches individual WAVs, not a concatenated stream: Bluetooth
startup/page-transition gaps may remain. Word timing is estimated and scaled
to WAV duration, not server-provided alignment. A failed foreground request
stops read-aloud and shows an error rather than silently skipping content or
switching to a local synthesizer.

### Volume with audioout disabled

When `audioout_enabled` is false, the HTTP worker attenuates PCM16 WAV samples
before returning audio to the player. This does not require GStreamer's volume
element and avoids applying the same gain twice. Zero percent is digital silence.
Changing volume while playing restarts the current sentence with the new gain;
while loading it restarts the pending sentence. Adjusting a paused session does
not resume it: the new gain applies when the user resumes. With audioout enabled,
the existing live daemon gain control remains in use.

Moving synthesis to a server does not replace the reader's Bluetooth player or
fix every possible local audio/firmware failure.

## Installation and verification

Back up the installed plugin first. The changed runtime files are:

- `piperhttp.lua`
- `piperhttpqueue.lua` (new lookahead queue)
- `ttsengine.lua`
- `menubuilder.lua`
- `synccontroller.lua`

The release packager also includes the new module. Existing voices and settings
need not be deleted; no address is automatically written to the reader.

Host checks (LuaJIT):

```sh
luajit dev/test_piper_http.lua
luajit dev/test_piper_http_queue.lua
luajit dev/test_piper_http_menu.lua
luajit dev/test_piper_http_volume.lua
luajit dev/test_audioout_deadline.lua
luajit dev/test_tts_kobo_safety.lua
```

These are isolated/mocked backend, transport, menu, and audio-lifecycle checks.
A separate live NAS probe verified HTTP synthesis returns WAV, but end-to-end
KOReader subprocess behavior, physical keyboard/menu, Bluetooth playback, close
button, and USB teardown still require a real-reader acceptance test.

Device acceptance: save/restore a manually entered URL, play each language,
change voice, stop while a request is loading, close while playing and paused,
make the server unreachable, and enter USB mode after stopping. Test N=0, 3,
and 8, immediate stop while prefetching, changes to voice/rate/volume, and page
transitions. Confirm no text is silently skipped and local engines remain
selectable. Host queue tests use a controlled fake worker; cache behavior on
physical Kobo still requires this acceptance test.
