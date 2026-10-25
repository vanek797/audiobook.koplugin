--[[--
Piper TTS Queue & Server Management
Extracted from ttsengine.lua — owns all Piper-related state:
  • Persistent server lifecycle (start / stop / FIFO I/O)
  • Async prefetch queue (enqueue → batch dispatch → poll → finalize)
  • Model configuration (resolve path, read sample rate, list voices)
  • Command building (base command, JSON lines, per-process fallback)

The module takes an `engine` (TTSEngine) reference at construction time
and accesses engine fields/methods as needed (rate, piper_model, etc.).

@module piperqueue
--]]

local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local logger = require("logger")
local time = require("ui/time")
local _ = require("audiobook_gettext")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local WavUtils = dofile(_utils_dir .. "wavutils.lua")

-- ── Constants ────────────────────────────────────────────────────────

-- Auto-detect CPU cores.  On single-core ARM (e.g. Kobo Clara Cortex-A8)
-- running >1 Piper server causes severe CPU contention — benchmarks show
-- a 4× throughput drop vs a single server.  Only use multiple servers on
-- hardware with ≥2 physical cores.
local function _detect_cpu_cores()
    local f = io.open("/sys/devices/system/cpu/possible", "r")
    if f then
        -- Format: "0-N" → N+1 cores, or "0" → 1 core
        local s = f:read("*l") or "0"
        f:close()
        local hi = s:match("%-(%d+)")
        if hi then return tonumber(hi) + 1 end
        return 1
    end
    return 1  -- conservative fallback
end

local _cpu_cores    = _detect_cpu_cores()
local SERVER_COUNT  = math.min(_cpu_cores, 2)  -- 1 server per core, max 2
local SERVER_PREFIX = "/tmp/piper_server_"
local BATCH_SIZE    = _cpu_cores == 1 and 3 or 1  -- batch more on single-core
-- Maximum requests queued per server via FIFO pipelining.
-- On single-core, depth>1 adds FIFO overhead with no benefit (CPU can't
-- overlap work).  On multi-core, depth=2 keeps the server fed while we
-- process the previous result.
local MAX_PIPELINE_DEPTH = _cpu_cores == 1 and 1 or 2
-- The sanoTTS server is internally threaded (SNT_THREADS=2, arm-neon port
-- patch 0004): on multi-core devices it runs as ONE process covering both
-- cores, so a second server process would only oversubscribe.  Piper keeps
-- the one-process-per-core pool.  Resolved per active backend; cleanup
-- sweeps always cover the larger legacy pool so stale slots from a backend
-- switch are still reaped.
local function _pool_count(engine)
    if engine and engine.backend == engine.BACKENDS.SANOTTS then
        return 1
    end
    return SERVER_COUNT
end

-- ── PiperQueue class ─────────────────────────────────────────────────

local PiperQueue = {}

--[[--
Effective batch size.  Low-resource mode (setting A: explicit setting or
session auto-degrade) forces single-sentence batches so the next needed
sentence arrives after one synthesis instead of a full multi-sentence batch.
@return number
--]]
function PiperQueue:_batchSize()
    local engine = self.engine
    if engine._piperLowResource and engine:_piperLowResource() then
        return 1
    end
    return BATCH_SIZE
end

function PiperQueue:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    -- Required: reference to the owning TTSEngine
    assert(o.engine, "PiperQueue requires an engine reference")

    -- Queue state
    o._queue       = {}    -- keyed by sentence text → entry table
    o._queue_order = {}    -- ordered list of queued texts

    -- Server state
    o._servers              = {}
    o._servers_running      = false
    o._servers_starting     = false
    o._server_rr            = 0
    o._slots_busy           = 0
    o._server_start_attempts = 0

    return o
end

-- ── Model configuration ─────────────────────────────────────────────

--[[--
Read the sample rate from a Piper model's companion JSON config.
@param model_path string  Path to the .onnx file
@return number  Sample rate (defaults to 22050 if unreadable)
--]]
function PiperQueue:_readModelSampleRate(model_path)
    if not model_path then return 22050 end
    local json_path = model_path .. ".json"
    local f = io.open(json_path, "r")
    if not f then
        logger.dbg("PiperQueue: No .onnx.json sidecar for", model_path)
        return 22050
    end
    local content = f:read("*a")
    f:close()
    local sr = tonumber(content:match('"sample_rate"%s*:%s*(%d+)'))
    if sr and sr > 0 then
        logger.warn("PiperQueue: Model sample rate =", sr, "Hz")
        return sr
    end
    return 22050
end

--[[--
Resolve the Piper voice model path.
@return string|nil  Absolute path to .onnx file, or nil
--]]
function PiperQueue:_resolvePiperModel()
    local engine = self.engine
    -- Explicit model path set by user or config
    if engine.piper_model then
        if engine.piper_model:sub(1, 1) == "/" then
            local f = io.open(engine.piper_model, "r")
            if f then f:close(); return engine.piper_model end
        end
        local f = io.open(engine.piper_model, "r")
        if f then
            f:close()
            logger.dbg("PiperQueue: Resolved model relative to CWD:", engine.piper_model)
            return engine.piper_model
        end
        if engine.piper_model_dir then
            local basename = engine.piper_model:match("([^/]+)$")
            if basename then
                local try = engine.piper_model_dir .. "/" .. basename
                f = io.open(try, "r")
                if f then
                    f:close()
                    logger.dbg("PiperQueue: Resolved model via basename:", try)
                    return try
                end
                if not basename:match("%.onnx$") then
                    try = engine.piper_model_dir .. "/" .. basename .. ".onnx"
                    f = io.open(try, "r")
                    if f then f:close(); return try end
                end
            end
            local try = engine.piper_model_dir .. "/" .. engine.piper_model
            f = io.open(try, "r")
            if f then f:close(); return try end
        end
    end
    -- Auto-detect: first .onnx in the model dir
    logger.warn("PiperQueue: _resolvePiperModel – explicit path failed, falling back.",
        "piper_model=", engine.piper_model or "(nil)",
        "piper_model_dir=", engine.piper_model_dir or "(nil)")
    if engine.piper_model_dir then
        local handle = io.popen('find "' .. engine.piper_model_dir
            .. '" -name "*.onnx" -type f 2>/dev/null | head -1')
        if handle then
            local result = handle:read("*a"):gsub("%s+$", "")
            handle:close()
            if result and result ~= "" then
                logger.dbg("PiperQueue: Auto-detected model:", result)
                engine._piper_sample_rate = self:_readModelSampleRate(result)
                return result
            end
        end
    end
    return nil
end

--[[--
Set the Piper voice model.
@param model string  Model name or path
--]]
function PiperQueue:setModel(model)
    local engine = self.engine
    local old_model = engine.piper_model
    engine.piper_model = model
    local resolved = self:_resolvePiperModel()
    if resolved then
        engine._piper_sample_rate = self:_readModelSampleRate(resolved)
    end
    logger.dbg("PiperQueue: Model set to", engine.piper_model,
        "sample_rate=", engine._piper_sample_rate or 22050)
    if old_model and old_model ~= model then
        logger.warn("PiperQueue: Model changed, stopping servers + pipeline")
        self:stopServers()
        if engine._releaseAudioout then engine:_releaseAudioout() end
        self:cleanQueue()
    end
end

--[[--
Set the synthesis rate.  The rate is baked into each server's command line
as its length scale (Piper `--length_scale`, sanoTTS `--length-scale`), so a
server that is already running keeps the old speed.  Restart the servers when
it changes so the new speed actually reaches the audio; the next synthesis
spawns them with the fresh flag.

The rate affects only the synthesis engine.  espeak applies it per call, so
this is a no-op for that backend.
--]]
function PiperQueue:setRate(rate, old_rate)
    local engine = self.engine
    -- The caller may already have written the new rate into engine.rate, so
    -- take the previous value from the argument when it is given.
    local old = tonumber(old_rate) or engine.rate or 1.0
    rate = math.max(0.25, math.min(2.0, tonumber(rate) or 1.0))
    engine.rate = rate
    if math.abs(rate - old) < 0.01 then return end
    -- Drop audio that is already synthesized: the queue prefetches far ahead,
    -- so those sentences were produced at the old speed and would keep playing
    -- at the old speed long after the user asked for a new one.  Dropping them
    -- makes the change audible from the next sentence onward, at the cost of
    -- re-synthesizing them.  This matters in per-process mode too, where there
    -- are no servers to restart but the stale queue is the same.
    logger.warn("PiperQueue: Rate changed", old, "->", rate,
        (self._servers_running or self._servers_starting)
            and "- restarting servers to apply the new length scale"
            or "- flushing the prefetch queue")
    if self._servers_running or self._servers_starting then
        self:stopServers()
    end
    self:cleanQueue()
end

--[[--
Set the Piper speaker id (multi-speaker models).
@param id number  Speaker id (0-based)
--]]
function PiperQueue:setSpeaker(id)
    self.engine.piper_speaker = id or 0
    logger.dbg("PiperQueue: Speaker set to", self.engine.piper_speaker)
end

--[[--
Get the active model's sample rate.
@return number
--]]
function PiperQueue:getSampleRate()
    return self.engine._piper_sample_rate or 22050
end

--[[--
List available Piper voice models in the model directory.
@return table  Array of {name=, path=, size=, quality=, sample_rate=}
--]]
function PiperQueue:listVoices()
    local engine = self.engine
    local voices = {}
    if not engine.piper_model_dir then return voices end
    local handle = io.popen('find "' .. engine.piper_model_dir
        .. '" -name "*.onnx" -type f 2>/dev/null')
    if handle then
        for line in handle:lines() do
            local path = line:gsub("%s+$", "")
            if path ~= "" then
                local name = path:match("([^/]+)%.onnx$") or path
                local size = engine:getFileSize(path)
                local quality, voice_sr = nil, 22050
                local jf = io.open(path .. ".json", "r")
                if jf then
                    local content = jf:read("*a")
                    jf:close()
                    quality = content:match('"quality"%s*:%s*"([^"]+)"')
                    voice_sr = tonumber(content:match('"sample_rate"%s*:%s*(%d+)')) or 22050
                end
                table.insert(voices, {
                    name = name,
                    path = path,
                    size = size,
                    quality = quality,
                    sample_rate = voice_sr,
                })
            end
        end
        handle:close()
    end
    return voices
end

-- ── Command building ─────────────────────────────────────────────────

--[[--
Clean text for Piper synthesis.
@param text string
@return string
--]]
function PiperQueue:_cleanText(text)
    local clean = text:gsub("\n", " "):gsub("\r", "")
    clean = clean:gsub("\xe2\x80\xa6", ", ")       -- U+2026 ellipsis
    clean = clean:gsub("%.[%.%s]+%.", ", ")          -- 3+ dots
    clean = clean:gsub("%.%.+", ", ")                -- 2+ dots
    return clean
end

--[[--
Build the base Piper command (no I/O flags).
@return string
--]]
function PiperQueue:buildBaseCommand()
    local engine = self.engine
    -- sanoTTS-jp engine (Japanese, bring-your-own-weights): same FIFO/JSON
    -- protocol, own static musl binary, no loader prefix and no espeak
    -- flags.  Weights + dictionary paths are the user's downloads; they are
    -- quoted because plugin dirs can contain spaces.  The core has no user
    -- speed knob in v1, so no rate flag is emitted for this backend.
    if engine.backend == engine.BACKENDS.SANOTTS_JP and engine.snt_jp_server then
        -- Paths resolve from the state fields, with the deterministic
        -- download locations as fallback so a mid-session download works
        -- without re-running detectBackend (which would reset the backend).
        local jp_dir = (engine.plugin_dir
            or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin")
            .. "/sanotts-jp"
        local w = engine.snt_jp_weights or jp_dir .. "/saanotts-jp-v4-int8.bin"
        local d = engine.snt_jp_dict or jp_dir .. "/k1-dict-438750.bin"
        return string.format('nice -n 19 "%s" --weights "%s" --dict "%s"',
            engine.snt_jp_server, w, d)
    end
    -- sanoTTS engine: same FIFO/JSON protocol, different binary and args.
    if engine.backend == engine.BACKENDS.SANOTTS and engine.sanotts_server then
        local exec_prefix = ""
        local plugin_dir = engine.plugin_dir
            or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
        local espeak_lib = plugin_dir .. "/espeak-ng/lib"
        local ld_linux = espeak_lib .. "/ld-linux-armhf.so.3"
        local ld_f = io.open(ld_linux, "r")
        if ld_f then
            ld_f:close()
            local lib_path = espeak_lib .. ":/usr/lib:/lib"
            exec_prefix = string.format('"%s" --library-path "%s" ',
                ld_linux, lib_path)
        else
            exec_prefix = string.format('LD_LIBRARY_PATH="%s:/usr/lib:/lib" ',
                espeak_lib)
        end
        local espeak_bin = engine.espeak_bin
            or (plugin_dir .. "/espeak-ng/bin/espeak-ng")
        local espeak_data = engine.espeak_data_path
            or (plugin_dir .. "/espeak-ng/share")
        -- The bundled espeak-ng binary is a glibc ARM executable whose
        -- interpreter (/lib/ld-linux-armhf.so.3) does not exist on the Kobo
        -- rootfs: it must be exec'd through the bundled loader, exactly like
        -- piper itself is.
        local espeak_lib = plugin_dir .. "/espeak-ng/lib"
        local loader = espeak_lib .. "/ld-linux-armhf.so.3"
        local loader_f = io.open(loader, "r")
        local loader_flag = ""
        if loader_f then
            loader_f:close()
            loader_flag = string.format(' --loader "%s" --loader-libdir "%s"',
                loader, espeak_lib)
        end
        -- Per-voice engine selection from the ttsengine voice defs: amy is the
        -- fully-int8 piperlite stack with the punctuation pauses scaled up
        -- (device-ear preference); kristin is the R7 int8 voice; fr (and
        -- later fp32 siblings) run the fp32 piperlite pair with their own
        -- espeak voice and phoneme id map.  The rate slider maps to the
        -- piperlite length scale for the piperlite-family engines (pq8/f32),
        -- same convention as the Piper branch below (rate 1.0 emits no flag).
        local voice_name = engine.sanotts_voice_name or "amy"
        local vcfg = engine.sanotts_voice_cfg or {}
        local vengine = vcfg.engine or (voice_name == "kristin" and "int8" or "pq8")
        local engine_args
        -- The rate slider maps to the length scale for every sanoTTS engine
        -- that has a duration path: pq8 and f32 take it per call, and the int8
        -- (R7) engine applies it as a ratio on top of its native 1.08 (see
        -- snt_server).  Rate 1.0 emits no flag, keeping native speed.
        local rate = engine.rate or 1.0
        local ls = 1.0 / math.max(0.25, rate)
        local length_flag = ""
        if math.abs(ls - 1.0) > 0.01 then
            length_flag = string.format(" --length-scale %.2f", ls)
        end
        if vengine == "int8" then
            engine_args = " --engine int8" .. length_flag
        else
            engine_args = (vengine == "f32" and " --engine f32" or " --engine pq8")
                .. " --pause-scale 2.5" .. length_flag
        end
        local espeak_voice_flag = string.format(' --voice "%s"', vcfg.espeak_voice or "en-us")
        local phoneme_flag = vcfg.phonemes and vcfg.phonemes ~= "en"
            and string.format(" --phonemes %s", vcfg.phonemes) or ""
        -- Phonemizer: the in-process lexicon G2P (--g2p nano) replaces the
-- Phonemizer: the in-process lexicon G2P (--g2p nano) replaces the
-- per-clause espeak fork+exec, English and French alike. The
-- per-voice def wins over the sanotts_g2p setting; absent flag =
-- espeak path, byte-identical to the legacy command line.
        -- An explicit setting (the voice-menu toggle) beats the voice def,
        -- so the toggle stays a working escape hatch back to espeak.
        local g2p = (engine.plugin and engine.plugin.getSetting
                and engine.plugin:getSetting("sanotts_g2p", nil))
            or vcfg.g2p or "espeak"
        local g2p_flag = g2p == "nano" and " --g2p nano" or ""
            and " --g2p nano" or ""
        -- Thread the sanoTTS server across both cores on multi-core devices
        -- (arm-neon port, patch 0004).  Older server binaries ignore the
        -- variable, so setting it unconditionally is safe.  Single-core
        -- devices keep the serial path: a second thread would only fight
        -- for the one core.
        local threads_prefix = _cpu_cores > 1 and "SNT_THREADS=2 " or ""
        return string.format(
            '%snice -n 19 %s%s --model "%s" --espeak-bin "%s" --espeak-data "%s"%s%s%s%s%s',
            threads_prefix, exec_prefix, engine.sanotts_server, engine.sanotts_voice_dir,
            espeak_bin, espeak_data, loader_flag, engine_args,
            g2p_flag, espeak_voice_flag, phoneme_flag)
    end
    local piper_bin = engine.piper_cmd or engine.backend_cmd or "piper"
    local model_flag = ""
    local model_path = self:_resolvePiperModel()
    if model_path then
        model_flag = string.format(' --model "%s"', model_path)
    end
    local speaker_flag = ""
    if engine.piper_speaker and engine.piper_speaker > 0 then
        speaker_flag = string.format(' --speaker %d', engine.piper_speaker)
    end
    local length_scale = 1.0 / math.max(0.25, engine.rate)
    local length_flag = ""
    if math.abs(length_scale - 1.0) > 0.01 then
        length_flag = string.format(' --length_scale %.2f', length_scale)
    end
    local exec_prefix = ""
    if engine.piper_model_dir then
        -- Newer Piper tarballs keep .so files in piper/lib/; older ones are flat.
        local piper_lib = engine.piper_model_dir .. "/lib"
        local dir_ok = os.execute('test -d "' .. piper_lib .. '" 2>/dev/null')
        if not (dir_ok == 0 or dir_ok == true) then
            piper_lib = engine.piper_model_dir
        end
        local plugin_dir = engine.plugin_dir
            or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
        local espeak_lib = plugin_dir .. "/espeak-ng/lib"
        local ld_linux = espeak_lib .. "/ld-linux-armhf.so.3"
        local ld_f = io.open(ld_linux, "r")
        if ld_f then
            ld_f:close()
            -- Include /usr/lib:/lib as a final fallback so Piper can find
            -- libpthread, libm, libc etc. on Kindles where espeak-ng/lib does
            -- not bundle every glibc dependency (issue #11).
            local lib_path = piper_lib .. ":" .. espeak_lib .. ":/usr/lib:/lib"
            exec_prefix = string.format('"%s" --library-path "%s" ',
                ld_linux, lib_path)
            local espeak_data_dir = engine.piper_model_dir .. "/espeak-ng-data"
            local ed_f = io.open(espeak_data_dir .. "/phontab", "r")
            if ed_f then
                ed_f:close()
                model_flag = model_flag
                    .. string.format(' --espeak_data "%s"', espeak_data_dir)
            end
        else
            exec_prefix = string.format(
                'LD_LIBRARY_PATH="%s:%s:/usr/lib:/lib" ESPEAK_DATA_PATH="%s" ',
                piper_lib, espeak_lib, engine.piper_model_dir)
        end
    end
    return string.format('nice -n 19 %s%s%s%s%s',
        exec_prefix, piper_bin, model_flag, speaker_flag, length_flag)
end

--[[--
Build a JSON line for Piper's --json-input mode.
@param text string
@param output_file string
@return string  JSON line ending with \n
--]]
function PiperQueue:_buildJsonLine(text, output_file)
    local clean = self:_cleanText(text)
    clean = clean:gsub("\\", "\\\\")
    clean = clean:gsub('"', '\\"')
    clean = clean:gsub("\t", "\\t")
    return string.format('{"text":"%s","output_file":"%s"}\n', clean, output_file)
end

--[[--
Build the shell command for per-process Piper synthesis.
@param text string
@param audio_file string
@return string cmd, string text_file
--]]
function PiperQueue:buildCommand(text, audio_file)
    local base = self:buildBaseCommand()
    local engine = self.engine
    engine.file_counter = (engine.file_counter or 0) + 1
    local text_file = "/tmp/audiobook_piper_in_"
        .. os.time() .. "_" .. engine.file_counter .. ".txt"
    local tf = io.open(text_file, "w")
    local cmd
    if engine.backend == engine.BACKENDS.SANOTTS
        or engine.backend == engine.BACKENDS.SANOTTS_JP then
        -- snt_server / snt_jp_server read one JSON line per utterance from
        -- stdin and write the WAV at the path given inside the line.
        if tf then
            tf:write(self:_buildJsonLine(text, audio_file))
            tf:close()
        end
        cmd = string.format('%s < "%s" 2>&1', base, text_file)
    else
        if tf then
            tf:write(self:_cleanText(text) .. "\n")
            tf:close()
        end
        cmd = string.format('%s --output_file "%s" < "%s" 2>&1',
            base, audio_file, text_file)
    end
    return cmd, text_file
end

-- ── Server lifecycle ─────────────────────────────────────────────────

--[[--
Pick the next server (round-robin).
@return number  1-based server id
--]]
function PiperQueue:_pickServer()
    local count = _pool_count(self.engine)
    self._server_rr = (self._server_rr or 0) % count + 1
    return self._server_rr
end

--[[--
Write a JSON line to a server's FIFO via FFI (non-blocking).
@param server_id number
@param json_line string
@return boolean
--]]
function PiperQueue:_writeToPiperFifo(server_id, json_line)
    local server = self._servers[server_id]
    if not server then return false end

    local O_WRONLY   = 1
    local O_NONBLOCK = 2048
    local fd = ffi.C.open(server.fifo, bit.bor(O_WRONLY, O_NONBLOCK))
    if fd < 0 then
        logger.err("PiperQueue: Server", server_id,
            "FIFO open failed, errno:", ffi.errno())
        return false
    end
    local len = #json_line
    local written = tonumber(ffi.C.write(fd, json_line, len))
    ffi.C.close(fd)
    if written ~= len then
        logger.err("PiperQueue: Server", server_id,
            "FIFO write incomplete:", written, "/", len)
        return false
    end
    return true
end

--[[--
Start persistent Piper servers (--json-input).
Model loads once; sentences are sent as JSON lines via FIFO.
--]]
function PiperQueue:startServers()
    if self._abandoned then return end
    if self._servers_running or self._servers_starting then return end

    self._server_start_attempts = (self._server_start_attempts or 0) + 1
    if self._server_start_attempts > 2 then
        logger.warn("PiperQueue: Server start attempts exhausted, per-process mode")
        return
    end

    -- Low-memory guard: Piper neural TTS loads a ~100MB ONNX model into RAM.
    -- On devices with < 80MB free, launching Piper risks OOM-killing KOReader.
    -- sanoTTS is exempt: its int8 model is 680KB with a ~5MB working set.
    -- sanoTTS-jp is exempt too: 654KB weights + a file-backed 13.7MB
    -- dictionary (page cache, evictable) and a ~10MB working set.
    local engine = self.engine
    local mem_available_kb = 0
    if engine.backend ~= engine.BACKENDS.SANOTTS
        and engine.backend ~= engine.BACKENDS.SANOTTS_JP then
        local mf = io.open("/proc/meminfo", "r")
        if mf then
            for line in mf:lines() do
                local kb = line:match("MemAvailable:%s+(%d+)%s+kB")
                if kb then
                    mem_available_kb = tonumber(kb) or 0
                    break
                end
            end
            mf:close()
        end
    end
    if mem_available_kb > 0 and mem_available_kb < 80 * 1024 then
        local mem_mb = math.floor(mem_available_kb / 1024)
        logger.err("PiperQueue: Low memory (", mem_mb, "MB free). Aborting Piper server launch.")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = _("Low memory detected (~" .. mem_mb .. " MB free).\nPiper neural TTS requires more RAM.\nSwitch to the espeak backend for reliable playback."),
            timeout = 6,
        })
        self._servers_starting = false
        return
    end

    local pool = _pool_count(engine)
    logger.warn("PiperQueue: CPU cores:", _cpu_cores,
                "→ SERVER_COUNT:", pool,
                "BATCH_SIZE:", self:_batchSize())

    self._servers_starting = true
    self._servers = {}
    self._server_rr = 0

    -- Kill ALL existing piper processes before launching (the list spans
    -- every backend's server binary; engine switches pass through here).
    os.execute("killall -9 piper snt_server snt_jp_server 2>/dev/null")
    -- Also kill orphan server shell wrappers from a previous crash.
    -- These are /bin/sh processes not caught by killall piper.
    for i = 1, math.max(SERVER_COUNT, pool) do
        local fifo = SERVER_PREFIX .. i
        local pid_file = fifo .. ".pid"
        local piper_pid_file = fifo .. ".piper_pid"
        local pf = io.open(pid_file, "r")
        if pf then
            local pid = pf:read("*a"):gsub("%s+", "")
            pf:close()
            if pid ~= "" then
                os.execute(string.format("kill -9 %s 2>/dev/null", pid))
            end
        end
        local ppf = io.open(piper_pid_file, "r")
        if ppf then
            local pid = ppf:read("*a"):gsub("%s+", "")
            ppf:close()
            if pid ~= "" then
                os.execute(string.format("kill -9 %s 2>/dev/null", pid))
            end
        end
        os.execute(string.format('rm -f "%s" "%s.pid" "%s.piper_pid" "%s.sh" "%s.log"',
            fifo, fifo, fifo, fifo, fifo))
    end
    os.execute("usleep 200000")

    local base_cmd = self:buildBaseCommand()

    for i = 1, pool do
        local fifo = SERVER_PREFIX .. i
        local script_path = fifo .. ".sh"
        local pid_file = fifo .. ".pid"
        local log_file = fifo .. ".log"

        os.execute(string.format('rm -f "%s" "%s" "%s" "%s"',
            fifo, pid_file, script_path, log_file))

        local script = string.format([=[#!/bin/sh
set -e
FIFO="%s"
LOG="%s"
rm -f "$FIFO" "${FIFO}.pid" "${FIFO}.piper_pid"
mkfifo "$FIFO" || { echo "mkfifo failed" >> "$LOG"; exit 1; }
# Verify the FIFO actually exists before declaring readiness.
if [ ! -p "$FIFO" ]; then echo "FIFO missing after mkfifo" >> "$LOG"; exit 1; fi
exec 3<>"$FIFO"
# Launch piper piped to the done-marker writer, as a single background
# pipeline.  $! gives the PID of the rightmost (while-read) subshell.
# We also record piper's PID via a wrapper that writes it before exec.
PIPER_INNER_PID_FILE="${FIFO}.piper_pid"
{
  # This subshell's PID ($BASHPID / $$) is the piper process after exec.
  # But /bin/sh doesn't have $BASHPID; use a bg trick instead.
  %s --json-input --sentence_silence 0 <&3 2>>"$LOG" &
  INNER_PID=$!
  echo "$INNER_PID" > "$PIPER_INNER_PID_FILE"
  wait $INNER_PID
} | while IFS= read -r wav_path; do
  wav_path=$(echo "$wav_path" | tr -d '\r\n')
  if [ -n "$wav_path" ]; then
    echo "0" > "${wav_path}.done"
  fi
done &
PIPE_PID=$!
echo "$PIPE_PID" > "${FIFO}.pid"
cleanup() {
  # Kill piper directly (not just the pipe reader)
  if [ -f "$PIPER_INNER_PID_FILE" ]; then
    INNER=$(cat "$PIPER_INNER_PID_FILE" 2>/dev/null)
    kill $INNER 2>/dev/null
  fi
  kill $PIPE_PID 2>/dev/null
  exec 3>&- 2>/dev/null
  rm -f "$FIFO" "${FIFO}.pid" "${FIFO}.piper_pid"
}
trap cleanup EXIT TERM
wait $PIPE_PID 2>/dev/null
exec 3>&-
rm -f "$FIFO" "${FIFO}.pid" "${FIFO}.piper_pid"
]=], fifo, log_file, base_cmd)

        local sf = io.open(script_path, "w")
        if sf then
            sf:write(script)
            sf:close()
            os.execute('chmod +x "' .. script_path .. '"')
        end
        os.execute(string.format('/bin/sh "%s" &', script_path))
        logger.warn("PiperQueue: Server", i, "launching...")
    end

    -- Poll for all servers to be ready
    local pq = self
    local start_time = UIManager:getTime()
    local function checkServersReady()
        local all_ready = true
        for i = 1, pool do
            if not pq._servers[i] then
                local pid_file = SERVER_PREFIX .. i .. ".pid"
                local pf = io.open(pid_file, "r")
                if pf then
                    local pid = pf:read("*a"):gsub("%s+", "")
                    pf:close()
                    -- Verify the FIFO actually exists before declaring ready.
                    -- Under memory pressure mkfifo can fail silently; the .pid
                    -- file gets written but the FIFO is missing (issue #18).
                    local fifo = SERVER_PREFIX .. i
                    local fifo_ok = false
                    -- Do not wait forever if the FIFO's writer has died.
                    local fd = ffi.C.open(fifo, 2048) -- O_RDONLY | O_NONBLOCK
                    if fd >= 0 then
                        ffi.C.close(fd)
                        fifo_ok = true
                    end
                    if not fifo_ok then
                        logger.warn("PiperQueue: Server", i,
                            "has .pid but FIFO missing — not ready yet")
                        all_ready = false
                    else
                        -- Also read piper's own PID for direct kill capability
                        local piper_pid = nil
                        local ppf = io.open(SERVER_PREFIX .. i .. ".piper_pid", "r")
                        if ppf then
                            local raw = ppf:read("*a"):gsub("%s+", "")
                            piper_pid = tonumber(raw)
                            ppf:close()
                        end
                        pq._servers[i] = {
                            fifo = fifo,
                            pid = tonumber(pid),
                            piper_pid = piper_pid,
                        }
                        logger.warn("PiperQueue: Server", i, "ready, PID:", pid, "piper_pid:", piper_pid)
                    end
                else
                    all_ready = false
                end
            end
        end
        if all_ready then
            pq._servers_running = true
            pq._servers_starting = false
            -- A successful start clears the retry budget.  The counter only
            -- exists to stop rapid retry loops after failures; leaving it
            -- latched would drop the session into slow per-process mode after
            -- any deliberate restart (for example a speed change).
            pq._server_start_attempts = 0
            logger.warn("PiperQueue: All", pool,
                "servers ready in",
                time.to_ms(UIManager:getTime() - start_time), "ms")
            pq:launchNext()
        elseif time.to_ms(UIManager:getTime() - start_time) > 60000 then
            pq._servers_starting = false
            logger.err("PiperQueue: Server startup timed out (60s), per-process fallback")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Piper server failed to start (timeout).\nNeural TTS may be too heavy for this device.\nSwitch to the espeak backend for reliable playback."),
                timeout = 6,
            })
            pq:launchNext()
        else
            UIManager:scheduleIn(0.3, checkServersReady)
        end
    end
    UIManager:scheduleIn(0.3, checkServersReady)
end

--[[--
Stop persistent Piper servers.
--]]
function PiperQueue:stopServers()
    -- No early return: even if we think servers aren't running, there may
    -- be orphan processes from a previous crash.  Always kill by PID file
    -- and killall to be safe.  Sweep the larger legacy pool so slots from a
    -- backend switch are reaped too.
    for i = 1, math.max(SERVER_COUNT, _pool_count(self.engine)) do
        local server = self._servers and self._servers[i]
        if server and server.pid then
            os.execute(string.format("kill %d 2>/dev/null", server.pid))
        end
        -- Also kill the piper process directly via its PID file
        if server and server.piper_pid then
            os.execute(string.format("kill %d 2>/dev/null", server.piper_pid))
        end
        local fifo = SERVER_PREFIX .. i
        -- Read piper_pid from file in case server table is stale
        local ppf = io.open(fifo .. ".piper_pid", "r")
        if ppf then
            local ppid = ppf:read("*a"):gsub("%s+", "")
            ppf:close()
            if ppid ~= "" then
                os.execute(string.format("kill -9 %s 2>/dev/null", ppid))
            end
        end
        os.execute(string.format('rm -f "%s" "%s.pid" "%s.piper_pid" "%s.sh" "%s.log"',
            fifo, fifo, fifo, fifo, fifo))
    end
    os.execute("killall -9 piper snt_server snt_jp_server 2>/dev/null")
    -- Kill wrapper shells that may be orphaned (reparented to init)
    os.execute("pkill -9 -f 'piper_server_.*\\.sh' 2>/dev/null")
    self._servers = {}
    self._servers_running = false
    self._servers_starting = false
    self._slots_busy = 0

    -- Rescue orphaned "pending" entries
    local rescued = 0
    for _, entry in pairs(self._queue) do
        if entry.status == "pending" then
            entry.status = "queued"
            entry.done_marker = entry.file and (entry.file .. ".done") or nil
            rescued = rescued + 1
        end
    end
    logger.warn("PiperQueue: Servers stopped, rescued", rescued, "pending entries")
end

-- ── Real word timing (snt_server timing sidecar) ─────────────────────
--
-- The pq8 and f32 sanoTTS engines already compute a duration per phoneme;
-- they write it beside the WAV as "<wav>.timing".  Reading it back replaces
-- the character-count estimate with the engine's own arithmetic.  Every
-- other backend writes no such file and keeps the estimate.

--[[--
Parse a timing sidecar.
@param path string  Path to the sidecar
@return table|nil  {rate, hop, total, clauses, words}, or nil when the file
                   is missing, unreadable, truncated or an unknown version.
                   nil is the signal to fall back to the estimator.
--]]
function PiperQueue:_parseTimingSidecar(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local side
    for line in f:lines() do
        local tag = line:sub(1, 2)
        if tag == "sn" then
            local magic, ver, rate, hop, total, ncl, nw = line:match(
                "^(%a+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)$")
            if magic ~= "sntt" or tonumber(ver) ~= 1 then
                f:close()
                return nil
            end
            side = {
                rate = tonumber(rate), hop = tonumber(hop), total = tonumber(total),
                n_clauses = tonumber(ncl), n_words = tonumber(nw),
                clauses = {}, words = {},
            }
        elseif side and tag == "c " then
            local j, cs, ce, punct, ss, se, w0, nwd = line:match(
                "^c%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)$")
            if cs then
                side.clauses[#side.clauses + 1] = {
                    char_start = tonumber(cs), char_end = tonumber(ce),
                    punct = tonumber(punct),
                    sample_start = tonumber(ss), sample_end = tonumber(se),
                    word0 = tonumber(w0), nwords = tonumber(nwd),
                }
            end
        elseif side and tag == "w " then
            local idx, ss, se = line:match("^w%s+(%d+)%s+(%d+)%s+(%d+)$")
            if idx then
                side.words[#side.words + 1] = {
                    start_sample = tonumber(ss), end_sample = tonumber(se),
                }
            end
        end
    end
    f:close()

    if not side or side.rate <= 0 or side.hop <= 0 or side.total <= 0 then
        return nil
    end
    -- A short file (the server died mid-write) must not be trusted.
    if #side.clauses ~= side.n_clauses or #side.words ~= side.n_words then
        return nil
    end
    return side
end

--[[--
Count the words a timing array for this text holds: whitespace tokens
carrying at least one non-punctuation character, matching the tokenization
in TTSEngine:generateTimingEstimates.
@param text string
@return number
--]]

-- ── Japanese highlight units ────────────────────────────────────────────
-- Mirrors the sanoTTS-jp server's per-character classifier
-- (sanotts-jp/snt_jp_server.c) so sidecar spans map one to one: every
-- character except whitespace and CJK punctuation, with small kana and the
-- long-vowel mark merged into the preceding unit.

local function utf8_cp_at(s, i)
    local b = s:byte(i)
    if not b then return nil, 0 end
    if b < 0x80 then return b, 1 end
    if b < 0xE0 then
        return (b % 0x20) * 0x40 + ((s:byte(i + 1) or 0) % 0x40), 2
    end
    if b < 0xF0 then
        return (b % 0x10) * 0x1000
               + ((s:byte(i + 1) or 0) % 0x40) * 0x40
               + ((s:byte(i + 2) or 0) % 0x40), 3
    end
    if b < 0xF8 then
        return (b % 0x08) * 0x40000
               + ((s:byte(i + 1) or 0) % 0x40) * 0x1000
               + ((s:byte(i + 2) or 0) % 0x40) * 0x40
               + ((s:byte(i + 3) or 0) % 0x40), 4
    end
    return b, 1
end

local function cp_is_small_kana_jp(cp)
    return cp == 0x3041 or cp == 0x3043 or cp == 0x3045 or cp == 0x3047
        or cp == 0x3049 or cp == 0x3063 or cp == 0x3083 or cp == 0x3085
        or cp == 0x3087 or cp == 0x3095 or cp == 0x3096
        or cp == 0x30A1 or cp == 0x30A3 or cp == 0x30A5 or cp == 0x30A7
        or cp == 0x30A9 or cp == 0x30C3 or cp == 0x30E3 or cp == 0x30E5
        or cp == 0x30E7 or cp == 0x30F5 or cp == 0x30F6
        or (cp >= 0xFF67 and cp <= 0xFF6F)
end

local function cp_is_prolong_jp(cp)
    return cp == 0x30FC or cp == 0xFF70
end

local function cp_is_jp_skip_jp(cp)
    return cp == 32 or cp == 9 or cp == 10 or cp == 13
        or cp == 0x3001 or cp == 0x3002
        or cp == 0xFF0C or cp == 0xFF0E
        or cp == 0xFF01 or cp == 0xFF1F
        or cp == 0xFF1B or cp == 0xFF1A
        or cp == 0x2026 or cp == 0x2015 or cp == 0x2025
        or (cp >= 0x300C and cp <= 0x300F)
        or cp == 0xFF08 or cp == 0xFF09
end

-- Per-character highlight units for Japanese text.
local function jp_timing_units(text)
    local units = {}
    local i, n = 1, #text
    while i <= n do
        local cp, w = utf8_cp_at(text, i)
        w = w or 1
        if cp_is_jp_skip_jp(cp) then
            i = i + w
        else
            local us, ue = i, i + w - 1
            i = i + w
            while i <= n do
                local c2, w2 = utf8_cp_at(text, i)
                if c2 and (cp_is_small_kana_jp(c2) or cp_is_prolong_jp(c2)) then
                    ue = i + w2 - 1
                    i = i + w2
                else break end
            end
            units[#units + 1] = text:sub(us, ue)
        end
    end
    return units
end

local function countTimingWords(text)
    local n = 0
    for word in text:gmatch("%S+") do
        if (word:gsub("[%p]", "")) ~= "" then n = n + 1 end
    end
    return n
end

--[[--
Build a flat per-word timing array for one sentence from the sidecar.
@param side table        Parsed sidecar
@param first_clause number  First clause index (1-based) of this sentence
@param last_clause number   Last clause index of this sentence
@param seg_start number  Sentence segment start, in WAV samples
@param seg_end number    Sentence segment end, in WAV samples
@param text string       Sentence text
@return table|nil  Array of {word, start_time, end_time} in ms relative to
                   the segment, or nil when the sentence's word count does
                   not match the engine's spoken word groups, in which case
                   the caller falls back to the estimator for this sentence.

                   The counts differ for two reasons, both in espeak and
                   neither fixable here without changing the audio. Merging
                   dominates: espeak joins unstressed function words to their
                   neighbour, so "in the" and "from the" come back as single
                   groups and a sentence can lose several groups this way
                   (measured on the benchmark prose, about a quarter of
                   sentences). Expansion is the other: espeak spells numbers
                   out, so "1984" becomes three groups for one word. Per-word
                   phonemization does not recover the boundary either, since
                   espeak de-stresses and reduces those words in context, so
                   the isolated form is a different phone sequence.
--]]
function PiperQueue:_buildSentenceTiming(side, first_clause, last_clause, seg_start, seg_end, text)
    if not side or last_clause < first_clause or seg_end <= seg_start then
        return nil
    end

    local spans = {}
    for j = first_clause, last_clause do
        local c = side.clauses[j]
        if not c then return nil end
        for k = c.word0, c.word0 + c.nwords - 1 do
            local w = side.words[k + 1]   -- sidecar word indices are 0-based
            if not w then return nil end
            spans[#spans + 1] = w
        end
    end
    -- Japanese has no whitespace words: the sanoTTS-jp server emits one
    -- span per highlight unit (character), so accept either the whitespace
    -- word count or the jp unit count.
    local words_ws = {}
    local n_ws = 0
    for word in text:gmatch("%S+") do
        if (word:gsub("[%p]", "")) ~= "" then
            n_ws = n_ws + 1
            words_ws[#words_ws + 1] = word
        end
    end
    local units = jp_timing_units(text)
    local n_units = #units
    local cjk = (#spans == n_units) and (n_units ~= n_ws)
    if #spans ~= n_ws and #spans ~= n_units then return nil end

    local recs, i = {}, 0
    if cjk then
        for _, word in ipairs(units) do
            i = i + 1
            local w = spans[i]
            local s = math.floor((w.start_sample - seg_start) * 1000 / side.rate)
            local e = math.floor((w.end_sample - seg_start) * 1000 / side.rate)
            if s < 0 then s = 0 end
            if e <= s then e = s + 1 end
            recs[#recs + 1] = { word = word, start_time = s, end_time = e }
        end
    else
        for _, word in ipairs(words_ws) do
            i = i + 1
            local w = spans[i]
            local s = math.floor((w.start_sample - seg_start) * 1000 / side.rate)
            local e = math.floor((w.end_sample - seg_start) * 1000 / side.rate)
            if s < 0 then s = 0 end
            if e <= s then e = s + 1 end
            recs[#recs + 1] = { word = word, start_time = s, end_time = e }
        end
    end
    if #recs == 0 then return nil end

    -- Anchor the last word to the segment end.  play() and SyncController
    -- rescale a timing array by real_duration / last_end, so landing the
    -- last word exactly on the segment length makes those divisions 1 and
    -- leaves the real times untouched.
    local last = recs[#recs]
    local seg_ms = math.floor((seg_end - seg_start) * 1000 / side.rate)
    if seg_ms > last.start_time then last.end_time = seg_ms end
    return recs
end

--[[--
Map the plugin's sentences onto the server's clauses using the character
territories the sidecar records.  The territories partition the cleaned
request string, so a clause belongs to the sentence whose range it starts in.
@param side table           Parsed sidecar
@param cleaned_parts table  Per-sentence cleaned text
@param ref string           The cleaned joined text the server received
@return table|nil, table|nil  Per-sentence {first,last,seg_start,seg_end} and
                              the sample boundary array, or nil when the
                              territories do not form a clean partition (the
                              caller then keeps the estimated split).
--]]
function PiperQueue:_mapSentencesToClauses(side, cleaned_parts, ref)
    if table.concat(cleaned_parts, " ") ~= ref then return nil end

    local sent_first, sent_last = {}, {}
    local j, pos = 1, 0
    for i, part in ipairs(cleaned_parts) do
        local stop = pos + #part
        local first = j
        while j <= #side.clauses and side.clauses[j].char_start < stop do
            j = j + 1
        end
        if j - 1 < first then return nil end
        sent_first[i], sent_last[i] = first, j - 1
        pos = stop + 1   -- the join space
    end
    if j <= #side.clauses then return nil end

    local out, bounds = {}, {}
    for i = 1, #sent_first do
        bounds[i] = side.clauses[sent_first[i]].sample_start
        out[i] = { first = sent_first[i], last = sent_last[i] }
    end
    bounds[#out + 1] = side.total
    if bounds[1] ~= 0 then return nil end
    for i = 1, #out do
        out[i].seg_start, out[i].seg_end = bounds[i], bounds[i + 1]
        if out[i].seg_end <= out[i].seg_start then return nil end
    end
    return out, bounds
end

--[[--
Note which timing source an utterance used, for the bug report.
@param real boolean  True when the engine's own per-phoneme durations were
                     used, false when TTSEngine:generateTimingEstimates ran
                     instead.  Counters live on the engine so the bug report
                     can read them off plugin.tts_engine.
--]]
function PiperQueue:_noteTimingSource(real)
    local e = self.engine
    if not e then return end
    if real then
        e._piper_timing_real = (e._piper_timing_real or 0) + 1
    else
        e._piper_timing_estimated = (e._piper_timing_estimated or 0) + 1
    end
end

-- ── Queue management ─────────────────────────────────────────────────

--[[--
Add a sentence to the prefetch queue.
@param text string
--]]
--- Disable the queue for the rest of the session (SyncController's Piper
--- abandon and RTF escalation set this; stop() clears it so the next
--- playback start tries Piper again).  While set, no server is launched
--- and no sentence is queued, so espeak fallbacks never churn server
--- processes on slow devices.
function PiperQueue:setAbandoned(flag)
    self._abandoned = flag and true or nil
end

function PiperQueue:enqueue(text)
    if self._abandoned then return end
    if not text or text == "" then return end
    if self._queue[text] then return end  -- already queued

    local engine = self.engine
    engine.file_counter = (engine.file_counter or 0) + 1
    local audio_file = "/tmp/audiobook_piper_pf_"
        .. os.time() .. "_" .. engine.file_counter .. ".wav"

    self._queue[text] = {
        file        = audio_file,
        text_file   = nil,
        done_marker = audio_file .. ".done",
        timing_file = audio_file .. ".timing",
        timing      = nil,
        status      = "queued",
    }
    table.insert(self._queue_order, text)

    logger.dbg("PiperQueue: Queued:", text:sub(1, 40),
        "(size:", #self._queue_order, ")")

    if self._servers_running then
        self:launchNext()
    end
end

--[[--
Launch the next queued batch via persistent server (or per-process fallback).
--]]
function PiperQueue:launchNext()
    if self._abandoned then return end
    local engine = self.engine

    -- Start servers if needed
    if not self._servers_running then
        self:startServers()
        if self._servers_starting then return end
    end

    local max_concurrent = self._servers_running
        and (_pool_count(engine) * MAX_PIPELINE_DEPTH) or 2
    self._slots_busy = self._slots_busy or 0
    if self._slots_busy >= max_concurrent then return end

    -- Gather consecutive "queued" entries
    local batch_size = self:_batchSize()
    local batch_texts   = {}
    local batch_entries = {}
    for _, text in ipairs(self._queue_order) do
        local e = self._queue[text]
        if e and e.status == "queued" then
            table.insert(batch_texts, text)
            table.insert(batch_entries, e)
            if #batch_texts >= batch_size then break end
        end
    end
    if #batch_texts == 0 then return end

    -- Mark batch as pending
    for _, e in ipairs(batch_entries) do e.status = "pending" end

    local primary_text  = batch_texts[1]
    local primary_entry = batch_entries[1]
    local combined_audio_file  = primary_entry.file
    local combined_done_marker = primary_entry.done_marker

    -- ── Persistent server path ──
    if self._servers_running then
        local server_id = self:_pickServer()
        local combined_text = table.concat(batch_texts, " ")
        local json_line = self:_buildJsonLine(combined_text, combined_audio_file)

        local ok = self:_writeToPiperFifo(server_id, json_line)
        if not ok then
            logger.warn("PiperQueue: Server", server_id, "FIFO dead, trying alternate")
            for alt = 1, _pool_count(engine) do
                if alt ~= server_id then
                    ok = self:_writeToPiperFifo(alt, json_line)
                    if ok then
                        server_id = alt
                        logger.warn("PiperQueue: Alternate server", alt, "accepted batch")
                        break
                    end
                end
            end
        end

        if not ok then
            logger.err("PiperQueue: All server FIFOs failed, per-process fallback")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Piper neural TTS servers stopped responding.\nThis often happens on devices with limited RAM or CPU.\nSwitch to the espeak backend for reliable playback."),
                timeout = 6,
            })
            for _, e in ipairs(batch_entries) do e.status = "queued" end
            self._servers_running = false
            self:stopServers()
        else
            logger.warn("PiperQueue: BATCH → server", server_id, ":",
                #batch_texts, "sentences (",
                combined_text:sub(1, 60), ")")

            -- Prevent tryFinalize from racing with our poll
            for _, e in ipairs(batch_entries) do e.done_marker = nil end

            self._slots_busy = (self._slots_busy or 0) + 1

            -- Poll for .done marker, then split the combined WAV
            local pq = self
            local poll_count = 0
            local max_polls = 900  -- 180s
            local function pollDone()
                if not pq._queue[primary_text] then
                    os.remove(combined_audio_file)
                    os.remove(combined_done_marker)
                    os.remove(combined_audio_file .. ".timing")
                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                    return
                end
                poll_count = poll_count + 1
                local mf = io.open(combined_done_marker, "r")
                if mf then
                    mf:close()
                    os.remove(combined_done_marker)
                    local total_size = engine:getFileSize(combined_audio_file)
                    if not total_size or total_size <= 0 then
                        for _, t in ipairs(batch_texts) do
                            local e = pq._queue[t]
                            if e then e.status = "failed" end
                        end
                        logger.err("PiperQueue: Batch done but empty WAV")
                        pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                        pq:launchNext()
                        return
                    end

                    local synth_ms = poll_count * 200
                    logger.warn("PiperQueue: BATCH READY in", synth_ms, "ms:",
                        #batch_texts, "sentences, size:", total_size)

                    -- Track the realtime factor for slow-device auto-degrade
                    local audio_ms = WavUtils.getDurationMs(combined_audio_file)
                    self:_recordRtfSample(synth_ms, audio_ms, #batch_texts)

                    local sidecar_path = combined_audio_file .. ".timing"
                    local side = pq:_parseTimingSidecar(sidecar_path)

                    if #batch_texts == 1 then
                        WavUtils.applyFade(combined_audio_file, 15)
                        local real = side and pq:_buildSentenceTiming(
                            side, 1, #side.clauses, 0, side.total, primary_text)
                        pq:_noteTimingSource(real ~= nil)
                        if real then
                            primary_entry.timing = real
                            logger.warn("PiperQueue: real word timing for",
                                #real, "words (sidecar)")
                        else
                            engine:generateTimingEstimates(primary_text)
                            primary_entry.timing = engine.timing_data
                        end
                        primary_entry.status = "ready"
                    else
                        -- The server cleans the joined text before it sees it,
                        -- so the sidecar's character territories are offsets
                        -- into the cleaned string.  Rebuild that same string
                        -- here; if a cleaning pattern spans a sentence join the
                        -- parts will not reassemble and the sidecar is ignored
                        -- for this batch.
                        local cleaned = {}
                        for i, t in ipairs(batch_texts) do
                            cleaned[i] = pq:_cleanText(t)
                        end
                        local plan, bounds
                        if side then
                            plan, bounds = pq:_mapSentencesToClauses(side, cleaned,
                                pq:_cleanText(table.concat(batch_texts, " ")))
                        end

                        local output_paths = {}
                        local first_seg_tmp = combined_audio_file .. ".seg1"
                        for i, _ in ipairs(batch_texts) do
                            if i == 1 then
                                table.insert(output_paths, first_seg_tmp)
                            else
                                table.insert(output_paths, batch_entries[i].file)
                            end
                        end

                        local split_ok
                        if plan then
                            -- Exact cut points from the engine: no syllable
                            -- estimate, no proportional rounding.
                            split_ok = WavUtils.splitFileAtSamples(
                                combined_audio_file, bounds, output_paths)
                        else
                            -- Estimate per-sentence duration from syllable counts
                            local durations = {}
                            local total_syllables = 0
                            for _, t in ipairs(batch_texts) do
                                local count = 0
                                for word in t:gmatch("%S+") do
                                    count = count + engine:countSyllables(
                                        word:gsub("[%p]", ""))
                                end
                                count = math.max(count, 1)
                                table.insert(durations, count)
                                total_syllables = total_syllables + count
                            end

                            local total_dur_ms = audio_ms
                            local est_durations_ms = {}
                            for _, syl in ipairs(durations) do
                                table.insert(est_durations_ms,
                                    math.floor(total_dur_ms * syl / total_syllables))
                            end
                            split_ok = WavUtils.splitFile(
                                combined_audio_file, est_durations_ms, output_paths)
                        end

                        if split_ok then
                            os.remove(combined_audio_file)
                            os.rename(first_seg_tmp, combined_audio_file)
                        else
                            os.remove(first_seg_tmp)
                        end

                        if split_ok then
                            local real_count = 0
                            for i, t in ipairs(batch_texts) do
                                local e = pq._queue[t]
                                if e then
                                    WavUtils.applyFade(e.file, 15)
                                    local real = plan and pq:_buildSentenceTiming(
                                        side, plan[i].first, plan[i].last,
                                        plan[i].seg_start, plan[i].seg_end, t)
                                    pq:_noteTimingSource(real ~= nil)
                                    if real then
                                        e.timing = real
                                        real_count = real_count + 1
                                    else
                                        engine:generateTimingEstimates(t)
                                        e.timing = engine.timing_data
                                    end
                                    e.status = "ready"
                                end
                            end
                            logger.warn("PiperQueue: Batch split OK,",
                                #batch_texts, "sentences ready, exact split=",
                                plan ~= nil, "real timing=", real_count)
                        else
                            engine:generateTimingEstimates(primary_text)
                            primary_entry.timing = engine.timing_data
                            primary_entry.status = "ready"
                            for i = 2, #batch_texts do
                                local e = pq._queue[batch_texts[i]]
                                if e then e.status = "failed" end
                            end
                            logger.err("PiperQueue: Batch split failed, only first ready")
                        end
                    end
                    os.remove(sidecar_path)

                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                    return
                end
                if poll_count < max_polls then
                    UIManager:scheduleIn(0.2, pollDone)
                else
                    for _, t in ipairs(batch_texts) do
                        local e = pq._queue[t]
                        if e then e.status = "failed" end
                    end
                    logger.err("PiperQueue: Batch timed out")
                    os.remove(combined_done_marker)
                    os.remove(combined_audio_file .. ".timing")
                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                end
            end
            UIManager:scheduleIn(0.2, pollDone)

            -- Fill remaining server slots
            self:launchNext()
            return
        end
    end

    -- ── Per-process fallback ──
    local text_to_launch = batch_texts[1]
    local entry = batch_entries[1]
    for i = 2, #batch_entries do batch_entries[i].status = "queued" end

    local audio_file   = entry.file
    local done_marker  = entry.done_marker

    local cmd, text_file = self:buildCommand(text_to_launch, audio_file)
    entry.text_file = text_file

    local bg_cmd = string.format('(%s; echo $? > "%s") &', cmd, done_marker)
    logger.dbg("PiperQueue: Prefetch (per-process):", text_to_launch:sub(1, 40))
    os.execute(bg_cmd)
    self._slots_busy = (self._slots_busy or 0) + 1

    local pq = self
    local poll_count = 0
    local max_polls = 300  -- 60s
    local function pollDone()
        local e = pq._queue[text_to_launch]
        if not e then
            os.remove(audio_file)
            os.remove(done_marker)
            os.remove(audio_file .. ".timing")
            if text_file then os.remove(text_file) end
            pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
            pq:launchNext()
            return
        end
        poll_count = poll_count + 1
        local mf = io.open(done_marker, "r")
        if mf then
            local exit_code = mf:read("*a"):gsub("%s+", "")
            mf:close()
            os.remove(done_marker)
            if text_file then os.remove(text_file) end
            local af = io.open(audio_file, "r")
            if af then
                af:close()
                local size = engine:getFileSize(audio_file)
                if size and size > 0 then
                    -- The per-process fallback runs the same server, so the
                    -- sidecar can be there too.
                    local sc = audio_file .. ".timing"
                    local sside = pq:_parseTimingSidecar(sc)
                    local real = sside and pq:_buildSentenceTiming(
                        sside, 1, #sside.clauses, 0, sside.total, text_to_launch)
                    pq:_noteTimingSource(real ~= nil)
                    if real then
                        e.timing = real
                    else
                        engine:generateTimingEstimates(text_to_launch)
                        e.timing = engine.timing_data
                    end
                    e.status = "ready"
                    os.remove(sc)
                    pq:_recordRtfSample(poll_count * 200,
                        WavUtils.getDurationMs(audio_file), 1)
                    logger.dbg("PiperQueue: Prefetch ready:",
                        text_to_launch:sub(1, 40), "size:", size)
                    pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
                    pq:launchNext()
                    return
                end
            end
            e.status = "failed"
            logger.err("PiperQueue: Prefetch failed:",
                text_to_launch:sub(1, 40), "exit:", exit_code)
            pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
            pq:launchNext()
            return
        end
        if poll_count < max_polls then
            UIManager:scheduleIn(0.2, pollDone)
        else
            e.status = "failed"
            logger.err("PiperQueue: Prefetch timed out:", text_to_launch:sub(1, 40))
            if text_file then os.remove(text_file) end
            os.remove(done_marker)
            os.remove(audio_file .. ".timing")
            pq._slots_busy = math.max(0, (pq._slots_busy or 0) - 1)
            pq:launchNext()
        end
    end
    UIManager:scheduleIn(0.2, pollDone)
end

--[[--
Synchronously check a pending entry's .done marker.
Closes the race between background process completion and UIManager poll.
@param text string
--]]
function PiperQueue:tryFinalize(text)
    local entry = self._queue[text]
    if not entry or entry.status ~= "pending" then return end
    if not entry.done_marker then return end

    local mf = io.open(entry.done_marker, "r")
    if not mf then return end

    local exit_code = mf:read("*a"):gsub("%s+", "")
    mf:close()
    os.remove(entry.done_marker)
    if entry.text_file then os.remove(entry.text_file) end

    local engine = self.engine
    local af = io.open(entry.file, "r")
    if af then
        af:close()
        local size = engine:getFileSize(entry.file)
        if size and size > 0 then
            local sc = entry.file .. ".timing"
            local sside = self:_parseTimingSidecar(sc)
            local real = sside and self:_buildSentenceTiming(
                sside, 1, #sside.clauses, 0, sside.total, text)
            self:_noteTimingSource(real ~= nil)
            if real then
                entry.timing = real
            else
                engine:generateTimingEstimates(text)
                entry.timing = engine.timing_data
            end
            entry.status = "ready"
            os.remove(sc)
            logger.dbg("PiperQueue: Sync-finalized:", text:sub(1, 40), "size:", size)
            self._slots_busy = math.max(0, (self._slots_busy or 0) - 1)
            self:launchNext()
            return
        end
    end

    entry.status = "failed"
    logger.err("PiperQueue: Sync-finalize FAILED:", text:sub(1, 40), "exit:", exit_code)
    self._slots_busy = math.max(0, (self._slots_busy or 0) - 1)
    self:launchNext()
end

--[[--
Check if a prefetched entry is ready and consume it.
Tries to finalize pending entries first.
@param text string
@return string|nil file, table|nil timing
--]]
function PiperQueue:useReady(text)
    local entry = self._queue[text]
    if not entry then return nil, nil end
    if entry.status == "pending" then self:tryFinalize(text) end
    if entry.status ~= "ready" or not entry.file then return nil, nil end
    -- Remove from queue (promoted to current)
    self._queue[text] = nil
    for i, t in ipairs(self._queue_order) do
        if t == text then table.remove(self._queue_order, i); break end
    end
    logger.dbg("PiperQueue: Using queued audio")
    return entry.file, entry.timing
end

--[[--
Peek without consuming.
@param text string
@return string|nil file, table|nil timing, number dur_ms
--]]
function PiperQueue:peek(text)
    local entry = self._queue[text]
    if not entry then return nil, nil, 0 end
    if entry.status == "pending" then self:tryFinalize(text) end
    if entry.status == "ready" and entry.file then
        local dur = WavUtils.getDurationMs(entry.file)
        return entry.file, entry.timing, dur
    end
    return nil, nil, 0
end

--[[--
Check if entry is ready.
@param text string
@return boolean
--]]
function PiperQueue:isReady(text)
    local entry = self._queue[text]
    return entry and entry.status == "ready"
end

--[[--
Get entry status.
@param text string
@return string|nil  "queued"/"pending"/"ready"/"failed" or nil
--]]
function PiperQueue:getStatus(text)
    local entry = self._queue[text]
    if entry then return entry.status end
    return nil
end

--[[--
Remove entry unconditionally, return file+timing (ownership transfer).
Used by concat pipeline to take ownership of the WAV file.
@param text string
@return string|nil file, table|nil timing
--]]
function PiperQueue:consume(text)
    local entry = self._queue[text]
    if entry then
        self._queue[text] = nil
        for i, t in ipairs(self._queue_order) do
            if t == text then table.remove(self._queue_order, i); break end
        end
        return entry.file, entry.timing
    end
    return nil, nil
end

--[[--
Diagnostic snapshot string.
@return string
--]]
function PiperQueue:getSnapshot()
    local counts = { queued = 0, pending = 0, ready = 0, failed = 0 }
    for _, entry in pairs(self._queue or {}) do
        local st = entry.status or "unknown"
        counts[st] = (counts[st] or 0) + 1
    end
    return string.format("queued=%d pending=%d ready=%d failed=%d total=%d",
        counts.queued, counts.pending, counts.ready, counts.failed,
        #(self._queue_order or {}))
end

-- ── Realtime-factor tracking (slow-device auto-degrade) ─────────────

--[[--
Record one synthesis timing sample.
@param synth_ms number  Wall time the batch took
@param audio_ms number  Duration of the produced audio
@param n_sentences number  Sentences in the batch
--]]
function PiperQueue:_recordRtfSample(synth_ms, audio_ms, n_sentences)
    if not synth_ms or synth_ms <= 0 or not audio_ms or audio_ms <= 0 then
        return
    end
    self._rtf_samples = self._rtf_samples or {}
    table.insert(self._rtf_samples, {
        rtf = synth_ms / audio_ms,
        synth_ms = synth_ms,
        n = n_sentences or 1,
    })
    if #self._rtf_samples > 6 then
        table.remove(self._rtf_samples, 1)
    end
    self._rtf_total_samples = (self._rtf_total_samples or 0) + 1
    logger.dbg("PiperQueue: RTF sample:", string.format("%.2f", synth_ms / audio_ms),
        "(", synth_ms, "ms synth /", audio_ms, "ms audio )")
end

--[[--
Rolling realtime factor (synthesis time / audio duration).  Values above
1.0 mean Piper cannot keep up with playback.  Returns nil until at least
3 batches have completed, so callers don't act on cold-start noise.
@return number|nil
--]]
function PiperQueue:getRtf()
    if (self._rtf_total_samples or 0) < 3 then return nil end
    local s = self._rtf_samples
    if not s or #s == 0 then return nil end
    local sum, n = 0, 0
    for i = math.max(1, #s - 2), #s do
        sum = sum + s[i].rtf
        n = n + 1
    end
    if n == 0 then return nil end
    return sum / n
end

--[[--
Total number of RTF samples recorded (monotonic, used as an escalation
checkpoint marker).
@return number
--]]
function PiperQueue:getRtfSampleCount()
    return self._rtf_total_samples or 0
end

--[[--
Average synthesis wall time per sentence, in seconds (for user-facing
wait estimates).  Returns nil when no samples exist yet.
@return number|nil
--]]
function PiperQueue:getAvgSentenceSynthS()
    local s = self._rtf_samples
    if not s or #s == 0 then return nil end
    local sum = 0
    for _, smp in ipairs(s) do
        sum = sum + smp.synth_ms / math.max(1, smp.n)
    end
    return (sum / #s) / 1000
end

--[[--
Move a queued entry to the front of the dispatch order so the currently
needed sentence is synthesized before lookahead entries (low-resource mode).
No-op when the entry is missing or already dispatched.
@param text string
--]]
function PiperQueue:prioritize(text)
    local entry = self._queue[text]
    if not entry or entry.status ~= "queued" then return end
    for i, t in ipairs(self._queue_order) do
        if t == text then
            if i > 1 then
                table.remove(self._queue_order, i)
                table.insert(self._queue_order, 1, text)
                logger.dbg("PiperQueue: Prioritized:", text:sub(1, 40))
            end
            return
        end
    end
end

--[[--
Enqueue multiple sentences and kick the launcher.
@param texts table  Array of sentence texts
--]]
function PiperQueue:batchEnqueue(texts)
    for _, text in ipairs(texts) do
        if text and text ~= "" then
            self:enqueue(text)
        end
    end
    self:launchNext()
end

-- ── Cleanup ──────────────────────────────────────────────────────────

--[[--
Kill orphan piper processes.
When servers are running, only kills per-process piper instances
(those not managed by persistent servers) by targeting the specific
nice-wrapped piper command pattern.  When servers are NOT running,
kills all piper processes unconditionally.
--]]
function PiperQueue:killOrphanProcesses()
    if self._servers_running then
        -- Servers are managed — don't kill them.
        -- Per-process fallback piper instances are unlikely when servers
        -- are active, but if any exist they'll die naturally when their
        -- output pipe is consumed.  No action needed.
        logger.dbg("PiperQueue: Servers active, skipping killall")
    else
        os.execute("killall -9 piper snt_server 2>/dev/null")
        -- Also kill server wrapper shells that might be orphaned
        os.execute("pkill -9 -f 'piper_server_.*\\.sh' 2>/dev/null")
        logger.dbg("PiperQueue: Killed all piper processes + wrapper shells")
    end
end

--[[--
Clean the queue: delete all WAV/marker files, reset state.
Does NOT stop persistent servers.
--]]
function PiperQueue:cleanQueue()
    self:killOrphanProcesses()
    for _, entry in pairs(self._queue) do
        if entry.file then os.remove(entry.file) end
        if entry.done_marker then os.remove(entry.done_marker) end
        if entry.text_file then os.remove(entry.text_file) end
        if entry.timing_file then os.remove(entry.timing_file) end
    end
    self._queue = {}
    self._queue_order = {}
    self._slots_busy = 0
end

--[[--
Full shutdown: clean queue AND stop servers.
--]]
function PiperQueue:shutdown()
    self:cleanQueue()
    self:stopServers()
end

return PiperQueue
