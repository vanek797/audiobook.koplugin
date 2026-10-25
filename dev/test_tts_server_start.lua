-- Exercise delayed startup and FIFO readiness without shell/device access.
local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local file=assert(io.open(root..'piperqueue.lua'));local source=file:read('*a');file:close()
local body=assert(source:match('(function PiperQueue:startServers%(%)%s.-)\n%-%-%[%[%-%-\nStop persistent Piper servers'))
local now,queue,builds,fifo_opens=0,{},0,0
local PQ={}
local function opened(path,mode)
 if mode=='w' then return {write=function()end,close=function()end} end
 if path:match('%.pid$') or path:match('%.piper_pid$') then
  return {read=function()return '12345' end,close=function()end}
 end
 error('Unexpected file open: '..path)
end
local env={PiperQueue=PQ,_pool_count=function()return 1 end,SERVER_COUNT=1,
 SERVER_PREFIX='/tmp/fake_tts_server_',_cpu_cores=1,
 logger={warn=function()end,err=function()error('unexpected startup error')end},
 os={execute=function(command)assert(not command:find('usleep',1,true))end},
 io={open=opened},time={to_ms=function(x)return x*1000 end},
 ffi={C={open=function(_,flags)assert(flags==2048,'FIFO open must not block');fifo_opens=fifo_opens+1;return 7 end,close=function()end}},
 UIManager={getTime=function()return now end,scheduleIn=function(_,delay,fn)queue[#queue+1]={at=now+delay,fn=fn}end}}
setmetatable(env,{__index=_G});setfenv(assert(loadstring(body)),env)()
local function new()
 return setmetatable({engine={backend='sanotts',BACKENDS={SANOTTS='sanotts',SANOTTS_JP='jp'}},
 _batchSize=function()return 1 end,buildBaseCommand=function()builds=builds+1;return 'snt_server' end,
 launchNext=function(self)self.launched=true end},{__index=PQ})
end
local function next_task()
 table.sort(queue,function(a,b)return a.at<b.at end)
 local task=assert(table.remove(queue,1));now=task.at;task.fn()
end
local p=new();p:startServers()
assert(builds==0 and #queue==1 and queue[1].at==.2)
next_task();assert(builds==1 and p._servers_starting)
next_task();assert(fifo_opens==1 and p._servers_running and p.launched)
print('PASS server startup yields during grace period and probes FIFO nonblockingly')
queue={};local previous=builds;p=new();p:startServers()
p._server_launch_generation=p._server_launch_generation+1;p._servers_starting=false
next_task();assert(builds==previous and not p._servers_running)
print('PASS stopped server cannot be relaunched by stale scheduled callback')
print('ALL 2 SERVER STARTUP TESTS PASSED')
