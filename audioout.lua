--[[ audioout.lua -- client for the audioout daemon (Tier 2).

The daemon (audioout.c, dev/audioout/PLAN.md) owns the audio pipeline: it
stays up across clips, feeds them gaplessly, and reports a real
rendered-position clock measured by a sink-pad probe. This module is its
KOReader-side half: lifecycle (spawn/kill), command transport, and status
polling.

Transport follows the mpv FFI client in mediaengine.lua: AF_UNIX stream
socket, one connection per command, SO_RCVTIMEO so a wedged daemon can
never freeze the UI. The daemon is line-JSON in, line-JSON out.

Completion is polled, not pushed: compare status().done_count against the
value taken when the play was issued, or check state == "idle" once
fed_end_ms is reached.
]]

local ffi = require("ffi")
local logger = require("logger")

pcall(function() ffi.cdef[[
    int socket(int domain, int type, int protocol);
    int connect(int sockfd, const struct sockaddr *addr, unsigned int addrlen);
    int send(int sockfd, const void *buf, unsigned long len, int flags);
    long recv(int sockfd, void *buf, unsigned long len, int flags);
    int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
    int close(int fd);
    int usleep(unsigned int usec);
    struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
    struct timeval { long tv_sec; long tv_usec; };
]] end)

local AudioOut = {
    SOCKET_PATH = "/tmp/audiobook_audioout.sock",
    LOG_PATH = "/tmp/audiobook_audioout.log",
    DAEMON = "audioout",
    -- Bounded per-command waits: a busy daemon answers in one tick (10 ms).
    COMMAND_TIMEOUT_MS = 2000,
    STARTUP_WAIT_MS = 4000,
}

local AF_UNIX, SOCK_STREAM = 1, 1
local SOL_SOCKET, SO_RCVTIMEO = 1, 20

function AudioOut:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.socket_path = o.socket_path or self.SOCKET_PATH
    o.daemon_path = o.daemon_path -- plugin_dir .. "/audioout/audioout"
    o.log_path = o.log_path or self.LOG_PATH
    o.rate = o.rate or 22050
    o.channels = o.channels or 1
    o.volume = o.volume or 1.0
    return o
end

-- One command, one connection. Returns the decoded JSON table of the
-- first response line, or nil + reason.
function AudioOut:_command(cmd_table, timeout_ms)
    local ok_json, json = pcall(require, "json")
    if not ok_json or not json then
        return nil, "no json module"
    end
    timeout_ms = timeout_ms or self.COMMAND_TIMEOUT_MS
    local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 then return nil, "socket" end
    local addr = ffi.new("struct sockaddr_un")
    addr.sun_family = AF_UNIX
    ffi.copy(addr.sun_path, self.socket_path:sub(1, 107))
    local rc = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr),
                             ffi.sizeof(addr))
    if rc ~= 0 then
        ffi.C.close(fd)
        return nil, "connect"
    end
    -- Each recv blocks at most 50 ms; the loop bounds the total wait.
    local tv = ffi.new("struct timeval")
    tv.tv_sec = 0
    tv.tv_usec = 50 * 1000
    pcall(function()
        ffi.C.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, tv, ffi.sizeof(tv))
    end)
    local payload = json.encode(cmd_table) .. "\n"
    ffi.C.send(fd, payload, #payload, 0)
    local buf = ffi.new("char[4096]")
    local out = nil
    local attempts = math.ceil(timeout_ms / 50)
    while attempts > 0 and not out do
        attempts = attempts - 1
        local n = ffi.C.recv(fd, buf, 4096, 0)
        if n and n > 0 then
            for line in ffi.string(buf, n):gmatch("[^\r\n]+") do
                local ok2, decoded = pcall(json.decode, line)
                if ok2 and type(decoded) == "table" then
                    if decoded.event then
                        self._last_event = decoded   -- surfaced via takeEvent
                    else
                        out = decoded
                    end
                end
            end
        end
    end
    ffi.C.close(fd)
    if out then return out end
    return nil, self._last_event and "event only" or "timeout"
end

function AudioOut:isRunning()
    local resp = self:_command({ cmd = "ping" }, 400)
    return resp ~= nil and resp.ok == true
end

-- Spawn the daemon and wait for its socket. Returns true, or nil + reason.
function AudioOut:start()
    self._daemon_generation = (self._daemon_generation or 0) + 1
    if self:isRunning() then
        return true
    end
    if not self.daemon_path or not self.daemon_path:match("%S") then
        return nil, "no daemon path"
    end
    -- Derive the fifo from the socket path; keep them distinct even if a
    -- custom socket path does not end in .sock (the daemon cannot open a
    -- fifo that collides with the socket file).
    local fifo = self:fifoPath()
    local cmd = string.format(
        '%s --socket "%s" --fifo "%s" --rate %d --channels %d --volume %.2f' ..
        ' > /dev/null 2>> "%s" &',
        self.daemon_path, self.socket_path, fifo,
        self.rate, self.channels, self.volume, self.log_path)
    logger.dbg("AudioOut: spawning daemon:", cmd)
    os.execute(cmd)
    local attempts = math.ceil(self.STARTUP_WAIT_MS / 100)
    while attempts > 0 do
        attempts = attempts - 1
        if self:isRunning() then
            logger.dbg("AudioOut: daemon up")
            return true
        end
        ffi.C.usleep(100 * 1000)
    end
    -- A wedged daemon process answers nothing and blocks the socket: kill
    -- it, clear the path, spawn once more.
    logger.warn("AudioOut: daemon not up; killing stale instance and retrying")
    os.execute("killall -9 audioout 2>/dev/null; rm -f " .. self.socket_path)
    os.execute(cmd)
    attempts = math.ceil(self.STARTUP_WAIT_MS / 100)
    while attempts > 0 do
        attempts = attempts - 1
        if self:isRunning() then
            logger.warn("AudioOut: daemon up after stale kill")
            return true
        end
        ffi.C.usleep(100 * 1000)
    end
    return nil, "daemon did not come up"
end

function AudioOut:stopDaemon()
    local UIManager = require("ui/uimanager")
    self._daemon_generation = (self._daemon_generation or 0) + 1
    local generation = self._daemon_generation
    self:commandAsync({ cmd = "shutdown" }, 500, function()
        UIManager:scheduleIn(0.3, function()
            -- Never kill a daemon started by a newer reading session.
            if self._daemon_generation ~= generation then return end
            os.execute("killall audioout 2>/dev/null; rm -f "
                .. string.format("%q", self.socket_path))
        end)
    end)
end

-- Startup must not sleep/poll in the UI thread. Callback is invoked once.
function AudioOut:startAsync(callback, is_current)
    local UIManager = require("ui/uimanager")
    local time = require("ui/time")
    self._daemon_generation = (self._daemon_generation or 0) + 1
    local generation = self._daemon_generation
    local function current()
        return self._daemon_generation == generation and (not is_current or is_current())
    end
    self:commandAsync({ cmd = "ping" }, 400, function(response)
        if not current() then return end
        if response and response.ok then callback(true); return end
        if not self.daemon_path or not self.daemon_path:match("%S") then
            callback(nil, "no daemon path"); return
        end
        local function spawn()
            os.execute(string.format(
                '%s --socket %q --fifo %q --rate %d --channels %d --volume %.2f > /dev/null 2>> %q &',
                self.daemon_path, self.socket_path, self:fifoPath(), self.rate,
                self.channels, self.volume, self.log_path))
        end
        spawn()
        local deadline = time.now() + time.ms(self.STARTUP_WAIT_MS)
        local retried = false
        local function poll()
            if not current() then return end
            self:commandAsync({ cmd = "ping" }, 200, function(reply)
                if not current() then return end
                if reply and reply.ok then callback(true); return end
                if time.now() >= deadline then
                    if retried then callback(nil, "daemon did not come up"); return end
                    retried = true
                    os.execute("killall -9 audioout 2>/dev/null; rm -f "
                        .. string.format("%q", self.socket_path))
                    spawn()
                    deadline = time.now() + time.ms(self.STARTUP_WAIT_MS)
                end
                UIManager:scheduleIn(0.1, poll)
            end)
        end
        UIManager:scheduleIn(0.1, poll)
    end)
end

function AudioOut:play(path, opts)
    opts = opts or {}
    return self:_command({
        cmd = "play",
        path = path,
        gap_ms = opts.gap_ms or 0,
        rate = opts.rate or self.rate,
        channels = opts.channels or self.channels,
        alsa_device = opts.alsa_device,
    }, 8000)
end

function AudioOut:pause() return self:_command({ cmd = "pause" }) end
-- resume with pos_ms (external mode) re-epochs the daemon's clock at that
-- position instead of the legacy byte-derived rebaseline.
function AudioOut:resume(pos_ms)
    if pos_ms then
        return self:_command({ cmd = "resume", pos_ms = pos_ms })
    end
    return self:_command({ cmd = "resume" })
end
function AudioOut:stop() return self:_command({ cmd = "stop" }) end
-- play and flush may rebuild the pipeline, which takes seconds on ARM.
function AudioOut:flush() return self:_command({ cmd = "flush" }, 8000) end
-- Tear the pipeline down without killing the daemon: session stop. The
-- next play() rebuilds lazily.
function AudioOut:release()
    -- Release is fire-and-forget; callers do not consume a response.
    return self:commandAsync({ cmd = "release" }, 8000)
end

-- External stream mode (media path): an outside writer (ffmpeg) feeds the
-- fifo; the daemon builds the pipeline and reports the probe clock.
-- alsa_device selects the output PCM on ALSA devices (bluealsa). pos_ms and
-- total_ms place the stream on the client's timeline (book position and
-- length): the daemon's clock, status cap and completion latch all speak
-- book positions from then on.
function AudioOut:externalStart(rate, channels, alsa_device, pos_ms, total_ms, path)
    return self:_command({ cmd = "external", rate = rate or 44100,
                           channels = channels or 2, alsa_device = alsa_device,
                           pos_ms = pos_ms, total_ms = total_ms,
                           path = path }, 8000)
end

-- True when the running daemon was built with in-process decode (it then
-- accepts compressed files directly in external mode). Cached.
function AudioOut:hasDecoder()
    if self._has_decoder == nil then
        local st = self:status(400)
        self._has_decoder = (st and st.decoder == 1) or false
    end
    return self._has_decoder
end

-- External mode: drop the old stream's bytes and re-epoch the clock at
-- pos_ms. The caller respawns its feeder after this returns. total_ms
-- updates the completion target.
function AudioOut:seek(pos_ms, total_ms)
    return self:_command({ cmd = "seek", pos_ms = pos_ms,
                           total_ms = total_ms }, 8000)
end

function AudioOut:fifoPath()
    if self._fifo_path then return self._fifo_path end
    local fifo = self.socket_path:gsub("%.sock$", ".fifo")
    if fifo == self.socket_path then fifo = self.socket_path .. ".fifo" end
    self._fifo_path = fifo
    return fifo
end
function AudioOut:setVolume(v)
    return self:_command({ cmd = "volume", value_x1000 = math.floor(v * 1000 + 0.5) })
end
-- Nonblocking transport for commands issued by the UI thread. One socket per
-- request; retain partial JSON frames and enforce a wall-clock deadline.
function AudioOut:commandAsync(command, timeout_ms, callback)
    local UIManager = require("ui/uimanager")
    local time = require("ui/time")
    local json = require("json")
    local deadline = time.now() + time.ms(timeout_ms or self.COMMAND_TIMEOUT_MS)
    local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM + 2048, 0) -- Linux SOCK_NONBLOCK
    local finished = false
    local function finish(response, reason)
        if finished then return end
        finished = true
        if fd >= 0 then ffi.C.close(fd) end
        if callback then callback(response, reason) end
    end
    if fd < 0 then finish(nil, "socket"); return end
    local addr = ffi.new("struct sockaddr_un")
    addr.sun_family = AF_UNIX
    ffi.copy(addr.sun_path, self.socket_path:sub(1, 107))
    local connected = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr)) == 0
    if not connected then
        local err = ffi.errno()
        if err ~= 115 and err ~= 11 then finish(nil, "connect"); return end
    end
    local payload, offset, received = json.encode(command) .. "\n", 0, ""
    local function tick()
        if finished then return end
        if time.now() >= deadline then finish(nil, "timeout"); return end
        if offset < #payload then
            -- MSG_NOSIGNAL prevents a closed daemon socket from killing KOReader.
            local n = ffi.C.send(fd, payload:sub(offset + 1), #payload - offset, 16384)
            if n > 0 then
                offset = offset + tonumber(n)
            elseif n < 0 then
                local err = ffi.errno()
                if err ~= 11 and err ~= 4 and err ~= 107 then
                    finish(nil, "send"); return
                end
            end
        end
        if offset == #payload then
            local buf = ffi.new("char[4096]")
            -- Bound work per tick even if the daemon floods unsolicited events.
            for _ = 1, 4 do
                local n = ffi.C.recv(fd, buf, 4096, 0)
                if n == 0 then finish(nil, "closed"); return end
                if n < 0 then
                    local err = ffi.errno()
                    if err ~= 11 and err ~= 4 then finish(nil, "recv"); return end
                    break
                end
                received = received .. ffi.string(buf, n)
                if #received > 65536 then finish(nil, "response too large"); return end
                while true do
                    local ending = received:find("\n", 1, true)
                    if not ending then break end
                    local line = received:sub(1, ending - 1)
                    received = received:sub(ending + 1)
                    local ok, value = pcall(json.decode, line)
                    if ok and type(value) == "table" then
                        if value.event then self._last_event = value
                        else finish(value); return end
                    end
                end
            end
        end
        UIManager:scheduleIn(0.02, tick)
    end
    UIManager:scheduleIn(0, tick)
    return function() finish(nil, "cancelled") end
end

-- Keep the synchronous API for media-engine callers which require an
-- immediate capability probe. TTS polling uses statusCached instead.
function AudioOut:status(timeout_ms)
    return self:_command({ cmd = "status" }, timeout_ms)
end

function AudioOut:statusCached(timeout_ms)
    local time = require("ui/time")
    local now = time.now()
    if not self._status_pending and (not self._status_requested_at
        or now - self._status_requested_at >= time.ms(100)) then
        self._status_pending = true
        self._status_requested_at = now
        local epoch = self._status_epoch
        self:commandAsync({ cmd = "status" }, timeout_ms or 400, function(response)
            self._status_pending = false
            if epoch ~= self._status_epoch then return end
            self._status_cache = response
            self._status_time = time.now()
        end)
    end
    if self._status_time and time.now() - self._status_time <= time.ms(750) then
        return self._status_cache
    end
end
function AudioOut:takeEvent()
    local e = self._last_event
    self._last_event = nil
    return e
end

return AudioOut
