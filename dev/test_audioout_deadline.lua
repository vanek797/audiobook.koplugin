-- Deterministic Linux socket mocks: no real daemon or device is touched.
local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local now,closed,mode,chunks,commands,send_calls,connect_calls,err
local function reset(m)
    now=0;closed=0;mode=m or {};chunks={};commands={};send_calls=0;connect_calls=0;err=11
end
local ffi={C={},cdef=function()end,new=function()return {}end,copy=function()end,
 cast=function(_,x)return x end,sizeof=function()return 110 end,
 string=function(buf,n)return buf.data:sub(1,n)end,errno=function()return err end}
ffi.C.socket=function(_,flags)assert(flags==2049,'connect must not block');return 7 end
ffi.C.connect=function()
    connect_calls=connect_calls+1
    if mode.refused then err=111;return -1 end
    if mode.backlog or (mode.connect_delay and now<mode.connect_delay) then err=11;return -1 end
    return 0
end
ffi.C.send=function(_,_,size,flags)
    assert(flags==16384,'MSG_NOSIGNAL is required')
    send_calls=send_calls+1
    if mode.send_stall then err=11;return -1 end
    return math.min(size,mode.partial_send or size)
end
ffi.C.recv=function(_,buf)
    if mode.closed then return 0 end
    if #chunks==0 then err=11;return -1 end
    local data=table.remove(chunks,1);buf.data=data;return #data
end
ffi.C.close=function()closed=closed+1 end
ffi.C.usleep=function(us)now=now+us/1000000 end
package.loaded.ffi=ffi
package.loaded.logger={dbg=function()end,warn=function()end}
package.loaded['ui/time']={now=function()return now end,ms=function(x)return x/1000 end}
package.loaded.json={encode=function()return '{}'end,decode=function(s)
    if s=='{"ok":true}' then return {ok=true} end
    if s=='{"event":"idle"}' then return {event='idle'} end
    error('invalid frame')
end}
local env=setmetatable({os={execute=function(cmd)commands[#commands+1]=cmd end}},{__index=_G})
local loader=assert(loadfile(root..'audioout.lua'));setfenv(loader,env)
local AudioOut=loader()
local function request(m)
    reset(m);local a=AudioOut:new{};local response,reason=a:_command({cmd='stop'},250)
    assert(closed==1);return response,reason,a
end
local response,reason=request({backlog=true})
assert(not response and reason=='connect timeout' and now<=.256 and send_calls==0)
print('PASS full listen backlog has a bounded connect deadline')
response,reason=request({send_stall=true})
assert(not response and reason=='send timeout' and now<=.256)
print('PASS blocked send cannot escape the command deadline')
response,reason=request({})
assert(not response and reason=='timeout' and now<=.256)
print('PASS silent daemon has a bounded receive deadline')
response,reason=request({connect_delay=.2})
assert(not response and reason=='timeout' and now<=.256)
print('PASS connect/send/receive share one total deadline')
reset({partial_send=1});chunks={'{"event":"idle"}\n{"ok":','true}\n'}
local a=AudioOut:new{};response=a:_command({},250)
assert(response.ok and a:takeEvent().event=='idle' and closed==1 and send_calls==3)
print('PASS partial writes and split JSON frames are handled')
response,reason=request({closed=true});assert(not response and reason=='closed' and now==0)
print('PASS closed peer fails without spinning')
response,reason=request({refused=true});assert(not response and reason=='connect' and now==0)
print('PASS refused connection fails immediately')
reset();a=AudioOut:new{};local limits={}
a._command=function(_,command,limit)limits[command.cmd]=limit;return {ok=true} end
a:stop();a:release();a:stopDaemon()
assert(limits.stop==250 and limits.release==500 and limits.shutdown==200)
assert(#commands==2 and commands[2]:find('killall -9 audioout',1,true))
print('PASS teardown budgets and synchronous hard-kill fallback are retained')
-- Exercise the actual engine stop function with all non-audioout work stubbed.
local f=assert(io.open(root..'ttsengine.lua'));local source=f:read('*a');f:close()
local body=assert(source:match('(function TTSEngine:stop%(%)%s.-)\n%-%-%[%[%-%-\nCheck if GStreamer'))
local E={};env=setmetatable({TTSEngine=E,logger={dbg=function()end,warn=function()end}},{__index=_G})
setfenv(assert(loadstring(body)),env)()
local function engine(success)
    local calls={}
    local e=setmetatable({is_speaking=true,_audioout_active=true,backend='none',BACKENDS={},
        _cancelHTTP=function()end,
        _stopKindleKeepalive=function()end,_androidPrefetchInvalidate=function()end,
        _killAudioProcess=function()end,fullCleanup=function(self)self.cleaned=true end,
        _audioout_client={
            stop=function()calls[#calls+1]='stop';if success then return {ok=true} end;return nil,'connect timeout' end,
            release=function()calls[#calls+1]='release';return {ok=true} end,
            stopDaemon=function()calls[#calls+1]='kill' end,
        }},{__index=E})
    return e,calls
end
local e,calls=engine(false);e:stop()
assert(table.concat(calls,',')=='stop,kill' and e.cleaned and not e.is_speaking and not e._audioout_active)
print('PASS engine stop kills an unreachable daemon and completes cleanup')
e,calls=engine(true);e:stop()
assert(table.concat(calls,',')=='stop,release' and e.cleaned)
print('PASS responsive daemon retains graceful stop/release')
print('ALL 10 AUDIOOUT DEADLINE CHECKS PASSED')
