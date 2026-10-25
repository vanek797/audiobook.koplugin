local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local worker_script=os.tmpname()..'-fake-espeak.sh'
local f=assert(io.open(root..'ttsengine.lua'));local s=f:read('*a');f:close()
local a=assert(s:find('function TTSEngine:espeakSynthesizeFallbackAsync',1,true))
local b=assert(s:find('--[[--\nMerge multiple WAV files',a,true))
local now,queue=0,{}
local E={}
local env={TTSEngine=E,UIManager={scheduleIn=function(_,delay,fn)queue[#queue+1]={at=now+delay,fn=fn}end},
 time={now=function()return now end,s=function(x)return x end},logger={warn=function()end},
 WavUtils={applyFade=function()end,resampleFile=function()end}}
setmetatable(env,{__index=_G});setfenv(assert(loadstring(s:sub(a,b-1))),env)()
f=assert(io.open(worker_script,'w'));f:write([[#!/bin/sh
while [ "$#" -gt 0 ]; do
 if [ "$1" = "-w" ]; then shift; out="$1"; fi
 shift
done
sleep 0.1
printf RIFF > "$out"
]]);f:close()
local e=setmetatable({espeak_bin='/bin/sh '..worker_script,file_counter=50000,
 current_audio_file='original.wav',timing_data={original=true},
 _resolveEspeakDataPath=function()return '/tmp' end,escapeText=function(_,x)return x end,
 generateTimingEstimates=function(self)self.timing_data={generated=true}end},{__index=E})
local returned,timing
e:espeakSynthesizeFallbackAsync('hello',function(file,t) returned=file;timing=t end)
assert(returned==nil and e.current_audio_file=='original.wav')
local function pump()
 for _=1,150 do
  if #queue==0 then return end
  table.sort(queue,function(x,y)return x.at<y.at end)
  local task=table.remove(queue,1);now=task.at
  os.execute('sleep 0.02');task.fn()
 end
 error('worker did not finish')
end
pump()
assert(returned and timing.generated and e.current_audio_file=='original.wav' and e.timing_data.original)
os.remove(returned)
assert(next(e._fallback_jobs)==nil)
print('PASS real background shell completes through atomic marker without clobbering playback')
local called,reason=0,nil
e:espeakSynthesizeFallbackAsync('cancel me',function(_,_,why)called=called+1;reason=why end)
-- Let the shell publish its child PID before cancelling.
os.execute('sleep 0.03')
local jobs={};for _,cancel in pairs(e._fallback_jobs)do jobs[#jobs+1]=cancel end
for _,cancel in ipairs(jobs)do cancel()end
pump();assert(called==1 and reason=='cancelled' and next(e._fallback_jobs)==nil)
print('PASS cancelled background worker is terminated and callback fires once')
os.remove(worker_script)
print('ALL 2 ESPEAK WORKER TESTS PASSED')
