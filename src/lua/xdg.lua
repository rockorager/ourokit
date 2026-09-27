local ouro, env = ...
local xdg = ouro.xdg or {}
ouro.xdg = xdg
local function failure(name, message) return nil, {kind='xdg', name=name, message=message} end
local function absolute(value)
  return type(value)=='string' and value:sub(1,1)=='/' and not value:find('\0',1,true)
end
local function join(root, name) return root:gsub('/+$','')..'/'..name end
local home = absolute(env.HOME) and env.HOME or nil
local function base(key, fallback)
  if absolute(env[key]) then return env[key] end
  return home and join(home, fallback) or nil
end
local bases = {
  config=base('XDG_CONFIG_HOME','.config'), data=base('XDG_DATA_HOME','.local/share'),
  state=base('XDG_STATE_HOME','.local/state'), cache=base('XDG_CACHE_HOME','.cache'),
  runtime=absolute(xdg.runtime_dir) and xdg.runtime_dir or nil,
}
local function roots(key, fallback, first)
  local out={}
  if first then out[1]=first end
  local value=env[key]; if value==nil or value=='' then value=fallback end
  for part in value:gmatch('[^:]+') do if absolute(part) then out[#out+1]=part end end
  return out
end
local config_roots=roots('XDG_CONFIG_DIRS','/etc/xdg',bases.config)
local data_roots=roots('XDG_DATA_DIRS','/usr/local/share:/usr/share',bases.data)
function xdg.paths(application_id)
  if type(application_id)~='string' or #application_id>255 or not application_id:find('%.') then
    return failure('InvalidApplicationId','expected a dotted application ID')
  end
  for part in (application_id..'.'):gmatch('(.-)%.') do
    if not part:match('^[A-Za-z_][A-Za-z0-9_-]*$') then
      return failure('InvalidApplicationId','invalid application ID component')
    end
  end
  local out={config_dirs={},data_dirs={}}
  for name,root in pairs(bases) do out[name]=join(root,application_id) end
  for i,root in ipairs(config_roots) do out.config_dirs[i]=join(root,application_id) end
  for i,root in ipairs(data_roots) do out.data_dirs[i]=join(root,application_id) end
  return out
end

local user_kinds={desktop=true,documents=true,download=true,music=true,pictures=true,publicshare=true,templates=true,videos=true}
-- Parse the data format without sourcing a shell file. Only the leading $HOME
-- substitution and double-quote escapes defined by user-dirs are interpreted.
local function user_path(raw)
  local prefix=''
  if raw:sub(1,5)=='$HOME' and (raw:sub(6,6)=='/' or #raw==5) then
    if not home then return nil end
    prefix=home; raw=raw:sub(6)
  end
  local out={prefix}; local i=1
  while i<=#raw do
    local ch=raw:sub(i,i)
    if ch=='\\' then
      i=i+1; local next_ch=raw:sub(i,i)
      if next_ch=='' then return nil end
      if next_ch~='\\' and next_ch~='"' and next_ch~='$' and next_ch~='`' then out[#out+1]='\\' end
      out[#out+1]=next_ch
    elseif ch=='$' or ch=='`' or ch=='"' then return nil
    else out[#out+1]=ch end
    i=i+1
  end
  local value=table.concat(out)
  return absolute(value) and value or nil
end
function xdg.user_dir(kind)
  if not user_kinds[kind] then return failure('InvalidUserDirectory','unknown user directory kind') end
  if not bases.config then return failure('DirectoryUnavailable','configuration directory is unavailable') end
  local bytes,e=ouro.files.read(join(bases.config,'user-dirs.dirs'),{max_bytes=65536})
  if not bytes then
    if e and e.name=='FileNotFound' then return home end
    return nil,e
  end
  local found
  for line in (bytes..'\n'):gmatch('(.-)\n') do
    local key,raw=line:match('^%s*XDG_([A-Z]+)_DIR%s*=%s*"(.*)"%s*$')
    if key and key:lower()==kind then found=user_path(raw) or found end
  end
  return found or home
end
