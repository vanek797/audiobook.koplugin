-- Actual WAV concatenation and controller/queue ownership, with no audio device.
local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
package.loaded.logger={warn=function()end,dbg=function()end}
local W=dofile(root..'wavutils.lua')
local Queue=dofile(root..'piperhttpqueue.lua')
local function source(name)local f=assert(io.open(root..name));local s=f:read('*a');f:close();return s end
local E,SC={},{}
local timers={}
local ui={getTime=function()return 0 end,scheduleIn=function(_,delay,fn)timers[#timers+1]={delay=delay,fn=fn}end,unschedule=function()end}
local env=setmetatable({TTSEngine=E,SyncController=SC,WavUtils=W,UIManager=ui,
    logger=package.loaded.logger,time={to_ms=function(x)return x end}},{__index=_G})
local text=source('ttsengine.lua')
local blocks={
    assert(text:match('(function TTSEngine:_httpConcatFormat%([^\n]+.-)\nfunction TTSEngine:_httpSoftwareVolume')),
    assert(text:match('(function TTSEngine:peekPrefetch%([^\n]+.-)\n%-%-%[%[%-%-\nDiagnostic:')),
    assert(text:match('(function TTSEngine:consumePiperQueueEntry%([^\n]+.-)\nfunction ')),
}
for _,body in ipairs(blocks)do setfenv(assert(loadstring(body)),env)()end
text=source('synccontroller.lua')
blocks={
    assert(text:match('(function SyncController:beginSentencePlayback%([^\n]+.-)\n%-%-%[%[%-%-\nPrefetch a future')),
    assert(text:match('(function SyncController:planHTTPAhead%([^\n]+.-)\nfunction SyncController:_prefetchNextSentence')),
    assert(text:match('(function SyncController:_cleanConcatFiles%(%)%s.-)\n%-%-%[%[%-%-')),
}
for _,body in ipairs(blocks)do setfenv(assert(loadstring(body)),env)()end
local function options(s)return {url='http://piper.test:5000',voice='voice',rate=1,volume=1,text=s}end
local function wav(ms,rate)
    rate=rate or 22050
    local data=string.rep('\1\0',math.floor(rate*ms/1000))
    local p=os.tmpname();local f=assert(io.open(p,'wb'))
    f:write('RIFF',W.le32(36+#data),'WAVEfmt ',W.le32(16),W.le16(1),W.le16(1),W.le32(rate),W.le32(rate*2),W.le16(2),W.le16(16),'data',W.le32(#data),data)
    f:close();return p
end
local function exists(path)local f=io.open(path,'rb');if f then f:close();return true end;return false end
local function fixture(duration,gap,ready,bad_rate)
    timers={}
    local client={requests=0}
    function client:request(o,cb)assert(not self.active);self.active={options=o,cb=cb};self.requests=self.requests+1;return true end
    function client:cancel()self.active=nil end
    local q=Queue:new{client=client}
    local paths={}
    local letters={'A','B','C','D','E','F','G','H'}
    local planned={};for i=2,#letters do planned[#planned+1]=options(letters[i])end
    q:plan(planned,8)
    if ready~=false then
        while client.active do
            local job=client.active;client.active=nil
            local path=wav(duration,bad_rate and job.options.text=='B' and 16000 or nil)
            paths[job.options.text]=path;job.cb(path)
        end
    end
    local main=wav(duration);paths.A=main
    local engine=setmetatable({backend='http',BACKENDS={PIPER_HTTP='http'},audio_player_type='gst-bt',
        current_audio_file=main,timing_data={{start_time=0,end_time=100}},_http=q,
        _httpOptions=function(_,s)return options(s)end,
        generateTimingEstimates=function(self)self.timing_data={{start_time=0,end_time=100}}end,
        getAudioDurationMs=function(self)return W.getDurationMs(self.current_audio_file)end,
        appendGapToWav=function(_,p,ms)assert(W.appendSilence(p,ms))end,
        prefetch=function()error('must not synthesize during block assembly')end,
    },{__index=E})
    function engine:prefetchHTTPSentences(texts,count)
        self.planned=texts;local all={};for _,s in ipairs(texts)do all[#all+1]=options(s)end
        q:plan(all,count)
    end
    function engine:play(_,done,_,files)
        self.play_calls=(self.play_calls or 0)+1;self.done=done;self.extra_files=files
        self._current_audio_duration_ms=self._unpadded_duration_ms or W.getDurationMs(self.current_audio_file)
        if files then assert(W.mergeFiles(self.current_audio_file,files))end
        return true
    end
    local sentences={}
    for i,s in ipairs(letters)do sentences[i]={index=i,text=s,end_type='sentence',words={{index=1,text=s,start_time=0,end_time=100,duration=100}}}end
    local sc=setmetatable({tts_engine=engine,parsed_data={sentences=sentences},total_sentences=#sentences,
        reading_sentence_idx=1,STATE={PLAYING='playing',STOPPED='stopped',PAUSED='paused'},
        plugin={getSetting=function(_,key,default)
            if key=='sentence_pause' or key=='paragraph_pause' then return gap or 0 end
            if key=='piper_http_lookahead' then return 8 end
            if key=='highlight_sentences' then return false end
            return default
        end},highlight_manager={clearHighlights=function()end},
        _disarmTtsWaitUi=function()end,_rememberSpoken=function()end,_applyBarVisibility=function()end,
        _prefetchNextPage=function(self)self.page_peeks=(self.page_peeks or 0)+1 end,startSentenceSyncLoop=function()end,
        _prefetchNextSentence=function(self)self:planHTTPAhead()end,
        applySentenceTiming=function(_,sent,timing)
            sent.words[1].start_time=timing[1].start_time;sent.words[1].end_time=timing[1].end_time
            sent.words[1].duration=timing[1].end_time-timing[1].start_time
        end,
        readNextSentence=function(self)self.next_index=self.reading_sentence_idx+1 end,
        stop=function()error('unexpected stop')end,
    },{__index=SC})
    local function cleanup()
        q:cancel();sc:_cleanConcatFiles();os.remove(main)
        for _,path in pairs(paths)do os.remove(path)end
    end
    return sc,engine,q,client,paths,cleanup
end
local count=0
local function check(name,fn)fn();count=count+1;print('PASS '..name)end
check('five ready sentences use one merged WAV/player launch',function()
    local sc,e,q,c,p,cleanup=fixture(1000)
    sc:beginSentencePlayback(sc.parsed_data.sentences[1])
    assert(e.play_calls==1 and #e.extra_files==4 and W.getDurationMs(p.A)==5000)
    assert(sc._sentences_in_play==5 and sc._http_group_end_idx==5)
    assert(table.concat(sc._concat_split_points,',')=='1000,2000,3000,4000')
    assert(table.concat(e.planned,',')=='F,G,H' and q.bytes==3*(44+44100))
    assert(not sc.page_peeks)
    cleanup()
end)
check('completed block advances once past every included sentence',function()
    local sc,e,q,c,p,cleanup=fixture(1000)
    sc:beginSentencePlayback(sc.parsed_data.sentences[1]);e.done()
    assert(sc.reading_sentence_idx==5)
    local chain=assert(timers[#timers]);assert(chain.delay==.05);chain.fn()
    assert(sc.next_index==6);cleanup()
end)
check('existing 30-second cap limits long HTTP blocks',function()
    local sc,e,q,c,p,cleanup=fixture(10000)
    sc:beginSentencePlayback(sc.parsed_data.sentences[1])
    assert(#e.extra_files==2 and W.getDurationMs(p.A)==30000 and sc._http_group_end_idx==3)
    assert(table.concat(e.planned,',')=='D,E,F,G,H');cleanup()
end)
check('a cache miss starts the current sentence without waiting for HTTP',function()
    local sc,e,q,c,p,cleanup=fixture(1000,0,false)
    sc:beginSentencePlayback(sc.parsed_data.sentences[1])
    assert(e.play_calls==1 and not e.extra_files and sc._http_group_end_idx==1)
    assert(c.active and c.active.options.text=='B');cleanup()
end)
check('different WAV sample rates are never concatenated',function()
    local sc,e,q,c,p,cleanup=fixture(1000,0,true,true)
    sc:beginSentencePlayback(sc.parsed_data.sentences[1])
    assert(not e.extra_files and W.getDurationMs(p.A)==1000 and exists(p.B));cleanup()
end)
check('cache cleanup cannot delete block-owned audio files',function()
    local sc,e,q,c,p,cleanup=fixture(1000)
    sc:beginSentencePlayback(sc.parsed_data.sentences[1]);q:cancel()
    assert(exists(p.B) and exists(p.E) and not exists(p.F))
    e.done();assert(not exists(p.B) and not exists(p.E));cleanup()
end)
check('configured gaps are padded once and timing excludes first padding',function()
    local sc,e,q,c,p,cleanup=fixture(1000,.2)
    sc:beginSentencePlayback(sc.parsed_data.sentences[1])
    assert(W.getDurationMs(p.A)==6000 and e._current_audio_duration_ms==1000)
    assert(table.concat(sc._concat_split_points,',')=='1200,2400,3600,4800')
    e.done();assert(timers[#timers].delay==.05);cleanup()
end)
check('noncanonical WAV headers are rejected by the block format gate',function()
    local sc,e,q,c,p,cleanup=fixture(1000)
    local f=assert(io.open(p.A,'r+b'));f:seek('set',36);f:write('JUNK');f:close()
    assert(not e:_httpConcatFormat(p.A))
    -- Only format gating is exercised: deliberately invalid data is not played.
    cleanup()
end)
print('ALL '..count..' PIPER HTTP BLOCK CHECKS PASSED')
