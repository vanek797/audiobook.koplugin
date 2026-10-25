-- Host-only checks for the conservative Kobo patch; requires LuaJIT.
local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local function read(name)
    local f=assert(io.open(root..name));local s=f:read('*a');f:close();return s
end
local source=read('synccontroller.lua')
local body=assert(source:match('(function SyncController:_reserveBarSpace%(%)%s.-)\n%-%-%[%[%-%-'))
local SC={};local env=setmetatable({SyncController=SC},{__index=_G})
setfenv(assert(loadstring(body)),env)()
local calls=0
local function controller(opt_in)
    return setmetatable({plugin={
        getSetting=function(_,_,default)if opt_in==nil then return default end;return opt_in end,
        ui={rolling={}},
        _ensureAudiobookChromeMargins=function()calls=calls+1;return true end,
    }},{__index=SC})
end
local c=controller();c:_reserveBarSpace()
assert(calls==0 and not c._bar_space_reserved and c._bar_space_reflowed==false)
print('PASS default TTS start leaves EPUB margins alone')
c=controller(true);c:_reserveBarSpace()
assert(calls==1 and c._bar_space_reserved and c._bar_space_reflowed)
c:_reserveBarSpace();assert(calls==1 and not c._bar_space_reflowed)
print('PASS explicit opt-in preserves the upstream inset and is idempotent')
source=read('piperqueue.lua')
assert(source:find('ffi.C.open(fifo, 2048)',1,true))
assert(not source:find('io.open(fifo, "r")',1,true))
print('PASS FIFO readiness uses a nonblocking open (source invariant)')
source=read('audioout.lua')
assert(source:find('function AudioOut:release() return self:_command({ cmd = "release" }, 8000) end',1,true))
assert(not source:find('commandAsync',1,true))
source=read('ttsengine.lua')
assert(source:find('self._audioout_client:stopDaemon()',1,true))
assert(not source:find('audioout stop/release scheduled',1,true))
print('PASS original synchronous daemon teardown is retained (source invariant)')
print('ALL 4 KOBO SAFETY CHECKS PASSED')
