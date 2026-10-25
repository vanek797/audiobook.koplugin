local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local f=assert(io.open(root..'ttsengine.lua'));local s=f:read('*a');f:close()
local a=assert(s:find('    if self:_useAudioOut() then',1,true))
local b=assert(s:find('    -- === POCKETBOOK INKVIEW PLAYFILE PATH ===',a,true))
local start_cb,requests,timers,failures={}, {}, {},0
local ao={startAsync=function(_,cb)start_cb=cb end,commandAsync=function(_,cmd,timeout,cb)
 requests[#requests+1]={cmd=cmd,cb=cb};return function()cb(nil)end
end}
local env={UIManager={getTime=function()return 0 end,unschedule=function()end,
 scheduleIn=function(_,delay,fn)timers[#timers+1]={delay,fn}end},
 WavUtils={readSampleRateFromPath=function()return 16000 end},
 logger={warn=function()end},time={to_ms=function(x)return x end},pairs=pairs}
setmetatable(env,{__index=_G})
local loader=assert(loadstring('return function(self,on_word,on_complete,on_fail,concat_files)\n'..s:sub(a,b-1)..'\nend'))
setfenv(loader,env);local play=loader()
local function engine()
 requests={};timers={};failures=0
 local e={is_speaking=true,current_audio_file='/tmp/test.wav',audio_player_type='gst-bt',
 _useAudioOut=function()return true end,_getAudioOut=function()return ao end,
 getAudioDurationMs=function()return 1000 end,getPiperQueueSnapshot=function()return ''end,
 startTimingLoop=function(self)self.started=true end}
 return e
end
local function fail()failures=failures+1 end
local e=engine();assert(play(e,nil,nil,fail)==true and not e.started and #requests==0)
start_cb(true);assert(#requests==1 and requests[1].cmd.cmd=='play' and not e.started)
requests[1].cb({ok=true,done_count=3,start_ms=100,fed_end_ms=1100})
assert(e.started and e._audioout_done_baseline==3 and failures==0)
print('PASS playback waits asynchronously for startup and play acknowledgement')
e=engine();play(e,nil,nil,fail);e.play_generation=e.play_generation+1;start_cb(true)
assert(#requests==0 and not e.started)
print('PASS stop during startup prevents late playback')
e=engine();play(e,nil,nil,fail);start_cb(true);e.play_generation=e.play_generation+1
requests[1].cb({ok=true,done_count=3});assert(not e.started and #timers==0)
print('PASS cancelled play acknowledgement cannot restart UI timers')
e=engine();play(e,nil,nil,fail);start_cb(true)
requests[1].cb({ok=false,error='queue full'});assert(requests[2].cmd.cmd=='flush')
requests[2].cb({ok=true});assert(requests[3].cmd.cmd=='play')
requests[3].cb({ok=false,error='queue full'});assert(#requests==3 and failures==1 and not e.is_speaking)
print('PASS full queue retries once without blocking or looping forever')
e=engine();play(e,nil,nil,fail);start_cb(true);requests[1].cb({ok=true})
assert(failures==1 and not e.started)
print('PASS missing completion baseline fails safely')
e=engine();play(e,nil,nil,fail);start_cb(true);e.is_paused=true
requests[1].cb({ok=true,done_count=3});assert(requests[2].cmd.cmd=='pause')
print('PASS pause during startup is applied when playback is acknowledged')
print('ALL 6 PLAYBACK REGRESSION TESTS PASSED')
