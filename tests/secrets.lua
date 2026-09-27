local ouro=require('ouro')
local function assert(value,err)
  if not value then error(type(err)=='table' and err.name or (err or 'assertion failed'),2) end
  return value
end
local function run()
local d=assert(ouro.dbus)
assert(ouro.secrets)
local service <close> = assert(d.connect('session'))

local service_path='/org/freedesktop/secrets'
local collection_path='/org/freedesktop/secrets/collection/default'
local item_path='/org/freedesktop/secrets/collection/default/item'
local session_path='/org/freedesktop/secrets/session/test'
local prompt_path='/org/freedesktop/secrets/prompt/test'
local values={}
local locked, prompt_mode, malformed, sessions_closed, dismissals=false,nil,false,0,0
local owner_ref, replacement_owner
local replacement <close> = assert(d.connect('session'))
local get_calls, create_calls, update_calls=0,0,0
local create_prompt, delete_prompt, failed_unlock=false,false,false

local function attrs_to_key(attrs)
  local app,key
  for _,pair in ipairs(attrs) do
    if pair[1]=='ourokit.application' then app=pair[2] end
    if pair[1]=='ourokit.key' then key=pair[2] end
  end
  return app and key and app..'\0'..key, key
end
local function variant(options,name)
  for _,pair in ipairs(options) do if pair[1]==name then return pair[2] end end
end

local prompt <close> = assert(service:export{path=prompt_path,interface='org.freedesktop.Secret.Prompt',methods={
  Prompt={input='s',output='',handler=function(r)
    local dismissed=prompt_mode=='cancel'
    local result = create_prompt and d.variant('o',item_path) or
      (delete_prompt and d.variant('s','') or d.variant('ao',locked and {item_path} or {collection_path}))
    -- Deliberately before the method reply: the client must already subscribe.
    assert(service:emit{destination=r.sender,path=prompt_path,interface='org.freedesktop.Secret.Prompt',
      member='Completed',signature='bv',args={dismissed,result}})
    if not dismissed then locked=false end
    return {}
  end},
  Dismiss={input='',output='',handler=function() dismissals=dismissals+1; return {} end},
},signals={Completed='bv'}})
local session <close> = assert(service:export{path=session_path,interface='org.freedesktop.Secret.Session',methods={
  Close={input='',output='',handler=function() sessions_closed=sessions_closed+1; return {} end},
},signals={}})
local item <close> = assert(service:export{path=item_path,interface='org.freedesktop.Secret.Item',methods={
  GetSecret={input='o',output='(oayays)',handler=function(r)
    get_calls=get_calls+1
    local value=assert(values.current)
    if malformed then return {{'/wrong/session','not-empty',value,'application/octet-stream'}} end
    return {{r.args[1],'',value,'application/octet-stream'}}
  end},
  SetSecret={input='(oayays)',output='',handler=function(r)
    update_calls=update_calls+1; values[values.current_key]=r.args[1][3]; return {}
  end},
  Delete={input='',output='o',handler=function()
    values[values.current_key]=nil; values.current=nil
    return {delete_prompt and prompt_path or '/'}
  end},
},signals={}})
local collection <close> = assert(service:export{path=collection_path,interface='org.freedesktop.Secret.Collection',methods={
  CreateItem={input='a{sv}(oayays)b',output='oo',handler=function(r)
    create_calls=create_calls+1
    local attrs=assert(variant(r.args[1],'org.freedesktop.Secret.Item.Attributes')).value
    local key=assert(attrs_to_key(attrs)); values[key]=r.args[2][3]
    assert(r.args[3]==true and r.args[2][1]==session_path and r.args[2][2]=='')
    return {create_prompt and '/' or item_path,create_prompt and prompt_path or '/'}
  end},
},signals={}})
local missing_default=false
local api <close> = assert(service:export{path=service_path,interface='org.freedesktop.Secret.Service',methods={
  OpenSession={input='sv',output='vo',handler=function(r)
    assert(r.args[1]=='plain' and r.args[2].signature=='s' and r.args[2].value=='')
    return {d.variant('s',''),session_path}
  end},
  ReadAlias={input='s',output='o',handler=function() return {missing_default and '/' or collection_path} end},
  SearchItems={input='a{ss}',output='aoao',handler=function(r)
    local key,name=attrs_to_key(r.args[1])
    if name=='service-failure' then return nil,{name='org.freedesktop.Secret.Error.NoSuchObject',message='fixture failure'} end
    if name=='duplicate' then return {{item_path,item_path},{}} end
    if name=='owner-change' then
      owner_ref:close(); ouro.sleep(5)
      replacement_owner=assert(replacement:own_name('org.freedesktop.secrets'))
      return {{item_path},{}}
    end
    if name=='slow' then ouro.sleep(20) end
    values.current_key=key; values.current=values[key]
    prompt_mode=name=='cancel' and values.current and 'cancel' or nil
    locked=(name=='cancel' or name=='early') and values.current~=nil
    if not values.current then return {{},{}} end
    return {locked and {} or {item_path},locked and {item_path} or {}}
  end},
  Unlock={input='ao',output='aoo',handler=function(r)
    if failed_unlock then return {{},'/'} end
    if locked or prompt_mode=='cancel' then return {{},prompt_path} end
    return {r.args[1],'/'}
  end},
},signals={}})
local owner <close> = assert(service:own_name('org.freedesktop.secrets'))
owner_ref=owner

local app='com.example.SecretsTest'
local binary='zero\0byte\255tail'
assert(ouro.secrets.get(app,'missing')==nil)
assert(ouro.secrets.delete(app,'missing')==false)
assert(ouro.secrets.set(app,'binary',binary))
assert(ouro.secrets.get(app,'binary')==binary)
assert(ouro.secrets.set(app,'binary','replacement'))
assert(create_calls==1 and update_calls==1,'overwrite must update the existing item, not create another')
assert(ouro.secrets.get(app,'binary')=='replacement')
assert(ouro.secrets.delete(app,'binary')==true)
assert(ouro.secrets.get(app,'binary')==nil)

assert(ouro.secrets.set(app,'early','unlocked by early signal'))
locked=true
assert(ouro.secrets.get(app,'early')=='unlocked by early signal')
assert(ouro.secrets.set(app,'cancel','never returned'))
locked=true
local value,e=ouro.secrets.get(app,'cancel')
assert(value==nil and e.kind=='secrets' and e.name=='Canceled')
locked=false; prompt_mode=nil

assert(ouro.secrets.set(app,'malformed','private'))
malformed=true; value,e=ouro.secrets.get(app,'malformed'); malformed=false
assert(value==nil and e.name=='MalformedReply' and not e.message:find('private',1,true))
value,e=ouro.secrets.get(app,'service-failure')
assert(value==nil and e.kind=='secrets' and e.name=='ServiceFailure')
missing_default=true; value,e=ouro.secrets.set(app,'no-default','private'); missing_default=false
assert(value==nil and e.name=='NoDefaultCollection' and not e.message:find('private',1,true))
value,e=ouro.secrets.get(app,'duplicate'); assert(value==nil and e.name=='Ambiguous')
failed_unlock=true; value,e=ouro.secrets.set(app,'locked','private'); failed_unlock=false
assert(value==nil and e.name=='Locked')
create_prompt=true; assert(ouro.secrets.set(app,'create-prompt','prompt value')); create_prompt=false
assert(ouro.secrets.get(app,'create-prompt')=='prompt value')
delete_prompt=true; assert(ouro.secrets.delete(app,'create-prompt')); delete_prompt=false
assert(ouro.secrets.set('org.example.OtherApp','malformed','other value'))
assert(ouro.secrets.get(app,'malformed')=='private')
assert(ouro.secrets.get('org.example.OtherApp','malformed')=='other value')

local ticked=false
ouro.spawn(function() ouro.sleep(2); ticked=true end)
value,e=ouro.secrets.get(app,'slow')
assert(value==nil and e==nil and ticked,'secret calls must not block the scheduler')
value,e=ouro.secrets.get('', 'key'); assert(value==nil and e.name=='InvalidArgument')
value,e=ouro.secrets.set(app,'key',nil); assert(value==nil and e.name=='InvalidArgument')
assert(sessions_closed>0)
local before=get_calls
value,e=ouro.secrets.get(app,'owner-change')
assert(value==nil and e.name=='ServiceDisappeared' and get_calls==before,'owner changes must not expose secrets')
replacement_owner:close(); ouro.sleep(5)
value,e=ouro.secrets.get(app,'missing-service')
assert(value==nil and (e.name=='ServiceUnavailable' or e.name=='ServiceFailure'))
ouro.stdout.write('PASS secrets\n')
ouro.exit(0)
end
local ok,e=pcall(run)
if not ok then ouro.stdout.write('FAIL secrets: '..tostring(e)..'\n'); ouro.exit(1) end
