local ouro=require('ouro')
local d=ouro.dbus
assert(d)
local connected,connect_error=d.connect('session'); assert(connected,connect_error and connect_error.message)
local service <close> = connected
assert(ouro.desktop)

local function value(options,name)
  for _,item in ipairs(options) do if item[1]==name then return item[2].value end end
end
local function portal(handler)
  return {input='ssa{sv}',output='o',handler=handler}
end
local function respond(request,options,result,malformed,alternate,canceled)
  local token=assert(value(options,'handle_token'))
  local path='/org/freedesktop/portal/desktop/request/'..request.sender:sub(2):gsub('%.','_')..'/'..token
  if alternate then path='/org/freedesktop/portal/desktop/request/alternate/'..token end
  assert(service:emit{destination=request.sender,path=path,interface='org.freedesktop.portal.Request',member='Response',
    signature=malformed and 's' or 'ua{sv}',args=malformed and {'bad'} or {canceled and 1 or 0,result}})
  return {path}
end
local chooser <close> = assert(service:export{path='/org/freedesktop/portal/desktop',interface='org.freedesktop.portal.FileChooser',methods={
  OpenFile=portal(function(r)
    local title,options=r.args[2],r.args[3]
    local filters=value(options,'filters'); assert(filters and filters[1][2][1][1]==1 and filters[1][2][1][2]=='text/plain')
    return respond(r,options,{{'uris',d.variant('as',{'file:///tmp/a'} )}},title=='malformed',false,title=='canceled')
  end),
  SaveFile=portal(function(r) return respond(r,r.args[3],{{'uris',d.variant('as',{'file:///tmp/out'})}}) end),
},signals={}})
local opener <close> = assert(service:export{path='/org/freedesktop/portal/desktop',interface='org.freedesktop.portal.OpenURI',methods={
  OpenURI=portal(function(r)
    local options=r.args[3]; assert(value(options,'ask')==true and value(options,'writable')==true and value(options,'activation_token')=='token')
    return respond(r,options,{},false,true)
  end),
  OpenFile={input='sha{sv}',output='o',handler=function(r)
    assert(type(r.args[2])=='userdata'); r.args[2]:close()
    return respond(r,r.args[3],{})
  end},
  OpenDirectory={input='sha{sv}',output='o',handler=function(r)
    assert(type(r.args[2])=='userdata'); r.args[2]:close()
    assert(value(r.args[3],'activation_token')=='folder-token')
    assert(value(r.args[3],'ask')==nil and value(r.args[3],'writable')==nil)
    return respond(r,r.args[3],{})
  end},
},signals={}})
local trash_result=1
local trash <close> = assert(service:export{path='/org/freedesktop/portal/desktop',interface='org.freedesktop.portal.Trash',methods={
  TrashFile={input='h',output='u',handler=function(r)
    assert(type(r.args[1])=='userdata'); r.args[1]:close(); return {trash_result}
  end},
},signals={}})
local portal_name <close> = assert(service:own_name('org.freedesktop.portal.Desktop'))

local next_id=1
local notification_export <close> = assert(service:export{path='/org/freedesktop/Notifications',interface='org.freedesktop.Notifications',methods={
  Notify={input='susssasa{sv}i',output='u',handler=function(r)
    local replaces=r.args[2]
    if replaces~=0 then return {replaces} end
    local id=next_id; next_id=next_id+1; return {id}
  end},
  CloseNotification={input='u',output='',handler=function() return {} end},
},signals={ActionInvoked='us',ActivationToken='us',NotificationClosed='uu'}})
local notification_name <close> = assert(service:own_name('org.freedesktop.Notifications'))

local files=assert(ouro.desktop.choose_file{filters={{name='Text',mime_types={'text/plain'}}}})
assert(files[1]=='file:///tmp/a')
assert(ouro.desktop.choose_save_file{}=='file:///tmp/out')
local ok,e=ouro.desktop.choose_file{title='malformed',filters={{name='Text',mime_types={'text/plain'}}}}
assert(ok==nil and e.name=='MalformedPortalResponse')
ok,e=ouro.desktop.choose_file{title='canceled',filters={{name='Text',mime_types={'text/plain'}}}}
assert(ok==nil and e.name=='Canceled')
ok,e=ouro.desktop.choose_file{parent='missing'}; assert(ok==nil and e.name=='WindowExportUnavailable')
ok,e=ouro.desktop.open_uri('file:///tmp/no')
assert(ok==nil and e.name=='FileURI' and e.message:find('open_file'))
ok,e=ouro.desktop.open_uri('FILE:relative'); assert(ok==nil and e.name=='FileURI')
assert(ouro.desktop.open_uri('https://example.test',{ask=true,writable=true,activation_token='token'}))
local fd <close> = assert(ouro.files.open(ouro.xdg.runtime_dir..'/document'))
assert(ouro.desktop.open_file(fd))
assert(ouro.desktop.show_in_folder(fd,{activation_token='folder-token'}))
local writable_fd <close> = assert(ouro.files.open(ouro.xdg.runtime_dir..'/document',{writable=true}))
assert(ouro.desktop.trash(writable_fd))
trash_result=0; ok,e=ouro.desktop.trash(writable_fd); assert(ok==nil and e.name=='TrashFailed')
trash_result=2; ok,e=ouro.desktop.trash(writable_fd); assert(ok==nil and e.name=='TrashFailed')
assert(ouro.files.read(ouro.xdg.runtime_dir..'/document')=='external-open fixture','no permanent-delete fallback')
ok,e=ouro.desktop.trash('not an fd'); assert(ok==nil and e.name=='InvalidFile')
ok,e=ouro.desktop.show_in_folder(fd,{activation_token=1}); assert(ok==nil and e.name=='InvalidOptions')
ok,e=ouro.desktop.choose_file('bad'); assert(ok==nil and e.name=='InvalidOptions')
ok,e=ouro.desktop.choose_file{multiple='yes'}; assert(ok==nil and e.name=='InvalidOptions')
ok,e=ouro.desktop.open_uri('https://example.test',{ask='yes'}); assert(ok==nil and e.name=='InvalidOptions')

local client <close> = assert(ouro.desktop.notifications())
local handle=assert(client:send{title='one',actions={{id='open',label='Open'}}})
assert(client:replace(handle,{title='two'})==handle)
assert(service:emit{path='/org/freedesktop/Notifications',interface='org.freedesktop.Notifications',member='ActivationToken',signature='us',args={handle.id,'activation'}})
assert(service:emit{path='/org/freedesktop/Notifications',interface='org.freedesktop.Notifications',member='ActionInvoked',signature='us',args={handle.id,'open'}})
local event=assert(client:next(3000)); assert(event.type=='action' and event.action=='open' and event.activation_token=='activation')
assert(client:withdraw(handle))
ok,e=client:withdraw(handle); assert(ok==nil and e.name=='StaleNotification')
local closed=assert(client:send{title='close event'})
assert(service:emit{path='/org/freedesktop/Notifications',interface='org.freedesktop.Notifications',member='NotificationClosed',signature='uu',args={closed.id,2}})
event=assert(client:next()); assert(event.type=='closed' and event.reason==2 and event.notification==closed)
ok,e=client:replace(closed,{title='too late'}); assert(ok==nil and e.name=='StaleNotification')
ok,e=client:next(2); assert(ok==nil and e.name=='Timeout')
notification_name:close()
ok,e=client:next(3000); assert(ok==nil and e.name=='ServiceDisappeared')
client:close()
ok,e=client:next(); assert(ok==nil and e.name=='Closed')
ouro.stdout.write('PASS desktop services\n')
ouro.exit(0)
