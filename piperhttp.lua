-- Remote Piper synthesis. HTTP runs in a killable child, never in the UI loop.
local PiperHTTP = {}
PiperHTTP.DEFAULT_VOICE = "ru_RU-irina-medium"
PiperHTTP.VOICES = {
    { id = "ru_RU-irina-medium", label = "Irina — Russian (medium)" },
    { id = "en_US-amy-medium", label = "Amy — English (medium)" },
    { id = "de_DE-ramona-low", label = "Ramona — German (low)" },
}
PiperHTTP.MAX_AUDIO_BYTES = 16 * 1024 * 1024

function PiperHTTP.validateURL(value)
    if type(value) ~= "string" then return nil, "Set the Piper HTTP server URL in Voice settings." end
    local url = value:match("^%s*(.-)%s*$"):gsub("/+$", "")
    if not url:match("^http://[^/%s]+$") or url:find("[?@#]") then
        return nil, "Enter an HTTP server URL, including the port, without a path or credentials."
    end
    return url
end

function PiperHTTP.isWav(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local header = file:read(12) or ""
    local size = file:seek("end") or 0
    file:close()
    return #header == 12 and header:sub(1, 4) == "RIFF"
        and header:sub(9, 12) == "WAVE" and size > 44
end

-- Apply attenuation in the HTTP worker, so legacy players need no mixer or
-- GStreamer volume plugin. Piper returns little-endian PCM16 WAV audio.
function PiperHTTP.scaleWav(path, gain)
    gain = math.max(0, math.min(1, tonumber(gain) or 1))
    if gain == 1 then return true end
    local f, err = io.open(path, "r+b")
    if not f then return nil, tostring(err) end
    local function fail(reason) f:close(); return nil, reason end
    local function le16(s) return s:byte(1) + s:byte(2) * 256 end
    local function le32(s) return le16(s:sub(1, 2)) + le16(s:sub(3, 4)) * 65536 end
    local size = f:seek("end")
    f:seek("set", 0)
    local header = f:read(12) or ""
    if header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        return fail("Invalid WAV header")
    end
    local position, pcm16, data_position, data_size = 12, false
    while position + 8 <= size do
        f:seek("set", position)
        local chunk = f:read(8)
        if not chunk or #chunk ~= 8 then return fail("Truncated WAV chunk") end
        local length = le32(chunk:sub(5, 8))
        local start = position + 8
        if start + length > size then return fail("Truncated WAV data") end
        if chunk:sub(1, 4) == "fmt " and length >= 16 then
            local format = f:read(16)
            pcm16 = le16(format:sub(1, 2)) == 1 and le16(format:sub(15, 16)) == 16
        elseif chunk:sub(1, 4) == "data" then
            data_position, data_size = start, length
        end
        position = start + length + length % 2
    end
    if not pcm16 or not data_position or data_size % 2 ~= 0 then
        return fail("Piper HTTP volume requires PCM16 WAV audio")
    end
    local offset = 0
    while offset < data_size do
        f:seek("set", data_position + offset)
        local block = f:read(math.min(4096, data_size - offset))
        if not block or #block == 0 or #block % 2 ~= 0 then return fail("Short WAV read") end
        local scaled
        if gain == 0 then
            scaled = string.rep("\0", #block)
        else
            local samples = {}
            for i = 1, #block, 2 do
                local value = block:byte(i) + block:byte(i + 1) * 256
                if value >= 32768 then value = value - 65536 end
                value = math.floor(value * gain + 0.5)
                if value < 0 then value = value + 65536 end
                samples[#samples + 1] = string.char(value % 256, math.floor(value / 256))
            end
            scaled = table.concat(samples)
        end
        f:seek("set", data_position + offset)
        local written, reason = f:write(scaled)
        if not written then return fail(tostring(reason)) end
        offset = offset + #block
    end
    local closed, reason = f:close()
    if not closed then return nil, tostring(reason) end
    return true
end

-- Only called inside the worker (or isolated tests). No shell or external curl.
function PiperHTTP.fetch(options, path)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local json = require("json")
    local socketutil = require("socketutil")
    local part = path .. ".part"
    local file, err = io.open(part, "wb")
    if not file then return nil, "Cannot create temporary audio: " .. tostring(err) end
    local bytes = 0
    local body = json.encode({
        text = options.text, voice = options.voice, length_scale = 1 / options.rate,
    })
    local function sink(chunk)
        if not chunk then return 1 end
        bytes = bytes + #chunk
        if bytes > PiperHTTP.MAX_AUDIO_BYTES then return nil, "Audio response is too large" end
        local ok, reason = file:write(chunk)
        if not ok then return nil, reason end
        return 1
    end
    socketutil:set_timeout(10, 10)
    local ok, result, code = pcall(http.request, {
        url = options.url .. "/synthesize", method = "POST", redirect = false,
        headers = { ["Content-Type"] = "application/json", ["Content-Length"] = tostring(#body) },
        source = ltn12.source.string(body), sink = sink,
    })
    socketutil:reset_timeout()
    local closed = file:close()
    if not ok or not result or tonumber(code) ~= 200 or not closed then
        os.remove(part)
        return nil, "Piper HTTP request failed: " .. tostring(ok and code or result)
    end
    if not PiperHTTP.isWav(part) then
        os.remove(part)
        return nil, "Piper HTTP returned invalid or empty WAV audio."
    end
    local scaled, scale_error = PiperHTTP.scaleWav(part, options.volume)
    if not scaled then os.remove(part); return nil, scale_error end
    local renamed, reason = os.rename(part, path)
    if not renamed then os.remove(part); return nil, tostring(reason) end
    return true
end

function PiperHTTP:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.util = o.util or require("ffi/util")
    o.ui = o.ui or require("ui/uimanager")
    o.time = o.time or require("ui/time")
    o.kill = o.kill or function(pid) require("ffi").C.kill(pid, 9) end
    return o
end

local function cleanup(job, keep_audio)
    os.remove(job.path .. ".part")
    os.remove(job.error_path)
    os.remove(job.base)
    if not keep_audio then os.remove(job.path) end
end

function PiperHTTP:cancel()
    local job = self.job
    if not job then return end
    self.job = nil
    if job.poll then self.ui:unschedule(job.poll) end
    -- Termination is immediate; only reaping may be retried later. Shutdown
    -- does not depend on a future UI callback to stop network/file activity.
    self.util.terminateSubProcess(job.pid)
    -- util kills the worker's process group. Very early cancellation can
    -- precede the child's setpgid(), so also target the unreaped child PID.
    if not self.util.isSubProcessDone(job.pid) then self.kill(job.pid) end
    cleanup(job)
    local function reap()
        if self.util.isSubProcessDone(job.pid) then cleanup(job); return end
        self.ui:scheduleIn(0.1, reap)
    end
    reap()
end

function PiperHTTP:request(options, callback)
    self:cancel()
    local url, err = PiperHTTP.validateURL(options.url)
    if not url then return nil, err end
    if type(options.text) ~= "string" or options.text == "" or #options.text > 32768 then
        return nil, "Piper HTTP expects between 1 and 32768 bytes of text."
    end
    local voice = options.voice or PiperHTTP.DEFAULT_VOICE
    if type(voice) ~= "string" or not voice:match("^[%w_%-]+$") then
        return nil, "Invalid Piper HTTP voice name."
    end
    local rate = math.max(0.25, math.min(2, tonumber(options.rate) or 1))
    local timeout = math.max(5, math.min(120, tonumber(options.timeout) or 30))
    local base = os.tmpname()
    local job = { base = base, path = base .. ".wav", error_path = base .. ".error" }
    local request = { url = url, text = options.text, voice = voice, rate = rate,
        volume = math.max(0, math.min(1, tonumber(options.volume) or 1)) }
    local pid, fork_error = self.util.runInSubProcess(function()
        local ok, success, reason = pcall(PiperHTTP.fetch, request, job.path)
        if not ok or not success then
            local f = io.open(job.error_path, "w")
            if f then f:write(tostring(ok and reason or success)); f:close() end
        end
    end)
    if not pid then cleanup(job); return nil, tostring(fork_error) end
    job.pid = pid
    job.deadline = self.time.now() + self.time.s(timeout)
    self.job = job
    job.poll = function()
        if self.job ~= job then return end
        if self.util.isSubProcessDone(pid) then
            self.job = nil
            if PiperHTTP.isWav(job.path) then
                cleanup(job, true)
                callback(job.path)
            else
                local f = io.open(job.error_path, "r")
                local reason = f and f:read(512) or "Piper HTTP worker exited without audio."
                if f then f:close() end
                cleanup(job)
                callback(nil, reason)
            end
        elseif self.time.now() >= job.deadline then
            self:cancel()
            callback(nil, "Piper HTTP timed out. Check the server address and Wi-Fi.")
        else
            self.ui:scheduleIn(0.1, job.poll)
        end
    end
    self.ui:scheduleIn(0.1, job.poll)
    return true
end

return PiperHTTP
