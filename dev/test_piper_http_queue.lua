local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local Queue=dofile(root..'piperhttpqueue.lua')
local tests=0
local function check(name,fn)fn();tests=tests+1;print('PASS '..name)end
local function options(text,volume)
    return {url='http://piper.test:5000',voice='en_US-amy-medium',rate=1,volume=volume or 1,text=text}
end
local function list(...)
    local out={};for _,text in ipairs({...})do out[#out+1]=options(text)end;return out
end
local function tempfile(bytes)
    local p=os.tmpname();local f=assert(io.open(p,'wb'));f:write(string.rep('x',bytes or 52));f:close();return p
end
local function exists(p)local f=io.open(p,'rb');if f then f:close();return true end;return false end
local function fixture(budget)
    local c={requests={},cancels=0}
    function c:request(o,cb)
        assert(not self.active,'parallel HTTP requests')
        local job={options=o,callback=cb};self.requests[#self.requests+1]=job;self.active=job;return true
    end
    function c:cancel()self.cancels=self.cancels+1;self.active=nil end
    function c:finish(bytes,reason)
        local job=assert(self.active);self.active=nil
        local path=not reason and tempfile(bytes) or nil
        job.callback(path,reason);return path
    end
    return Queue:new{client=c,max_bytes=budget},c
end
check('N lookahead is fetched in order by a single worker',function()
    local q,c=fixture();q:plan(list('B','C','D'),3)
    assert(#c.requests==1 and c.active.options.text=='B')
    c:finish();assert(c.active.options.text=='C')
    c:finish();assert(c.active.options.text=='D')
    c:finish();assert(not c.active and q.bytes==156 and #q.order==3)
    q:cancel()
end)
check('cache hit transfers WAV ownership without another HTTP request',function()
    local q,c=fixture();q:plan(list('B','C'),2);c:finish();c:finish()
    local path;q:request(options('B'),function(p)path=p end)
    assert(path and exists(path) and #c.requests==2 and q.hits==1 and q.bytes==52)
    q:cancel();assert(exists(path));os.remove(path)
end)
check('in-flight lookahead is promoted instead of duplicated',function()
    local q,c=fixture();q:plan(list('B','C'),2)
    local calls=0;q:request(options('B'),function(p)calls=calls+1;os.remove(p)end)
    assert(#c.requests==1 and c.cancels==0)
    c:finish();assert(calls==1 and c.active.options.text=='C')
    q:cancel()
end)
check('current sentence preempts unrelated speculative work',function()
    local q,c=fixture();q:plan(list('C','D'),2);local old=c.active
    q:request(options('B'),function(p)os.remove(p)end)
    assert(c.cancels==1 and c.active.options.text=='B')
    local late=tempfile();old.callback(late);assert(not exists(late) and c.active.options.text=='B')
    c:finish();assert(c.active.options.text=='C');q:cancel()
end)
check('moving the window deletes stale cached files and cancels stale work',function()
    local q,c=fixture();q:plan(list('B','C'),2);local path=c:finish()
    assert(exists(path) and c.active.options.text=='C')
    q:plan(list('D','E'),2)
    assert(not exists(path) and q.bytes==0 and c.active.options.text=='D' and c.cancels==1)
    q:cancel()
end)
check('zero lookahead cancels speculation but still serves foreground',function()
    local q,c=fixture();q:plan(list('B','C'),2);local path=c:finish()
    q:plan({},0);assert(not exists(path) and not c.active and q.bytes==0)
    q:request(options('A'),function(p)os.remove(p)end);assert(c.active.options.text=='A')
    c:finish();assert(not c.active);q:cancel()
end)
check('byte cap does not cause an endless redownload loop',function()
    local q,c=fixture(80);q:plan(list('B','C','D'),3)
    c:finish();c:finish();c:finish()
    assert(q.bytes==52 and not c.active and #c.requests==3)
    q:_pump();assert(#c.requests==3)
    q:request(options('B'),function(p)os.remove(p)end)
    q:plan(list('C','D'),2);assert(c.active.options.text=='C')
    c:finish();c:finish();assert(q.bytes==52 and #c.requests==5 and not c.active)
    q:cancel()
end)
check('failed speculative request is retried only when needed',function()
    local q,c=fixture();q:plan(list('B'),1);c:finish(nil,'offline')
    assert(not c.active and #c.requests==1)
    q:_pump();assert(#c.requests==1)
    local heard=false;q:request(options('B'),function(p)heard=true;os.remove(p)end)
    assert(#c.requests==2);c:finish();assert(heard);q:cancel()
end)
check('audio identity includes URL, voice, speed, gain, and full text',function()
    local base=options('hello');local key=Queue.key(base)
    for _,field in ipairs({'url','voice','rate','volume','text'})do
        local changed={};for k,v in pairs(base)do changed[k]=v end
        changed[field]=tostring(changed[field])..'-changed'
        assert(Queue.key(changed)~=key,field)
    end
    assert(Queue.key(options('a:1:b'))~=Queue.key(options('a:1:bb')))
end)
check('lookahead is clamped to eight entries',function()
    local q,c=fixture();local all={}
    for i=1,20 do all[i]=options('sentence '..i)end
    q:plan(all,1000);assert(#q.order==8)
    for _=1,8 do c:finish()end
    assert(not c.active and #c.requests==8);q:cancel()
end)
check('cancel clears cached files and rejects late worker results',function()
    local q,c=fixture();q:plan(list('B','C'),2);local path=c:finish();local late_job=c.active
    q:cancel();assert(not exists(path) and not c.active and q.bytes==0)
    local late=tempfile();late_job.callback(late);assert(not exists(late) and not c.active)
end)
check('immediate worker failure is delivered once without spinning',function()
    local c={cancel=function()end,request=function()return nil,'Set server URL' end}
    local q=Queue:new{client=c};local calls=0
    q:request(options('A'),function(p,err)assert(not p and err=='Set server URL');calls=calls+1 end)
    q:plan(list('B','C'),2)
    assert(calls==1 and q.downloads==3 and not q.current);q:cancel()
end)
check('controller plans only the following N parsed sentences',function()
    local f=assert(io.open(root..'synccontroller.lua'));local source=f:read('*a');f:close()
    local body=assert(source:match('(function SyncController:planHTTPAhead%(%)%s.-)\nfunction SyncController:_prefetchNextSentence'))
    local SC={};local env=setmetatable({SyncController=SC},{__index=_G})
    setfenv(assert(loadstring(body)),env)()
    local wanted,limit;local setting=3
    local sc=setmetatable({reading_sentence_idx=1,total_sentences=5,
        parsed_data={sentences={{text='A'},{text='B'},{text='C'},{text='D'},{text='E'}}},
        plugin={getSetting=function()return setting end},
        tts_engine={backend='http',BACKENDS={PIPER_HTTP='http'},
            prefetchHTTPSentences=function(_,texts,n)wanted=texts;limit=n end}},{__index=SC})
    sc:planHTTPAhead();assert(table.concat(wanted,',')=='B,C,D' and limit==3)
    setting=0;sc:planHTTPAhead();assert(#wanted==0 and limit==0)
    setting=100;sc:planHTTPAhead();assert(table.concat(wanted,',')=='B,C,D,E' and limit==8)
end)
check('disabling speculation does not cancel the active foreground sentence',function()
    local q,c=fixture();local heard=false
    q:request(options('A'),function(p)heard=true;os.remove(p)end)
    q:plan(list('B','C'),0)
    assert(c.cancels==0 and c.active.options.text=='A')
    c:finish();assert(heard and not c.active);q:cancel()
end)
check('missing cache files are refetched instead of being played',function()
    local q,c=fixture();q:plan(list('B'),1);local path=c:finish();os.remove(path)
    local heard=false;q:request(options('B'),function(p)heard=true;os.remove(p)end)
    assert(#c.requests==2 and q.bytes==0 and not heard)
    c:finish();assert(heard);q:cancel()
end)
check('duplicate text never shares the engine-owned playing file',function()
    local q,c=fixture();q:plan(list('B','B','C'),3)
    assert(#q.order==2);c:finish();c:finish()
    local playing;q:request(options('B'),function(p)playing=p end)
    q:plan(list('B','C'),2);local cached=c:finish()
    assert(cached~=playing and exists(playing) and exists(cached))
    q:cancel();assert(exists(playing) and not exists(cached));os.remove(playing)
end)
check('rate/gain edits invalidate speculation without abandoning foreground',function()
    local f=assert(io.open(root..'ttsengine.lua'));local source=f:read('*a');f:close()
    local E={};local env=setmetatable({TTSEngine=E,logger={dbg=function()end}},{__index=_G})
    local blocks={
        assert(source:match('(function TTSEngine:setRate%([^\n]+.-)\n%-%-%[%[%-%-\nSet speech pitch')),
        assert(source:match('(function TTSEngine:setVolume%([^\n]+.-)\n%-%-%[%[%-%-\nSet the espeak')),
        assert(source:match('(function TTSEngine:_invalidateHTTPLookahead%(%)%s.-)\nfunction TTSEngine:_httpSoftwareVolume')),
    }
    for _,body in ipairs(blocks)do setfenv(assert(loadstring(body)),env)()end
    local q,c=fixture();q:plan(list('B','C'),2);local cached=c:finish()
    local engine=setmetatable({backend='http',BACKENDS={PIPER_HTTP='http'},rate=1,volume=1,_http=q,
        _httpSoftwareVolume=function()return true end},{__index=E})
    engine:setRate(1.5);assert(not exists(cached) and not c.active and q.bytes==0)
    q:request(options('A'),function(p)os.remove(p)end)
    engine:setVolume(.5);assert(c.active.options.text=='A')
    c:finish();q:cancel()
end)
print('ALL '..tests..' PIPER HTTP QUEUE CHECKS PASSED')
