-- Isolated deterministic tests: exercise patched code, no Kobo binaries run.
local root = (debug.getinfo(1, 'S').source:match('^@(.*/)') or './') .. '../'
local now, queue, closed, reads = 0, {}, 0, 0
local chunks, send_limit = {}, nil
local function reset() now=0; queue={}; closed=0; reads=0; chunks={}; send_limit=nil end
local ui = {scheduleIn=function(_, delay, fn) queue[#queue+1]={at=now+delay,fn=fn} end}
local clock = {now=function() return now end, ms=function(x) return x/1000 end,s=function(x)return x end}
local function advance(limit)
    local n=0
    while #queue>0 do
        table.sort(queue,function(a,b)return a.at<b.at end)
        if queue[1].at>limit then break end
        local task=table.remove(queue,1); now=task.at; task.fn(); n=n+1
        assert(n<10000,'busy loop')
    end
    now=limit
end
local ffi={C={},new=function()return {}end,copy=function()end,cast=function(_,x)return x end,
 sizeof=function()return 110 end,cdef=function()end,errno=function()return 11 end,
 string=function(buf,n)return buf.data:sub(1,n)end}
ffi.C.socket=function(_,flags) assert(flags==2049,'blocking socket');return 7 end
ffi.C.connect=function()return 0 end
ffi.C.send=function(_,_,length)return math.min(length,send_limit or length)end
ffi.C.recv=function(_,buf)
 reads=reads+1
 if #chunks==0 then return -1 end
 local chunk=table.remove(chunks,1)
 if chunk==false then return 0 end
 buf.data=chunk;return #chunk
end
ffi.C.close=function()closed=closed+1 end
local json={encode=function()return '{}'end,decode=function(s)
 if s=='{"ok":true}' then return {ok=true}
 elseif s=='{"event":"idle"}' then return {event='idle'}
 elseif s=='{"pos_ms":10}' then return {pos_ms=10} end
 error('invalid JSON:'..s)
end}
package.loaded.ffi=ffi;package.loaded.logger={dbg=function()end,warn=function()end}
package.loaded['ui/uimanager']=ui;package.loaded['ui/time']=clock;package.loaded.json=json
local AudioOut=dofile(root..'audioout.lua')
reset()
local ao=AudioOut:new{};local result
chunks={'{"ok":','true}\n'}
ao:commandAsync({cmd='play'},8000,function(r)result=r end)
assert(reads==0 and result==nil,'request blocks before yielding')
advance(.1);assert(result.ok and closed==1)
print('PASS async transport yields and reassembles fragmented JSON')
reset();ao=AudioOut:new{};result=nil;send_limit=1
chunks={'{"event":"idle"}\n{"ok":true}\n'}
ao:commandAsync({},1000,function(r)result=r end)
advance(.2);assert(result.ok and ao:takeEvent().event=='idle' and closed==1)
print('PASS partial sends and event/response separation')
reset();ao=AudioOut:new{};local count=0;local reason
ao:commandAsync({},400,function(_,why)count=count+1;reason=why end)
advance(.5);assert(count==1 and reason=='timeout' and closed==1)
print('PASS unresponsive daemon times out without blocking')
reset();ao=AudioOut:new{};count=0
local cancel=ao:commandAsync({},8000,function()count=count+1 end)
cancel();advance(.5);cancel();assert(count==1 and closed==1 and reads==0)
print('PASS cancelled request closes once and sends no late command')
reset();ao=AudioOut:new{};chunks={'{"pos_ms":10}\n'}
assert(ao:statusCached()==nil and reads==0);advance(.01)
assert(ao:statusCached().pos_ms==10)
local prior=reads;ao:statusCached();advance(.09);assert(reads==prior)
print('PASS status is cached and request rate is limited')
reset();ao=AudioOut:new{};chunks={'{"pos_ms":10}\n'}
ao:statusCached();ao._status_epoch=1;advance(.1)
assert(ao._status_cache==nil)
print('PASS stale status cannot cross a playback epoch')
reset();ao=AudioOut:new{};chunks={false};reason=nil
ao:commandAsync({},1000,function(_,why)reason=why end)
advance(.01);assert(reason=='closed' and closed==1)
print('PASS closed daemon socket fails promptly')
-- Extract exactly the changed function without importing the entire KOReader UI.
local function source(name)local f=assert(io.open(root..name));local s=f:read('*a');f:close();return s end
local src=source('synccontroller.lua')
local body=assert(src:match('(function SyncController:_reserveBarSpace%(%)%s.-)\n%-%-%[%[%-%-'))
local env={SyncController={}}
setmetatable(env,{__index=_G});setfenv(assert(loadstring(body)),env)()
local p=setmetatable({plugin={getSetting=function(_,_,default)return default end}},{__index=env.SyncController})
p:_reserveBarSpace()
assert(p._bar_space_reflowed==false and not p._bar_space_reserved)
print('PASS default TTS panel does not touch document margins')
-- Async fallback cancellation and successful playback.
src=source('synccontroller.lua')
body=assert(src:match('(function SyncController:_playViaEspeakOrSkip%([^\n]+.-)\n%-%-%[%[%-%-'))
local SC={};env={SyncController=SC,logger={warn=function()end},os={remove=function()end}}
setmetatable(env,{__index=_G});setfenv(assert(loadstring(body)),env)()
local pending,started= nil,0
local sc=setmetatable({STATE={LOADING='loading'},state='loading',reading_sentence_idx=1,
 tts_engine={espeak_bin='espeak',espeakSynthesizeFallbackAsync=function(_,_,cb)pending=cb end},
 _checkPiperRtfEscalation=function()end,_checkPiperAbandon=function()end,
 applySentenceTiming=function()end,beginSentencePlayback=function()started=started+1 end,
 readNextSentence=function()error('unexpected skip')end},{__index=SC})
assert(sc:_playViaEspeakOrSkip({text='test'},'test') and started==0)
pending('/tmp/audio.wav',{});assert(started==1)
sc:_playViaEspeakOrSkip({text='test'},'test');sc._espeak_request_generation=sc._espeak_request_generation+1
pending('/tmp/audio.wav',{});assert(started==1)
print('PASS espeak fallback yields and ignores cancelled callbacks')
reset();ao=AudioOut:new{};chunks={'{"ok":true}\n'}
local started=false
ao:startAsync(function()started=true end,function()return false end)
advance(.1);assert(not started and #queue==0)
print('PASS cancelled daemon startup does not continue polling or restart playback')
reset();ao=AudioOut:new{};chunks={'{"ok":true}\n'}
local execute=os.execute;local kills=0
os.execute=function()kills=kills+1 end
ao:stopDaemon();advance(.01)
chunks={'{"ok":true}\n'}
ao:startAsync(function()end);advance(.5)
os.execute=execute
assert(kills==0)
print('PASS delayed shutdown cannot kill a newly started daemon')
print('ALL 11 REGRESSION TESTS PASSED')
