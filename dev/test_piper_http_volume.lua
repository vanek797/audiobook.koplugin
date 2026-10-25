local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local HTTP=dofile(root..'piperhttp.lua')
local function u16(v)return string.char(v%256,math.floor(v/256))end
local function u32(v)return u16(v%65536)..u16(math.floor(v/65536))end
local function wav(samples,extra,bits)
    local pcm={}
    for _,v in ipairs(samples)do pcm[#pcm+1]=u16(v<0 and v+65536 or v)end
    pcm=table.concat(pcm)
    local chunks='fmt '..u32(16)..u16(1)..u16(1)..u32(22050)..u32(44100)..u16(2)..u16(bits or 16)
        ..(extra or '')..'data'..u32(#pcm)..pcm
    return 'RIFF'..u32(#chunks+4)..'WAVE'..chunks
end
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local function write(path,s)local f=assert(io.open(path,'wb'));f:write(s);f:close()end
local function samples(s)
    local position=assert(s:find('data',1,true))+8
    local values={}
    for i=position,#s,2 do
        local v=s:byte(i)+s:byte(i+1)*256
        values[#values+1]=v>=32768 and v-65536 or v
    end
    return values,position
end
local path=os.tmpname()
local original=wav({-32768,-12000,-2,0,2,12000,32767},'JUNK'..u32(1)..'x\0')
write(path,original);assert(HTTP.scaleWav(path,.5))
local changed=read(path);local values,position=samples(changed)
assert(table.concat(values,',')=='-16384,-6000,-1,0,1,6000,16384')
assert(#changed==#original and changed:sub(1,position-1)==original:sub(1,position-1))
print('PASS 50 percent scales positive/negative PCM16 and preserves WAV metadata')
write(path,original);assert(HTTP.scaleWav(path,0));values=samples(read(path))
for _,v in ipairs(values)do assert(v==0)end
print('PASS zero percent produces silence without changing duration')
write(path,original);assert(HTTP.scaleWav(path,1) and read(path)==original)
print('PASS unity gain preserves the audio bit-for-bit')
write(path,wav({1,2},nil,8));assert(not HTTP.scaleWav(path,.5))
write(path,'not a wav');assert(not HTTP.scaleWav(path,.5))
print('PASS unsupported sample formats and malformed WAV are rejected')
os.remove(path)
local function source(name)local f=assert(io.open(root..name));local s=f:read('*a');f:close();return s end
local E={};local text=source('ttsengine.lua')
local body=assert(text:match('(function TTSEngine:_synthesizeHTTP%([^\n]+.-)\nfunction TTSEngine:_cancelHTTP'))
local options,pending
local env=setmetatable({TTSEngine=E,logger={warn=function()end},WavUtils={getDurationMs=function()return 1000 end},os={remove=function()end}},{__index=_G})
setfenv(assert(loadstring(body)),env)()
local enabled=false
local e=setmetatable({backend='http',BACKENDS={PIPER_HTTP='http'},volume=.5,rate=1,
    plugin={getSetting=function(_,key,default)
        if key=='audioout_enabled' then return enabled end
        if key=='piper_http_url' then return 'http://piper.test:5000' end
        return default
    end},
    _http={request=function(_,o,cb)options=o;pending=cb;return true end},
    generateTimingEstimates=function(self)self.timing_data={}end},{__index=E})
e:_synthesizeHTTP('test',function(ok)assert(ok)end)
assert(options.volume==.5);pending('/tmp/mock-volume.wav');assert(e._http_applied_gain==.5)
print('PASS legacy HTTP playback sends the selected gain to its worker')
body=assert(text:match('(function TTSEngine:_gstVolumeFragment%(%)%s.-)\nfunction TTSEngine:_isAudioProcessRunning'))
setfenv(assert(loadstring(body)),env)()
e._gst_volume_available=true
assert(e:_gstVolumeFragment()=='')
enabled=true;e:_synthesizeHTTP('test',function(ok)assert(ok)end)
assert(options.volume==1);pending('/tmp/mock-volume.wav');assert(e._http_applied_gain==nil)
assert(e:_gstVolumeFragment():find('0.500',1,true))
print('PASS no double attenuation; live audioout retains its own gain control')
text=source('synccontroller.lua');local SC={}
body=assert(text:match('(function SyncController:setSpeechVolumePct%([^\n]+.-)\n%-%- Scrub the page:'))
env=setmetatable({SyncController=SC},{__index=_G});setfenv(assert(loadstring(body)),env)()
local restarts,target=0,nil
local sc=setmetatable({STATE={PLAYING='playing',LOADING='loading',PAUSED='paused'},state='playing',
    tts_engine={volume=1,setVolume=function(self,v)self.volume=v end,_httpSoftwareVolume=function()return true end},
    _restartFromCurrentSentence=function(_,t)restarts=restarts+1;target=t end},{__index=SC})
sc:setSpeechVolumePct(50);assert(sc.tts_engine.volume==.5 and restarts==1)
sc:setSpeechVolumePct(50);assert(restarts==1)
print('PASS changing software volume restarts the phrase once, not on unchanged values')
sc.state='loading';sc.reading_sentence_idx=3;sc:setSpeechVolumePct(40)
assert(restarts==2 and target==3)
print('PASS loading-volume change targets the pending sentence, not the previous one')
sc.state='paused';sc:setSpeechVolumePct(30)
assert(sc._http_volume_dirty and restarts==2)
body=assert(text:match('(function SyncController:resume%([^\n]+.-)\n%-%-%[%[%-%-'))
env.logger={dbg=function()end,warn=function()end}
setfenv(assert(loadstring(body)),env)()
sc:resume(false)
assert(sc.state=='playing' and not sc._http_volume_dirty and restarts==3)
print('PASS paused volume changes remain paused and apply only on explicit resume')
local M={};text=source('menubuilder.lua')
body=assert(text:match('(function MenuBuilder.applySpeechVolume%([^\n]+.-)\nfunction MenuBuilder.buildSentencePauseMenu'))
env=setmetatable({MenuBuilder=M},{__index=_G});setfenv(assert(loadstring(body)),env)()
local percent
local plugin={sync_controller={setSpeechVolumePct=function(_,v)percent=v end},getSetting=function()return .5 end}
M.buildVolumeMenu(plugin)[2].callback();assert(percent==50)
print('PASS main volume menu uses the controller update/restart path')
local saved,applied
plugin.sync_controller=nil;plugin.setSetting=function(_,_,v)saved=v end
plugin.tts_engine={setVolume=function(_,v)applied=v end}
M.applySpeechVolume(plugin,.75);assert(saved==.75 and applied==.75)
print('PASS volume menu retains engine-only fallback without a reader controller')
print('ALL 11 PIPER HTTP VOLUME CHECKS PASSED')
