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
6. Start read-aloud normally.

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

Only one foreground request runs at a time. This first version intentionally
disables speculative prefetch/concat for HTTP, so there may be inter-sentence
network gaps. Word timing is estimated and scaled to the WAV duration, not
server-provided alignment. A failed request stops read-aloud and shows an error;
it does not silently skip content or switch to a local synthesizer.

Moving synthesis to a server does not replace the reader's Bluetooth player or
fix every possible local audio/firmware failure.

## Installation and verification

Back up the installed plugin first. The changed runtime files are:

- `piperhttp.lua` (new)
- `ttsengine.lua`
- `menubuilder.lua`
- `synccontroller.lua`

The release packager also includes the new module. Existing voices and settings
need not be deleted; no address is automatically written to the reader.

Host checks (LuaJIT):

```sh
luajit dev/test_piper_http.lua
luajit dev/test_piper_http_menu.lua
luajit dev/test_audioout_deadline.lua
luajit dev/test_tts_kobo_safety.lua
```

These are isolated/mocked backend, transport, menu, and audio-lifecycle checks.
A separate live NAS probe verified HTTP synthesis returns WAV, but end-to-end
KOReader subprocess behavior, physical keyboard/menu, Bluetooth playback, close
button, and USB teardown still require a real-reader acceptance test.

Device acceptance: save/restore a manually entered URL, play each language,
change voice, stop while a request is loading, close while playing and paused,
make the server unreachable, and enter USB mode after stopping. Confirm no text
is silently skipped and local engines remain selectable.
