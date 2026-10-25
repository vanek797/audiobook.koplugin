-- Host-only remote backend tests: no real network, subprocess, or Kobo needed.
local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local HTTP=dofile(root..'piperhttp.lua')
local audio='RIFF'..string.rep('\0',4)..'WAVE'..string.rep('\0',40)
local payload,status,sink_calls,reset_calls,encoded
local function reset_transport()
    payload=audio;status=200;sink_calls=0;reset_calls=0
end
package.loaded['socket.http']={request=function(req)
    assert(req.url=='http://piper.test:5000/synthesize' and req.method=='POST' and req.redirect==false)
    assert(req.headers['Content-Type']=='application/json')
    local ok,err=req.sink(payload);sink_calls=sink_calls+1
    if not ok then return nil,err end
    req.sink(nil)
    return 1,status
end}
package.loaded.ltn12={source={string=function(body)return function()return body end end}}
package.loaded.json={encode=function(value)encoded=value;return '{}' end}
package.loaded.socketutil={set_timeout=function()end,reset_timeout=function()reset_calls=reset_calls+1 end}
local opts={url='http://piper.test:5000',voice='en_US-amy-medium',text='Hello',rate=2}
local base=os.tmpname();local path=base..'.wav'
reset_transport();assert(HTTP.fetch(opts,path))
assert(HTTP.isWav(path) and encoded.voice==opts.voice and encoded.length_scale==.5 and reset_calls==1)
os.remove(path)
print('PASS POST voice/rate payload and WAV validation')
reset_transport();status=503
assert(not HTTP.fetch(opts,path) and not HTTP.isWav(path))
assert(io.open(path..'.part')==nil and reset_calls==1)
print('PASS HTTP failure removes incomplete audio')
reset_transport();payload='<html>not audio</html>'
assert(not HTTP.fetch(opts,path) and not HTTP.isWav(path))
print('PASS non-WAV response is rejected')
reset_transport();HTTP.MAX_AUDIO_BYTES=50;payload=string.rep('x',51)
assert(not HTTP.fetch(opts,path));HTTP.MAX_AUDIO_BYTES=16*1024*1024
print('PASS bounded response sink rejects oversized audio')
assert(HTTP.validateURL(' http://piper.test:5000/// ')=='http://piper.test:5000')
for _,url in ipairs({'','https://piper.test','http://user:pass@piper.test','http://piper.test/path','http://piper.test?x=1'}) do
    assert(not HTTP.validateURL(url),url)
end
print('PASS empty/manual URL policy and unsafe endpoint rejection')
local now,queue,processes,nextpid=0,{}, {},0
local ui={scheduleIn=function(_,delay,fn)queue[#queue+1]={at=now+delay,fn=fn}end,
    unschedule=function(_,fn)for i=#queue,1,-1 do if queue[i].fn==fn then table.remove(queue,i)end end end}
local util={runInSubProcess=function(fn)
    nextpid=nextpid+1;processes[nextpid]={run=fn,done=false};return nextpid
end,isSubProcessDone=function(pid)return processes[pid].done end,
terminateSubProcess=function(pid)processes[pid].killed=true;processes[pid].done=true end}
local function advance(limit)
    while #queue>0 do
        table.sort(queue,function(a,b)return a.at<b.at end)
        if queue[1].at>limit then break end
        local task=table.remove(queue,1);now=task.at;task.fn()
    end
    now=limit
end
local function client()return HTTP:new{util=util,ui=ui,time={now=function()return now end,s=function(x)return x end}}end
local h=client();local called=0;local output
reset_transport();assert(h:request(opts,function(p)called=called+1;output=p end))
assert(called==0 and h.job)
local pid=h.job.pid;processes[pid].run();processes[pid].done=true;advance(now+.2)
assert(called==1 and HTTP.isWav(output) and not h.job)
os.remove(output)
print('PASS foreground synthesis yields and transfers completed audio ownership')
h=client();called=0;h:request(opts,function()called=called+1 end)
local job=h.job;h:cancel();advance(now+.2)
assert(processes[job.pid].killed and called==0 and not h.job and not HTTP.isWav(job.path))
print('PASS stop kills worker immediately without a late playback callback')
h=client();called=0;h:request(opts,function()called=called+1 end)
job=h.job;reset_transport();processes[job.pid].run();processes[job.pid].done=true
h:cancel();advance(now+.2);assert(called==0 and not HTTP.isWav(job.path))
print('PASS cancel after download but before poll removes unconsumed WAV')
h=client();local reason
h:request({url=opts.url,text='Hello',timeout=5},function(p,e)output=p;reason=e end)
job=h.job;advance(now+5.2)
assert(processes[job.pid].killed and not output and reason:find('timed out',1,true))
print('PASS parent deadline bounds stalled DNS/HTTP independently of worker timeout')
h=client();reason=nil;reset_transport();status=500
h:request(opts,function(_,e)reason=e end);job=h.job
processes[job.pid].run();processes[job.pid].done=true;advance(now+.2)
assert(reason:find('500',1,true) and not h.job)
print('PASS worker error reaches caller instead of silently skipping text')
h=client();called=0
h:request(opts,function()called=called+1 end);local old=h.job
h:request(opts,function()called=called+10 end);local new=h.job
assert(processes[old.pid].killed and new.pid~=old.pid)
reset_transport();processes[new.pid].run();processes[new.pid].done=true;advance(now+.2)
assert(called==10);os.remove(new.path)
print('PASS replacing a request cancels the old generation')
h=client();local before=nextpid
assert(not h:request({url='',text='Hello'},function()error('unexpected callback')end))
assert(nextpid==before and not h.job)
print('PASS unconfigured URL never forks or uses a hardcoded server')
h=client();h.util=setmetatable({runInSubProcess=function()return nil,'fork failed' end},{__index=util})
local started,err=h:request(opts,function()error('unexpected callback')end)
assert(not started and err=='fork failed' and not h.job)
print('PASS subprocess launch failure is explicit')
os.remove(base)
-- Engine adapter: settings are read at request time and no local synthesis runs.
local file=assert(io.open(root..'ttsengine.lua'));local source=file:read('*a');file:close()
local body=assert(source:match('(function TTSEngine:_synthesizeHTTP%([^\n]+.-)\nfunction TTSEngine:_cancelHTTP'))
local E={};local pending,submitted
local settings={piper_http_url='http://piper.test:5000',piper_http_voice='en_US-amy-medium'}
local env=setmetatable({TTSEngine=E,logger={warn=function()end},WavUtils={getDurationMs=function()return 1000 end},os={remove=function()end}},{__index=_G})
setfenv(assert(loadstring(body)),env)()
local engine=setmetatable({BACKENDS={PIPER_HTTP='piper-http'},backend='piper-http',rate=1.2,
    plugin={getSetting=function(_,key,default)return settings[key] or default end},
    _http={request=function(_,options,cb)submitted=options;pending=cb;return true end},
    generateTimingEstimates=function(self)self.timing_data={{start_time=0,end_time=1000}}end},{__index=E})
called=0;assert(engine:_synthesizeHTTP('Hello',function(ok)assert(ok);called=called+1 end))
assert(submitted.url==settings.piper_http_url and submitted.voice=='en_US-amy-medium' and called==0)
pending('/tmp/mock.wav');assert(called==1 and engine.current_audio_file=='/tmp/mock.wav')
print('PASS engine reads editable URL and voice settings, then waits for WAV')
engine:_synthesizeHTTP('Hello',function()called=called+1 end)
engine._http_generation=1;pending('/tmp/mock.wav');assert(called==1)
print('PASS stopped engine ignores stale HTTP callback')
engine._http.request=function()return nil,'Configure server URL' end
called=0
assert(engine:_synthesizeHTTP('Hello',function(ok)assert(not ok);called=called+1 end))
assert(called==1 and engine._http_error=='Configure server URL')
print('PASS immediate validation failure is delivered exactly once')
h=client();local direct_kills=0
h.util=setmetatable({terminateSubProcess=function()end},{__index=util})
h.kill=function(pid)direct_kills=direct_kills+1;processes[pid].done=true end
h:request(opts,function()error('cancelled callback')end);h:cancel()
assert(direct_kills==1 and not h.job)
print('PASS cancellation before child process-group setup kills the child PID')
print('ALL 17 PIPER HTTP CHECKS PASSED')
