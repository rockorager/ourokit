-- App-owned formats over XDG paths and async file I/O; no framework settings database.
local ouro = require('ouro')
local paths = assert(ouro.xdg.paths('dev.ourokit.documents'))
local M = {}
local function read(directory, name)
  if not directory then return nil end
  local bytes = ouro.files.read(directory..'/'..name, {max_bytes=1024*1024})
  if not bytes then return nil end
  local ok, value = pcall(ouro.json.decode, bytes)
  if ok and type(value)=='table' and value.version==1 then return value end
end
function M.load()
  local preferences = read(paths.config, 'preferences.json') or {}
  local state = read(paths.state, 'session.json') or {}
  local position = preferences.split_position
  if type(position)~='number' or position<0.1 or position>0.8 then position=0.25 end
  local uris={}
  if type(state.uris)=='table' then
    for _,uri in ipairs(state.uris) do
      if #uris==32 then break end
      if type(uri)=='string' and (uri:sub(1,1)=='/' or uri:sub(1,5)=='file:') then uris[#uris+1]=uri end
    end
  end
  return position, uris, type(state.selected)=='string' and state.selected or nil
end
local function write(directory, name, value)
  if not directory then return nil,{name='DirectoryUnavailable',message='XDG storage directory is unavailable'} end
  local ok,e=ouro.files.mkdir(directory); if not ok then return nil,e end
  return ouro.files.write(directory..'/'..name,ouro.json.encode(value))
end
function M.save(position, documents, selected)
  local uris=ouro.json.array({})
  for _,d in ipairs(documents) do
    if d.path and #uris<32 then uris[#uris+1]=d.path end
  end
  local ok,e=write(paths.config,'preferences.json',{version=1,split_position=position})
  if not ok then return nil,e end
  return write(paths.state,'session.json',{version=1,uris=uris,selected=selected and selected.path})
end
return M
