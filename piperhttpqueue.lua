-- Bounded, ordered lookahead over PiperHTTP. Exactly one network worker runs.
local Queue = {}
Queue.MAX_BYTES = 32 * 1024 * 1024
Queue.MAX_AHEAD = 8

function Queue.key(options)
    local fields = {}
    for _, field in ipairs({"url", "voice", "rate", "volume", "text"}) do
        local value = tostring(options[field] or "")
        fields[#fields + 1] = #value .. ":" .. value
    end
    return table.concat(fields)
end

function Queue:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.entries, o.order, o.wanted, o.bytes = {}, {}, {}, 0
    o.max_bytes = o.max_bytes or self.MAX_BYTES
    o.hits, o.downloads = 0, 0
    return o
end

function Queue:_drop(key)
    local entry = self.entries[key]
    if not entry then return end
    if entry.path then
        os.remove(entry.path)
        self.bytes = self.bytes - entry.size
    end
    self.entries[key] = nil
end

function Queue:cancel()
    self.current, self.waiter = nil, nil
    self.client:cancel()
    for key in pairs(self.entries) do self:_drop(key) end
    self.order, self.wanted, self.bytes = {}, {}, 0
end

function Queue:_start(options, key)
    local job = { key = key, options = options }
    self.current = job
    self.downloads = self.downloads + 1
    local function done(path, reason)
        if self.current ~= job then
            if path then os.remove(path) end
            return
        end
        self.current = nil
        local waiter = self.waiter
        if waiter and waiter.key == key then
            self.waiter = nil
            -- Ownership of this WAV transfers to the engine, not the cache.
            self:_drop(key)
            waiter.callback(path, reason)
        elseif path and self.wanted[key] then
            local f = io.open(path, "rb")
            local size = f and f:seek("end")
            if f then f:close() end
            if size and self.bytes + size <= self.max_bytes then
                self.entries[key] = { path = path, size = size }
                self.bytes = self.bytes + size
            else
                os.remove(path)
                -- Do not repeatedly redownload a far-away phrase while full.
                self.entries[key] = { budget = true, size = size or self.max_bytes + 1 }
            end
        else
            if path then os.remove(path) end
            if self.wanted[key] then self.entries[key] = { failed = reason or "Prefetch failed" } end
        end
        self:_pump()
    end
    local started, err = self.client:request(options, done)
    if not started then done(nil, err) end
end

function Queue:_pump()
    if self.current then return end
    if self.waiter then
        self:_start(self.waiter.options, self.waiter.key)
        return
    end
    for _, key in ipairs(self.order) do
        if not self.entries[key] then
            self:_start(self.wanted[key], key)
            return
        end
    end
end

-- Replace the window rather than appending forever. Files outside it are
-- deleted, including on seeks/page changes. A foreground request is retained.
function Queue:plan(options_list, limit)
    limit = math.max(0, math.min(self.MAX_AHEAD, math.floor(tonumber(limit) or 0)))
    local order, wanted = {}, {}
    for i = 1, math.min(limit, #options_list) do
        local options = options_list[i]
        local key = Queue.key(options)
        if not wanted[key] then
            wanted[key] = options
            order[#order + 1] = key
        end
    end
    self.order, self.wanted = order, wanted
    local job = self.current
    if job and not wanted[job.key] and not (self.waiter and self.waiter.key == job.key) then
        self.current = nil
        self.client:cancel()
    end
    for key, entry in pairs(self.entries) do
        if not wanted[key] then
            self:_drop(key)
        elseif entry.budget and self.bytes + entry.size <= self.max_bytes then
            self.entries[key] = nil
        end
    end
    self:_pump()
end

-- Use a ready WAV; promote an in-flight prefetch of the same phrase; otherwise
-- cancel a lower-priority prefetch so the current sentence never waits behind N.
function Queue:request(options, callback)
    local key = Queue.key(options)
    self.wanted[key] = nil
    for i = #self.order, 1, -1 do
        if self.order[i] == key then table.remove(self.order, i) end
    end
    self.waiter = { key = key, options = options, callback = callback }
    local entry = self.entries[key]
    if entry and entry.path then
        local file = io.open(entry.path, "rb")
        local intact = file and file:seek("end") == entry.size
        if file then file:close() end
        if not intact then self:_drop(key); entry = nil end
    end
    if entry and entry.path then
        self.entries[key] = nil
        self.bytes = self.bytes - entry.size
        self.hits = self.hits + 1
        self.waiter = nil
        callback(entry.path)
        self:_pump()
        return true
    end
    if entry then self:_drop(key) end -- retry a failed speculative request once
    if self.current and self.current.key ~= key then
        self.current = nil
        self.client:cancel()
    end
    self:_pump()
    return true
end

return Queue
