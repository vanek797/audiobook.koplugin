-- Whole-page preparation, preview cancellation and view restoration.
local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
package.loaded.logger={warn=function()end,dbg=function()end}
local Parser=dofile(root..'textparser.lua')
local Page=dofile(root..'piperhttppage.lua')
local parser=Parser:new()
local function source(name)local f=assert(io.open(root..name));local s=f:read('*a');f:close();return s end
local count=0
local function check(name,fn)fn();count=count+1;print('PASS '..name)end
check('one page is one request unit with original word offsets',function()
    local p=Page.parse(parser,'First sentence.\nSecond sentence!\n\nThird paragraph.')
    assert(#p.sentences==1 and p.http_page and p.sentences[1].http_page)
    assert(p.sentences[1].text==p.text and p.sentences[1].words==p.words)
    for i,w in ipairs(p.words)do
        assert(w.index==i and w.sentence_index==1 and p.text:sub(w.start_pos,w.end_pos)==w.text)
    end
end)
check('page preparation bypasses local 300-character chunk splitting',function()
    local text=string.rep('A long sentence. ',80)
    assert(#Page.parse(parser,text).sentences==1 and #parser:parse(text).sentences>1)
    assert(#Page.parse(parser,text).text>300)
end)
check('empty pages remain empty and word suffixes do not reread page start',function()
    assert(#Page.parse(parser,'   ').sentences==0)
    local p=Page.parse(parser,'One two three four.')
    assert(Page.suffix(p,3)=='three four.' and Page.suffix(p,0)==p.text)
    assert(Page.suffix(p,999)=='four.')
end)
local SC={};local timers,shown={},{}
local ui={scheduleIn=function(_,delay,fn)timers[#timers+1]=fn end,
    show=function(_,widget)shown[#shown+1]=widget end}
local env=setmetatable({SyncController=SC,HTTPPage=Page,UIManager=ui,logger=package.loaded.logger,
    _=function(x)return x end,dlog=function()end,
    require=function(name)assert(name=='ui/widget/infomessage');return {new=function(_,x)return x end}end,
},{__index=_G})
local text=source('synccontroller.lua')
local bodies={
    assert(text:match('(function SyncController:_beginReadingParsed%([^\n]+.-)\n%-%-%[%[%-%-\nSynthesize and play')),
    assert(text:match('(function SyncController:prefetchHTTPNextPage%(%)%s.-)\nfunction SyncController:_prefetchNextSentence')),
    assert(text:match('(function SyncController:getProgress%(%)%s.-)\n%-%- Elapsed wall')),
    assert(text:match('(function SyncController:highlightCurrentSentence%([^\n]+.-)\n%-%-%[%[%-%-\nAdvance to the next')),
    assert(text:match('(function SyncController:seekToProgress%([^\n]+.-)\nfunction SyncController:_documentToc')),
    assert(text:match('(function SyncController:_remapAfterRotation%(%)%s.-)\n%-%-%[%[%-%-')),
}
for _,body in ipairs(bodies)do setfenv(assert(loadstring(body)),env)()end
local function fixture()
    timers={};shown={}
    local doc={pos=100,getCurrentPos=function(self)return self.pos end,getXPointer=function()return 'anchor' end}
    local queued,peeks,stops={},0,0
    local plugin={ui={rolling={},document=doc},getSetting=function(_,_,default)return default end,
        peekNextPageText=function()peeks=peeks+1;return 'Next\npage.' end}
    local engine={backend='http',BACKENDS={PIPER_HTTP='http'},
        isHTTPPageMode=function()return true end,_cancelHTTP=function()end,
        prefetchHTTPSentences=function(_,texts,limit)queued[#queued+1]={texts=texts,limit=limit}end}
    local sc=setmetatable({plugin=plugin,tts_engine=engine,text_parser=parser,
        STATE={PLAYING='playing',PAUSED='paused',LOADING='loading',STOPPED='stopped'},
        state='playing',playback_bar={},_http_page_generation=1,
        _ttsResetClock=function()end,_armTtsWaitUi=function()end,_disarmTtsWaitUi=function()end,
        readNextSentence=function(self)self.started=(self.started or 0)+1 end,
        _skipCarriedPrefix=function()error('must not skip a page prefix')end,
        _skipAlreadySpoken=function()error('must not skip already-spoken page text')end,
        _extendIncompleteLastSentence=function()error('must not append next-page words')end,
        stop=function(self)stops=stops+1;self.state='stopped';self._http_page_generation=self._http_page_generation+1 end,
    },{__index=SC})
    sc._http_page_view=Page.capture(plugin)
    sc.parsed_data=Page.parse(parser,'Current page.')
    return sc,doc,queued,function()return peeks,stops end
end
check('page reading does not call sentence carry/skip machinery',function()
    local sc=fixture();sc:_beginReadingParsed('The page ends in an incomplete',false,false)
    assert(sc.total_sentences==1 and sc.started==1)
    assert(sc.parsed_data.text=='The page ends in an incomplete' and not sc._tts_carry_skip)
end)
check('preview is deferred and queued once per page',function()
    local sc,doc,queued,stats=fixture()
    sc:planHTTPAhead();sc:planHTTPAhead()
    assert(#timers==1 and #queued==0);timers[1]()
    local peeks=stats();assert(peeks==1 and #queued==1 and queued[1].limit==1)
    assert(queued[1].texts[1]=='Next page.' and doc.pos==100)
end)
check('stale preview after stop does not navigate or download',function()
    local sc,_,queued,stats=fixture();sc:planHTTPAhead();sc:stop();timers[1]()
    local peeks=stats();assert(peeks==0 and #queued==0)
end)
check('a preview of the current page is never prequeued',function()
    local sc,_,queued=fixture();sc.plugin.peekNextPageText=function()return 'Current page.' end
    sc:planHTTPAhead();timers[1]();assert(#queued==0)
end)
check('manual view changes stop stale page audio, auto-turns do not',function()
    local sc,doc,_,stats=fixture()
    assert(not sc:onHTTPPageViewChanged())
    sc._http_page_transition=true;doc.pos=200;assert(not sc:onHTTPPageViewChanged())
    sc._http_page_transition=false;assert(sc:onHTTPPageViewChanged())
    local _,stops=stats();assert(stops==1)
end)
check('preview position drift stops playback rather than caching wrong text',function()
    local sc,doc,queued,stats=fixture()
    sc.plugin.peekNextPageText=function()doc.pos=200;return 'Wrong view.'end
    sc:planHTTPAhead();timers[1]()
    local _,stops=stats();assert(stops==1 and #queued==0)
end)
check('page progress is word-based instead of jumping to 100 percent',function()
    local sc=fixture();sc.parsed_data=Page.parse(parser,'One two three four.')
    sc.current_word_index=0;assert(sc:getProgress()==0)
    sc.current_word_index=2;assert(sc:getProgress()==50)
    sc.current_word_index=4;assert(sc:getProgress()==100)
end)
check('whole-page sentence highlight is suppressed',function()
    local sc=fixture();sc.highlight_manager={highlightSentence=function()error('page-wide selection')end}
    sc:highlightCurrentSentence(sc.parsed_data.sentences[1])
end)
check('speech-setting restart requests only the remaining page suffix',function()
    local sc=fixture();sc.parsed_data=Page.parse(parser,'One two three four.')
    local stopped,cleared,started=0,0
    sc.tts_engine.stop=function()stopped=stopped+1 end
    sc._cleanConcatFiles=function()end
    sc.highlight_manager={clearHighlights=function()cleared=cleared+1 end}
    sc.start=function(_,text,opts)started={text=text,opts=opts}end
    sc:restartHTTPPageAtWord(3)
    assert(stopped==1 and cleared==1 and started.text=='three four.' and started.opts.keep_text)
end)
check('page scrub seeks to a word, not always page start',function()
    local sc=fixture();sc.parsed_data=Page.parse(parser,'One two three four.')
    local target;sc.restartHTTPPageAtWord=function(_,index)target=index end
    sc:seekToProgress(.5);assert(target==3)
end)
check('rotation stops page audio instead of scanning document views',function()
    local sc,_,_,stats=fixture();sc:_remapAfterRotation()
    local _,stops=stats();assert(stops==1 and #shown==1)
end)
check('empty page cancels a pending remote page cache',function()
    local sc=fixture();local cancelled=0
    sc.tts_engine._cancelHTTP=function()cancelled=cancelled+1 end
    sc:_beginReadingParsed('',false,false)
    assert(cancelled==1 and sc.state=='stopped' and not sc.started)
end)
check('sentence mode keeps the original carry/parser pipeline',function()
    local sc=fixture();local extended=0
    sc.tts_engine.isHTTPPageMode=function()return false end
    sc._skipCarriedPrefix=function()return 0 end;sc._skipAlreadySpoken=function()return 0 end
    sc._extendIncompleteLastSentence=function()extended=extended+1 end
    sc:_beginReadingParsed('One sentence. Another sentence.',false,false)
    assert(not sc.parsed_data.http_page and sc.total_sentences==2 and extended==1)
end)
-- Actual preview function with a fake document; no UI page-turn event allowed.
local A={};local main=source('main.lua')
local body=assert(main:match('(function Audiobook:peekNextPageText%(%)%s.-)\n%-%- Event handlers'))
local preview_env=setmetatable({Audiobook=A,Device={screen={getWidth=function()return 300 end,getHeight=function()return 100 end,scaleBySize=function(_,n)return n end}},logger=package.loaded.logger},{__index=_G})
setfenv(assert(loadstring(body)),preview_env)()
local function preview_fixture(failure)
    local d={pos=100,getCurrentPos=function(self)return self.pos end,
        gotoPos=function(self,pos)
            self.pos=pos
            if failure=='goto' and pos==200 then error('goto failure')end
        end,getTextFromPositions=function()
            if failure=='extract' then error('extract failure')end
            return {text='Next page.'}
        end}
    local a=setmetatable({ui={document=d,rolling={},handleEvent=function()error('visible page turn')end}},{__index=A})
    return a,d
end
check('next-page preview restores position without a UI page turn',function()
    local a,d=preview_fixture();assert(a:peekNextPageText()=='Next page.' and d.pos==100 and not a._peeking_adjacent_page)
end)
check('failed extraction still restores the original view',function()
    local a,d=preview_fixture('extract');assert(not a:peekNextPageText() and d.pos==100 and not a._peeking_adjacent_page)
end)
check('navigation exceptions still restore the original view',function()
    local a,d=preview_fixture('goto');assert(not a:peekNextPageText() and d.pos==100 and not a._peeking_adjacent_page)
end)
check('end-of-book preview does not requeue the current page',function()
    local a,d=preview_fixture();d.gotoPos=function(self)self.pos=100 end
    assert(not a:peekNextPageText() and d.pos==100)
end)
check('page identity includes document identity and paging index',function()
    local doc={};local page=2
    local plugin={ui={document=doc,paging={},getCurrentPage=function()return page end}}
    local view=Page.capture(plugin);assert(Page.sameView(view,plugin))
    page=3;assert(not Page.sameView(view,plugin));page=2;plugin.ui.document={};assert(not Page.sameView(view,plugin))
end)
check('paged EPUB preview follows the visible page count and restores via gotoPage',function()
    local a,d=preview_fixture();d.page=2;d.pos=200
    a.ui.view={view_mode='page'}
    d.getCurrentPage=function(self)return self.page end
    d.getVisiblePageNumberCount=function()return 2 end
    d.gotoPage=function(self,page)self.page=page;self.pos=page*100 end
    d.gotoPos=function()error('must use page navigation')end
    d.getTextFromPositions=function(self)assert(self.page==4);return {text='Page four.'}end
    assert(a:peekNextPageText()=='Page four.' and d.page==2 and d.pos==200)
end)
check('paged preview follows hidden-flow page successors',function()
    local a,d=preview_fixture();d.page=2;d.pos=200;a.ui.view={view_mode='page'}
    d.getCurrentPage=function(self)return self.page end
    d.getVisiblePageNumberCount=function()return 2 end
    d.hasHiddenFlows=function()return true end
    d.getNextPage=function(_,page)return ({[2]=5,[5]=6})[page] or 0 end
    d.gotoPage=function(self,page)self.page=page;self.pos=page*100 end
    d.getTextFromPositions=function(self)assert(self.page==6);return {text='Page six.'}end
    assert(a:peekNextPageText()=='Page six.' and d.page==2)
end)
check('scroll preview accounts for footer height and configured overlap',function()
    local a,d=preview_fixture();a.ui.dimen={h=100}
    a.ui.view={view_mode='scroll',footer_visible=true,page_overlap_enable=true,
        footer={settings={reclaim_height=false},getHeight=function()return 10 end}}
    a.ui.rolling.configurable={font_size=10,line_spacing=100}
    d.getTextFromPositions=function(self)assert(self.pos==179);return {text='Scrolled page.'}end
    assert(a:peekNextPageText()=='Scrolled page.' and d.pos==100)
end)
local Queue=dofile(root..'piperhttpqueue.lua')
local function cache_fixture()
    local c={requests=0,request=function(self,options,cb)self.requests=self.requests+1;self.active={options=options,cb=cb};return true end,
        cancel=function(self)self.active=nil end}
    function c:finish()
        local job=self.active;self.active=nil
        local path=os.tmpname();local f=assert(io.open(path,'wb'));f:write('mock audio');f:close()
        job.cb(path);return path
    end
    local function options(text)return {url='http://piper.test:5000',voice='voice',rate=1,volume=1,text=text}end
    return Queue:new{client=c},c,options
end
check('settled page text reuses its matching normalized preview WAV',function()
    local q,c,options=cache_fixture()
    q:plan({options(Page.parse(parser,'Next\npage.').text)},1);c:finish()
    local heard=false;q:request(options(Page.parse(parser,'Next page.').text),function(path)heard=true;os.remove(path)end)
    assert(heard and c.requests==1 and q.hits==1);q:cancel()
end)
check('a wrong preview never replaces the actual settled next-page text',function()
    local q,c,options=cache_fixture();q:plan({options('Wrong preview.')},1);local wrong=c:finish()
    local heard=false;q:request(options('Actual next page.'),function(path)heard=true;os.remove(path)end)
    assert(not heard and c.requests==2 and c.active.options.text=='Actual next page.')
    q:plan({},0);assert(io.open(wrong,'rb')==nil)
    c:finish();assert(heard);q:cancel()
end)
check('disabled auto-advance does not download an unused next page',function()
    local sc,_,queued=fixture()
    sc.plugin.getSetting=function(_,key,default)if key=='auto_advance' then return false end;return default end
    sc:planHTTPAhead();assert(#timers==0 and #queued==0)
end)
check('main page-change hook also cancels stale audio while loading',function()
    local hook=assert(main:match('(function Audiobook:_dropTtsHighlightOnPageChange%(%)%s.-)\nfunction Audiobook:_currentAudioSentenceVisible'))
    setfenv(assert(loadstring(hook)),preview_env)()
    local calls=0
    local a=setmetatable({sync_controller={STATE={STOPPED='stopped',LOADING='loading'},state='loading',
        onHTTPPageViewChanged=function()calls=calls+1;return true end}},{__index=A})
    a:_dropTtsHighlightOnPageChange();assert(calls==1)
end)
print('ALL '..count..' PIPER HTTP PAGE CHECKS PASSED')
