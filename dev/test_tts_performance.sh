#!/bin/sh
# Host-only regression tests; do not run Kobo binaries or touch an attached Kobo.
set -eu
cd "$(dirname "$0")/.."
LUAJIT=${LUAJIT:-luajit}
for test in \
    dev/test_tts_performance.lua \
    dev/test_tts_async_playback.lua \
    dev/test_tts_async_espeak.lua \
    dev/test_tts_server_start.lua
do
    "$LUAJIT" "$test"
done
out=$(mktemp)
trap 'rm -f "$out"' EXIT HUP INT TERM
for file in audioout.lua piperqueue.lua synccontroller.lua ttsengine.lua; do
    "$LUAJIT" -b "$file" "$out"
done
printf '%s\n' 'PASS LuaJIT syntax checks'
