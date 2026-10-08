local ouro, setmetatable = ...
local d = ouro.dbus
local portal_name, portal_path = 'org.freedesktop.portal.Desktop', '/org/freedesktop/portal/desktop'
local request_iface = 'org.freedesktop.portal.Request'
local serial = 0

local function failure(name, message) return nil, {kind='desktop', name=name, message=message} end
-- Options often come from statechart context, whose tables are read-only
-- views (userdata); read them as the tables behind them.
local function raw(value) return ouro.machine and ouro.machine.raw(value) or value end
local function table_options(value)
  value = raw(value)
  if value == nil then return {} end
  if type(value) ~= 'table' then return nil, {kind='desktop',name='InvalidOptions',message='options must be a table'} end
  return value
end
local function option(out, name, signature, value)
  if value ~= nil then out[#out+1] = {name, d.variant(signature, value)} end
end
local function typed_option(options,name,kind)
  local value=options[name]
  if value~=nil and type(value)~=kind then return failure('InvalidOptions',name..' must be a '..kind) end
  return value
end
local function common_options(options)
  local _,e=typed_option(options,'parent','string'); if e then return nil,e end
  _,e=typed_option(options,'title','string'); if e then return nil,e end
  return true
end
local function parent(options)
  local id = options.parent
  if id == nil then return '', nil end
  if type(id) ~= 'string' then return failure('InvalidParent', 'parent must be a window id string') end
  if type(ouro._desktop_parent) ~= 'function' then return failure('ParentExportUnavailable', 'window export is unavailable') end
  local export, err = ouro._desktop_parent(id)
  if not export then return nil, err or {kind='desktop',name='ParentExportFailed',message='could not export parent window'} end
  if type(export.handle) ~= 'string' or export.handle:sub(1,8) ~= 'wayland:' then
    if export.close then export:close() end
    return failure('ParentExportFailed', 'window export returned no Wayland handle')
  end
  return export.handle, export
end
local function token()
  serial = serial + 1
  return ('ouro_%x_%x'):format(ouro.time(), serial)
end
local function portal_request(interface, member, signature, args, options, decode)
  local bus, err = d.connect('session'); if not bus then return nil, err end
  local guard = setmetatable({bus=bus}, {__close=function(g)
    if g.path then pcall(g.bus.send,g.bus,{destination=portal_name,path=g.path,interface=request_iface,member='Close',signature='',args={}}) end
    if g.stream then g.stream:close() end; if g.export then g.export:close() end; g.bus:close()
  end})
  local close_guard <close> = guard
  local p, export = parent(options); if not p then return nil, export end
  guard.export=export
  local stream, suberr = bus:subscribe{sender=portal_name, interface=request_iface, member='Response',close_on_owner_change=true}
  if not stream then return nil, suberr end
  guard.stream=stream
  local handle_token = token()
  local unique = bus:unique_name()
  local predicted = '/org/freedesktop/portal/desktop/request/'..unique:sub(2):gsub('%.','_')..'/'..handle_token
  guard.path=predicted
  option(args[#args], 'handle_token', 's', handle_token)
  args[1] = p
  local reply, callerr = bus:call{destination=portal_name,path=portal_path,interface=interface,member=member,signature=signature,args=args,timeout_ms=5000}
  if not reply then return nil, callerr end
  if reply.signature ~= 'o' or type(reply.args) ~= 'table' or type(reply.args[1]) ~= 'string' then
    return failure('MalformedPortalReply','portal returned an invalid request handle')
  end
  local returned = reply.args[1]
  guard.path=returned
  -- Human interaction is not a timed RPC. The initial method reply is bounded,
  -- but the chooser stays open until its response or the caller's cancellation.
  while true do
    local message, nexterr = stream:next()
    if not message then return nil, nexterr end
    if message.path == predicted or message.path == returned then
      guard.path = nil
      if message.signature ~= 'ua{sv}' or type(message.args) ~= 'table' or type(message.args[1]) ~= 'number' or type(message.args[2]) ~= 'table' then
        return failure('MalformedPortalResponse','portal returned a malformed Response signal')
      end
      if message.args[1] == 1 then return failure('Canceled','the request was canceled') end
      if message.args[1] ~= 0 then return failure('PortalFailure','the portal could not complete the request') end
      return decode(message.args[2])
    end
  end
end
local function dict(result,key,signature)
  if type(result) ~= 'table' then return nil end
  for _,item in ipairs(result) do
    if type(item)=='table' and item[1]==key and type(item[2])=='userdata' and item[2].signature==signature then return item[2].value end
  end
end
local function filters(value)
  value = raw(value)
  if value == nil then return nil end
  if type(value) ~= 'table' then return nil, 'filters must be a table' end
  local out={}
  for i,filter in ipairs(value) do
    filter = raw(filter)
    if type(filter)~='table' or type(filter.name)~='string' then return nil,'filter #'..i..' needs a name' end
    local rules={}
    local patterns, mime_types = raw(filter.patterns), raw(filter.mime_types)
    if patterns ~= nil and type(patterns)~='table' then return nil,'filter patterns must be a table' end
    if mime_types ~= nil and type(mime_types)~='table' then return nil,'filter MIME types must be a table' end
    for _,pattern in ipairs(patterns or {}) do if type(pattern)~='string' then return nil,'filter pattern must be a string' end; rules[#rules+1]={0,pattern} end
    for _,mime in ipairs(mime_types or {}) do if type(mime)~='string' then return nil,'filter MIME type must be a string' end; rules[#rules+1]={1,mime} end
    if #rules==0 then return nil,'filter #'..i..' has no patterns or MIME types' end
    out[#out+1]={filter.name,rules}
  end
  return out
end
local desktop={}
function desktop.choose_file(options)
  local e; options,e=table_options(options); if not options then return nil,e end
  local valid; valid,e=common_options(options); if not valid then return nil,e end
  local multiple; multiple,e=typed_option(options,'multiple','boolean'); if e then return nil,e end
  local directory; directory,e=typed_option(options,'directory','boolean'); if e then return nil,e end
  local opts={}; local fs,fe=filters(options.filters); if fe then return failure('InvalidFilters',fe) end
  option(opts,'multiple','b',multiple); option(opts,'directory','b',directory); option(opts,'filters','a(sa(us))',fs)
  return portal_request('org.freedesktop.portal.FileChooser','OpenFile','ssa{sv}',{'',options.title or 'Open File',opts},options,function(r)
    local uris=dict(r,'uris','as'); if type(uris)~='table' then return failure('MalformedPortalResponse','successful chooser response has no URIs') end; return uris
  end)
end
function desktop.choose_save_file(options)
  local e; options,e=table_options(options); if not options then return nil,e end
  local valid; valid,e=common_options(options); if not valid then return nil,e end
  local current_name; current_name,e=typed_option(options,'current_name','string'); if e then return nil,e end
  local current_folder; current_folder,e=typed_option(options,'current_folder','string'); if e then return nil,e end
  local opts={}; local fs,fe=filters(options.filters); if fe then return failure('InvalidFilters',fe) end
  option(opts,'current_name','s',current_name); option(opts,'current_folder','ay',current_folder and (current_folder..'\0')); option(opts,'filters','a(sa(us))',fs)
  return portal_request('org.freedesktop.portal.FileChooser','SaveFile','ssa{sv}',{'',options.title or 'Save File',opts},options,function(r)
    local uris=dict(r,'uris','as'); if type(uris)~='table' or #uris~=1 then return failure('MalformedPortalResponse','save response must contain one URI') end; return uris[1]
  end)
end
local function open_options(options)
  local out={}; option(out,'ask','b',options.ask); option(out,'writable','b',options.writable); option(out,'activation_token','s',options.activation_token); return out
end
local function validate_open_options(options)
  local valid,e=common_options(options); if not valid then return nil,e end
  for _,item in ipairs{{'ask','boolean'},{'writable','boolean'},{'activation_token','string'}} do
    local _,oe=typed_option(options,item[1],item[2]); if oe then return nil,oe end
  end
  return true
end
function desktop.open_uri(uri,options)
  if type(uri)~='string' or uri=='' then return failure('InvalidURI','URI must be a non-empty string') end
  if uri:match('^[Ff][Ii][Ll][Ee]:') then return failure('FileURI','file: URIs are not accepted; use ouro.desktop.open_file instead') end
  local e; options,e=table_options(options); if not options then return nil,e end
  local valid; valid,e=validate_open_options(options); if not valid then return nil,e end
  return portal_request('org.freedesktop.portal.OpenURI','OpenURI','ssa{sv}',{'',uri,open_options(options)},options,function() return true end)
end
function desktop.open_file(fd,options)
  if type(fd)~='userdata' then return failure('InvalidFile','file must be a D-Bus file-descriptor value') end
  local e; options,e=table_options(options); if not options then return nil,e end
  local valid; valid,e=validate_open_options(options); if not valid then return nil,e end
  return portal_request('org.freedesktop.portal.OpenURI','OpenFile','sha{sv}',{'',fd,open_options(options)},options,function() return true end)
end

function desktop.show_in_folder(fd,options)
  if type(fd)~='userdata' then return failure('InvalidFile','file must be a D-Bus file-descriptor value') end
  local e; options,e=table_options(options); if not options then return nil,e end
  local valid; valid,e=common_options(options); if not valid then return nil,e end
  local activation; activation,e=typed_option(options,'activation_token','string'); if e then return nil,e end
  local opts={}; option(opts,'activation_token','s',activation)
  return portal_request('org.freedesktop.portal.OpenURI','OpenDirectory','sha{sv}',{'',fd,opts},options,function() return true end)
end
function desktop.trash(fd)
  if type(fd)~='userdata' then return failure('InvalidFile','file must be a D-Bus file-descriptor value') end
  local bus,e=d.connect('session'); if not bus then return nil,e end
  local guard <close> = bus
  local r; r,e=bus:call{destination=portal_name,path=portal_path,interface='org.freedesktop.portal.Trash',member='TrashFile',signature='h',args={fd},timeout_ms=5000}
  if not r then return nil,e end
  if r.signature~='u' or type(r.args)~='table' or #r.args~=1 or type(r.args[1])~='number' then
    return failure('MalformedPortalReply','trash portal returned a malformed reply')
  end
  if r.args[1]~=1 then return failure('TrashFailed','the portal did not trash the file') end
  return true
end

local notify_name,notify_path='org.freedesktop.Notifications','/org/freedesktop/Notifications'
local notifications={}; notifications.__index=notifications
local function notification_args(spec,replaces)
  spec = raw(spec)
  if type(spec)~='table' then return nil,'notification must be a table' end
  for _,item in ipairs{{'app_name','string'},{'icon','string'},{'title','string'},{'body','string'},{'timeout','number'}} do
    if spec[item[1]]~=nil and type(spec[item[1]])~=item[2] then return nil,item[1]..' must be a '..item[2] end
  end
  if spec.timeout~=nil and (spec.timeout%1~=0 or spec.timeout < -1 or spec.timeout>2147483647) then return nil,'timeout must be an integer from -1 to 2147483647' end
  local actions={}
  local spec_actions = raw(spec.actions)
  if spec_actions~=nil and type(spec_actions)~='table' then return nil,'actions must be a table' end
  for i,a in ipairs(spec_actions or {}) do a=raw(a); if type(a)~='table' or type(a.id)~='string' or type(a.label)~='string' then return nil,'invalid action #'..i end; actions[#actions+1]=a.id; actions[#actions+1]=a.label end
  local hints={}; if spec.hints~=nil and type(spec.hints)~='table' then return nil,'hints must be a table' end
  for k,v in pairs(spec.hints or {}) do if type(k)~='string' or type(v)~='userdata' then return nil,'hints must map strings to D-Bus variants' end; hints[#hints+1]={k,v} end
  return {spec.app_name or '',replaces or 0,spec.icon or '',spec.title or '',spec.body or '',actions,hints,spec.timeout or -1}
end
function desktop.notifications()
  local bus,err=d.connect('session'); if not bus then return nil,err end
  local guard <close> = setmetatable({bus=bus}, {__close=function(g) if g.bus then g.bus:close() end end})
  local events,e=bus:subscribe{sender=notify_name,path=notify_path,interface=notify_name,close_on_owner_change=true}
  if not events then return nil,e end
  guard.bus=nil
  return setmetatable({bus=bus,events=events,active={},tokens={},closed=false},{__index=notifications,__close=notifications.close})
end
function notifications:send(spec)
  if self.closed then return failure('Closed','notification client is closed') end
  local args,e=notification_args(spec,0); if not args then return failure('InvalidNotification',e) end
  local r,err=self.bus:call{destination=notify_name,path=notify_path,interface=notify_name,member='Notify',signature='susssasa{sv}i',args=args}
  if not r then return nil,err end
  if r.signature~='u' or type(r.args)~='table' or type(r.args[1])~='number' or r.args[1]==0 or type(r.sender)~='string' or r.sender:sub(1,1)~=':' then return failure('MalformedNotificationReply','notification daemon returned an invalid reply') end
  local h={id=r.args[1],owner=r.sender}; self.active[h.id]=h; return h
end
function notifications:replace(handle,spec)
  if type(handle)~='table' or self.active[handle.id]~=handle then return failure('StaleNotification','notification is no longer active') end
  local args,e=notification_args(spec,handle.id); if not args then return failure('InvalidNotification',e) end
  local r,err=self.bus:call{destination=handle.owner,path=notify_path,interface=notify_name,member='Notify',signature='susssasa{sv}i',args=args}
  if not r then self.active[handle.id]=nil; return nil,err end
  if r.sender~=handle.owner or r.signature~='u' or type(r.args)~='table' or r.args[1]~=handle.id then self.active[handle.id]=nil; return failure('ServiceRestarted','notification service changed during replacement') end
  self.tokens[handle.id]=nil; return handle
end
function notifications:withdraw(handle)
  if type(handle)~='table' or self.active[handle.id]~=handle then return failure('StaleNotification','notification is no longer active') end
  local r,e=self.bus:call{destination=handle.owner,path=notify_path,interface=notify_name,member='CloseNotification',signature='u',args={handle.id}}
  if not r then self.active[handle.id]=nil; return nil,e end
  self.active[handle.id]=nil; self.tokens[handle.id]=nil; return true
end
function notifications:next(timeout_ms)
  if self.closed then return failure('Closed','notification client is closed') end
  if timeout_ms~=nil and (type(timeout_ms)~='number' or timeout_ms<1 or timeout_ms>2147483647 or timeout_ms%1~=0) then return failure('InvalidTimeout','timeout_ms must be an integer from 1 to 2147483647') end
  local deadline=timeout_ms and (ouro._monotonic_ms()+timeout_ms)
  while not self.closed do
    local remaining=deadline and (deadline-ouro._monotonic_ms())
    if remaining and remaining<=0 then return failure('Timeout','notification event timed out') end
    local m,e=self.events:next(remaining)
    if m then
      if type(m.args)=='table' and type(m.args[1])=='number' then
        local h=self.active[m.args[1]]
        if h and h.owner==m.sender then
          if m.member=='ActivationToken' and m.signature=='us' and type(m.args[2])=='string' then self.tokens[h.id]=m.args[2]
          elseif m.member=='ActionInvoked' and m.signature=='us' and type(m.args[2])=='string' then return {type='action',notification=h,action=m.args[2],activation_token=self.tokens[h.id]}
          elseif m.member=='NotificationClosed' and m.signature=='uu' and type(m.args[2])=='number' then self.active[h.id]=nil; self.tokens[h.id]=nil; return {type='closed',notification=h,reason=m.args[2]} end
        end
      end
    else
      if e and e.name=='ServiceDisappeared' then self:close() end
      return nil,e
    end
  end
  return failure('Closed','notification client is closed')
end
function notifications:close()
  if self.closed then return true end; self.closed=true
  if self.events then self.events:close(); self.events=nil end
  if self.bus then self.bus:close(); self.bus=nil end; self.active={}; self.tokens={}; return true
end
desktop.notification_client=desktop.notifications
ouro.desktop=desktop
