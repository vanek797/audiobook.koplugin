local root=(debug.getinfo(1,'S').source:match('^@(.*/)') or './')..'../'
local HTTP=dofile(root..'piperhttp.lua')
local f=assert(io.open(root..'menubuilder.lua'));local source=f:read('*a');f:close()
local first=assert(source:find('local function httpModule()',1,true))
local last=assert(source:find('--[[--\nBuild Piper voice model selection menu.',first,true))
local M={};local dialog,shown,stops,closed,input= nil,nil,0,0,''
local Input={new=function(_,options)
    dialog=options
    function options:getInputText()return input end
    function options:onShowKeyboard()self.keyboard_shown=true end
    return options
end}
local ui={show=function(_,widget)shown=widget end,close=function()closed=closed+1 end}
local env=setmetatable({MenuBuilder=M,UIManager=ui,_=function(x)return x end,
    InfoMessage={new=function(_,o)return o end},
    require=function(name)assert(name=='ui/widget/inputdialog');return Input end,
    dofile=function(path)assert(path:match('piperhttp.lua$'));return HTTP end,
},{__index=_G})
setfenv(assert(loadstring(source:sub(first,last-1))),env)()
local settings={}
local plugin={getSetting=function(_,k,d)if settings[k]~=nil then return settings[k]end;return d end,
    setSetting=function(_,k,v)settings[k]=v end,sync_controller={stop=function()stops=stops+1 end}}
M.showHTTPServerDialog(plugin)
assert(dialog.input=='' and dialog.keyboard_shown and shown==dialog)
print('PASS URL field is empty by default and opens the on-device keyboard')
input=' http://piper.test:5000/// ';dialog.buttons[1][2].callback()
assert(settings.piper_http_url=='http://piper.test:5000' and closed==1 and stops==1)
print('PASS Save persists the normalized manually entered server URL')
M.showHTTPServerDialog(plugin);assert(dialog.input=='http://piper.test:5000')
input='http://piper.test/invalid';dialog.buttons[1][2].callback()
assert(settings.piper_http_url=='http://piper.test:5000' and closed==1 and stops==1 and shown.text)
print('PASS invalid server URL does not replace the saved setting')
local voices=M.buildHTTPVoiceMenu(plugin)
assert(#voices==6 and voices[1].checked_func())
voices[2].callback();assert(settings.piper_http_voice=='en_US-amy-medium' and voices[2].checked_func())
voices[3].callback();assert(settings.piper_http_voice=='de_DE-ramona-low' and voices[3].checked_func())
local expected={'ru_RU-irina-medium','en_US-amy-medium','de_DE-ramona-low',
    'en_US-lessac-medium','en_US-lessac-high','en_US-libritts-high'}
for i,id in ipairs(expected)do
    local before=stops
    voices[i].callback()
    assert(settings.piper_http_voice==id and voices[i].checked_func() and stops==before+1)
    for j,item in ipairs(voices)do assert(item.checked_func()==(i==j))end
end
print('PASS all six voice callbacks save the correct id, stop old audio, and update selection')
input='';dialog.buttons[1][2].callback();assert(settings.piper_http_url=='')
print('PASS URL can be cleared without restoring any implicit server')
f=assert(io.open(root..'package-for-kobo.sh'));source=f:read('*a');f:close()
assert(source:find('piperhttp.lua',1,true))
print('PASS release packager includes the remote backend module')
local planned=0;plugin.sync_controller.planHTTPAhead=function()planned=planned+1 end
local ahead=M.buildHTTPAheadMenu(plugin)
assert(#ahead==9 and ahead[4].checked_func())
ahead[6].callback();assert(settings.piper_http_lookahead==5 and planned==1)
ahead[1].callback();assert(settings.piper_http_lookahead==0 and planned==2)
assert(source:find('piperhttpqueue.lua',1,true))
print('PASS editable lookahead applies the window and packages its queue module')
local modes=M.buildHTTPModeMenu(plugin);local old_stops=stops;local closed_menu=0
assert(#modes==2 and modes[1].checked_func())
modes[2].callback({closeMenu=function()closed_menu=closed_menu+1 end})
assert(settings.piper_http_mode=='page' and modes[2].checked_func() and stops==old_stops+1 and closed_menu==1)
modes[1].callback();assert(settings.piper_http_mode=='sentences' and stops==old_stops+2)
assert(source:find('piperhttppage.lua',1,true))
print('PASS page mode is opt-in, saved on-device, and stops the previous session')
print('ALL 8 PIPER HTTP MENU CHECKS PASSED')
