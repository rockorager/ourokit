local ouro, setmetatable = ...
local d = ouro.dbus
local service_name = 'org.freedesktop.secrets'
local service_path = '/org/freedesktop/secrets'
local service_iface = 'org.freedesktop.Secret.Service'
local collection_iface = 'org.freedesktop.Secret.Collection'
local item_iface = 'org.freedesktop.Secret.Item'
local prompt_iface = 'org.freedesktop.Secret.Prompt'
local session_iface = 'org.freedesktop.Secret.Session'

local function failure(name, message)
  return nil, {kind='secrets', name=name, message=message}
end
local function transport(err)
  if type(err) ~= 'table' then return failure('ServiceFailure', 'Secret Service operation failed') end
  local name = 'ServiceFailure'
  if err.name=='ServiceDisappeared' or err.name=='org.freedesktop.DBus.Error.NameHasNoOwner' then name='ServiceDisappeared'
  elseif err.name=='org.freedesktop.DBus.Error.ServiceUnknown' then name='ServiceUnavailable'
  elseif err.name=='org.freedesktop.Secret.Error.IsLocked' then name='Locked' end
  return failure(name, 'Secret Service operation failed')
end
local function valid_string(value, what)
  if type(value) ~= 'string' or value == '' then return failure('InvalidArgument', what..' must be a non-empty string') end
  if value:find('\0', 1, true) then return failure('InvalidArgument', what..' must not contain NUL') end
  return true
end
local function call(ctx, path, interface, member, signature, args)
  if ctx.owner then
    local owner,e=ctx.bus:call{destination='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='GetNameOwner',signature='s',args={service_name},timeout_ms=5000}
    if not owner then return transport(e) end
    if owner.signature~='s' or owner.args[1]~=ctx.owner then return failure('ServiceDisappeared','Secret Service owner changed') end
  end
  local reply, err = ctx.bus:call{destination=ctx.owner or service_name,path=path,interface=interface,member=member,
    signature=signature,args=args,timeout_ms=5000}
  if not reply then return transport(err) end
  return reply
end
local function reply(reply, signature, count, name)
  if type(reply)~='table' or reply.signature~=signature or type(reply.args)~='table' or #reply.args~=count then
    return failure(name or 'MalformedReply', 'Secret Service returned a malformed reply')
  end
  return reply.args
end
local function path(value) return type(value)=='string' and value:sub(1,1)=='/' end
local function paths(value)
  if type(value)~='table' then return false end
  for _,v in ipairs(value) do if not path(v) then return false end end
  return true
end

-- Subscribe before the operation that may create a prompt. This also handles a
-- service that emits Completed before Prompt's method reply is delivered.
local function prompt(ctx, prompt_path)
  if prompt_path == '/' then return true end
  if not path(prompt_path) then return failure('MalformedReply','Secret Service returned an invalid prompt path') end
  local guard <close> = setmetatable({path=prompt_path,active=true},{__close=function(g)
    if g.active then pcall(ctx.bus.send,ctx.bus,{destination=ctx.owner,path=g.path,interface=prompt_iface,
      member='Dismiss',signature='',args={}}) end
  end})
  local r,e=call(ctx,prompt_path,prompt_iface,'Prompt','s',{''}); if not r then return nil,e end
  local a; a,e=reply(r,'',0,'MalformedPromptReply'); if not a then return nil,e end
  while true do
    local message,next_error=ctx.prompts:next()
    if not message then return transport(next_error) end
    if message.path==prompt_path and message.sender==ctx.owner then
      guard.active=false
      if message.signature~='bv' or type(message.args)~='table' or type(message.args[1])~='boolean'
        or type(message.args[2])~='userdata' then
        return failure('MalformedPromptResponse','Secret Service returned a malformed prompt response')
      end
      if message.args[1] then return failure('Canceled','Secret Service prompt was canceled') end
      return message.args[2]
    end
  end
end

local function close_context(ctx)
  if ctx.session then pcall(ctx.bus.send,ctx.bus,{destination=ctx.owner,path=ctx.session,interface=session_iface,member='Close',signature='',args={}}) end
  if ctx.prompts then ctx.prompts:close() end
  ctx.bus:close()
end
local function context()
  local bus,err=d.connect('session'); if not bus then return transport(err) end
  local ctx=setmetatable({bus=bus},{__close=close_context})
  -- Construction itself yields, so it needs a cancellation guard as well.
  local cleanup <close> = setmetatable({ctx=ctx}, {__close=function(g)
    if g.ctx then close_context(g.ctx) end
  end})
  local prompts,e=bus:subscribe{sender=service_name,interface=prompt_iface,member='Completed',close_on_owner_change=true}
  if not prompts then return transport(e) end
  ctx.prompts=prompts
  local r; r,e=call(ctx,service_path,service_iface,'OpenSession','sv',{'plain',d.variant('s','')})
  if not r then return nil,e end
  local a; a,e=reply(r,'vo',2,'MalformedSessionReply')
  if not a then return nil,e end
  if type(a[1])~='userdata' or a[1].signature~='s' or a[1].value~='' or not path(a[2]) or a[2]=='/' or type(r.sender)~='string' or r.sender:sub(1,1)~=':' then
    return failure('MalformedSessionReply','Secret Service returned a malformed session')
  end
  ctx.session=a[2]; ctx.owner=r.sender
  cleanup.ctx=nil
  return ctx
end
local function attributes(application_id,key)
  return {{'xdg:schema','org.ourokit.Secret'}, {'ourokit.application',application_id}, {'ourokit.key',key}}
end
local function validate(application_id,key,value)
  local ok,e=valid_string(application_id,'application_id'); if not ok then return nil,e end
  ok,e=valid_string(key,'key'); if not ok then return nil,e end
  if value~=nil and type(value)~='string' then return failure('InvalidArgument','value must be a string') end
  return true
end
local function unlock(ctx, requested)
  local r,e=call(ctx,service_path,service_iface,'Unlock','ao',{requested}); if not r then return nil,e end
  local a; a,e=reply(r,'aoo',2); if not a then return nil,e end
  if not paths(a[1]) or not path(a[2]) then return failure('MalformedReply','Secret Service returned a malformed unlock reply') end
  local unlocked=a[1]
  if a[2]~='/' then
    local result; result,e=prompt(ctx,a[2]); if not result then return nil,e end
    if result.signature~='ao' or not paths(result.value) then return failure('MalformedPromptResponse','Secret Service returned malformed unlocked paths') end
    for _,item in ipairs(result.value) do unlocked[#unlocked+1]=item end
  end
  for _,item in ipairs(requested) do
    local found=false
    for _,value in ipairs(unlocked) do if value==item then found=true end end
    if not found then return failure('Locked','Secret Service did not unlock the requested object') end
  end
  return true
end
local function search(ctx, application_id, key)
  local r,e=call(ctx,service_path,service_iface,'SearchItems','a{ss}',{attributes(application_id,key)}); if not r then return nil,e end
  local a; a,e=reply(r,'aoao',2); if not a then return nil,e end
  if not paths(a[1]) or not paths(a[2]) then return failure('MalformedReply','Secret Service returned malformed item paths') end
  if #a[1]+#a[2]>1 then return failure('Ambiguous','Secret Service contains multiple items for this application and key') end
  if #a[2]>0 then
    local ok; ok,e=unlock(ctx,a[2]); if not ok then return nil,e end
    return a[2][1]
  end
  return a[1][1]
end

local secrets={}
function secrets.get(application_id,key)
  local ok,e=validate(application_id,key); if not ok then return nil,e end
  local ctx; ctx,e=context(); if not ctx then return nil,e end
  local close_ctx <close> = ctx
  local item; item,e=search(ctx,application_id,key); if e then return nil,e end
  if not item then return nil end
  local r; r,e=call(ctx,item,item_iface,'GetSecret','o',{ctx.session}); if not r then return nil,e end
  local a; a,e=reply(r,'(oayays)',1); if not a then return nil,e end
  local secret=a[1]
  if type(secret)~='table' or #secret~=4 or secret[1]~=ctx.session or type(secret[2])~='string'
    or type(secret[3])~='string' or type(secret[4])~='string' or #secret[2]~=0 then
    return failure('MalformedReply','Secret Service returned a malformed plain-session secret')
  end
  return secret[3]
end
function secrets.set(application_id,key,value)
  local ok,e=validate(application_id,key,value); if not ok then return nil,e end
  if type(value)~='string' then return failure('InvalidArgument','value must be a string') end
  local ctx; ctx,e=context(); if not ctx then return nil,e end
  local close_ctx <close> = ctx
  local secret={ctx.session,'',value,'application/octet-stream'}
  local existing; existing,e=search(ctx,application_id,key); if e then return nil,e end
  if existing then
    local updated; updated,e=call(ctx,existing,item_iface,'SetSecret','(oayays)',{secret}); if not updated then return nil,e end
    local a; a,e=reply(updated,'',0); if not a then return nil,e end
    return true
  end
  local collection_reply; collection_reply,e=call(ctx,service_path,service_iface,'ReadAlias','s',{'default'}); if not collection_reply then return nil,e end
  local ca; ca,e=reply(collection_reply,'o',1); if not ca then return nil,e end
  local collection=ca[1]; if not path(collection) then return failure('MalformedReply','Secret Service returned an invalid collection path') end
  if collection=='/' then return failure('NoDefaultCollection','Secret Service has no default collection') end
  local unlocked; unlocked,e=unlock(ctx,{collection}); if not unlocked then return nil,e end
  local props={{'org.freedesktop.Secret.Item.Label',d.variant('s',application_id..': '..key)},
    {'org.freedesktop.Secret.Item.Attributes',d.variant('a{ss}',attributes(application_id,key))}}
  local cr; cr,e=call(ctx,collection,collection_iface,'CreateItem','a{sv}(oayays)b',{props,secret,true}); if not cr then return nil,e end
  local aa; aa,e=reply(cr,'oo',2); if not aa then return nil,e end
  if not path(aa[1]) or not path(aa[2]) then return failure('MalformedReply','Secret Service returned malformed create paths') end
  local result; result,e=prompt(ctx,aa[2]); if not result then return nil,e end
  if aa[1]=='/' and (type(result)~='userdata' or result.signature~='o' or not path(result.value) or result.value=='/') then
    return failure('MalformedPromptResponse','Secret Service did not return the created item')
  end
  return true
end
function secrets.delete(application_id,key)
  local ok,e=validate(application_id,key); if not ok then return nil,e end
  local ctx; ctx,e=context(); if not ctx then return nil,e end
  local close_ctx <close> = ctx
  local item; item,e=search(ctx,application_id,key); if e then return nil,e end
  if not item then return false end
  local dr; dr,e=call(ctx,item,item_iface,'Delete','',{}); if not dr then return nil,e end
  local da; da,e=reply(dr,'o',1); if not da then return nil,e end
  if not path(da[1]) then return failure('MalformedReply','Secret Service returned an invalid delete prompt') end
  local _,pe=prompt(ctx,da[1]); if pe then return nil,pe end
  return true
end
ouro.secrets=secrets
