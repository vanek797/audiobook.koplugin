--[[ audioout.lua -- client for the audioout daemon (Tier 2).

The daemon (audioout.c, dev/audioout/PLAN.md) owns the audio pipeline: it
stays up across clips, feeds them gaplessly, and reports a real
rendered-position clock measured by a sink-pad probe. This module is its
KOReader-side half: lifecycle (spawn/kill), command transport, and status
polling.

Transport uses a Linux nonblocking AF_UNIX stream socket, one connection
per command, with a single deadline covering connect/send/receive. Commands
remain synchronous but bounded, including during UI/USB teardown. The daemon
is line-JSON in, line-JSON out.

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
    -- Linux SOCK_NONBLOCK: the old receive timeout did not cover connect()
    -- or send(), so a full daemon listen backlog could freeze the UI forever.
    local fd = ffi.C.socket(AF_UNIX, SOCK_STREAM + 2048, 0)
    if fd < 0 then return nil, "socket" end
    local addr = ffi.new("struct sockaddr_un")
    addr.sun_family = AF_UNIX
    ffi.copy(addr.sun_path, self.socket_path:sub(1, 107))
    local time = require("ui/time")
    local deadline = time.now() + time.ms(timeout_ms)
    local function finish(response, reason)
        ffi.C.close(fd)
        return response, reason
    end
    local connected = false
    while time.now() < deadline do
        local rc = ffi.C.connect(fd, ffi.cast("struct sockaddr *", addr), ffi.sizeof(addr))
        local err = rc ~= 0 and ffi.errno() or 0
        if rc == 0 or err == 106 then -- EISCONN
            connected = true
            break
        end
        -- A nonblocking Unix connect can return EAGAIN for a full backlog;
        -- retry it instead of entering a blocking connect before the deadline.
        if err ~= 11 and err ~= 4 and err ~= 115 and err ~= 114 then
            return finish(nil, "connect")
        end
        ffi.C.usleep(5000)
    end
    if not connected then return finish(nil, "connect timeout") end
    local payload = json.encode(cmd_table) .. "\n"
    local sent = 0
    while sent < #payload and time.now() < deadline do
        local n = ffi.C.send(fd, payload:sub(sent + 1), #payload - sent, 16384) -- MSG_NOSIGNAL
        if n > 0 then
            sent = sent + tonumber(n)
        elseif n < 0 then
            local err = ffi.errno()
            if err ~= 11 and err ~= 4 then return finish(nil, "send") end
        end
        if sent < #payload then ffi.C.usleep(5000) end
    end
    if sent < #payload then return finish(nil, "send timeout") end
    local buf = ffi.new("char[4096]")
    local received = ""
    while time.now() < deadline do
        local n = ffi.C.recv(fd, buf, 4096, 0)
        if n == 0 then return finish(nil, "closed") end
        if n > 0 then
            received = received .. ffi.string(buf, n)
            if #received > 65536 then return finish(nil, "response too large") end
            while true do
                local ending = received:find("\n", 1, true)
                if not ending then break end
                local line = received:sub(1, ending - 1)
                received = received:sub(ending + 1)
                local ok2, decoded = pcall(json.decode, line)
                if ok2 and type(decoded) == "table" then
                    if decoded.event then self._last_event = decoded
                    else return finish(decoded) end
                end
            end
        elseif n < 0 then
            local err = ffi.errno()
            if err ~= 11 and err ~= 4 then return finish(nil, "recv") end
        end
        ffi.C.usleep(5000)
    end
    return finish(nil, "timeout")
end

function AudioOut:isRunning()
    local resp = self:_command({ cmd = "ping" }, 400)
    return resp ~= nil and resp.ok == true
end

-- Spawn the daemon and wait for its socket. Returns true, or nil + reason.
function AudioOut:start()
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
    self:_command({ cmd = "shutdown" }, 200)
    -- Cleanup must finish before KOReader exits for USB mode. A wedged
    -- GStreamer teardown may never process SIGTERM, so retain a hard fallback.
    os.execute("killall audioout 2>/dev/null")
    ffi.C.usleep(100000)
    os.execute("killall -9 audioout 2>/dev/null; rm -f "
        .. string.format("%q", self.socket_path))
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
function AudioOut:stop() return self:_command({ cmd = "stop" }, 250) end
-- play and flush may rebuild the pipeline, which takes seconds on ARM.
function AudioOut:flush() return self:_command({ cmd = "flush" }, 8000) end
-- Tear the pipeline down without killing the daemon: session stop. The
-- next play() rebuilds lazily.
function AudioOut:release() return self:_command({ cmd = "release" }, 500) end

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
function AudioOut:status(timeout_ms)
    return self:_command({ cmd = "status" }, timeout_ms)
end
function AudioOut:takeEvent()
    local e = self._last_event
    self._last_event = nil
    return e
end

return AudioOut
