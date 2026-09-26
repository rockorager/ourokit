local ouro = require("ouro")
local model = require("model")(ouro.json)
local windows_changed = ouro.signal(0)
local pending_uris = {}
local filters = {{ name = "Ourokit notes", patterns = {"*.ournote"}, mime_types = {"application/vnd.ourokit.note+json"} }}

local function refresh() windows_changed:set(windows_changed() + 1) end
local function remove(d)
  model.remove(d)
  if #model.documents == 0 then ouro.exit(0) else refresh() end
end
local function notify(options)
  local client = ouro.desktop.notifications()
  if client then
    local notifications <close> = client
    notifications:send(options)
  end
end
local function report(d, message)
  d.error = message; refresh()
  notify { app_name="Ourokit Notes", title="Ourokit Notes", body=message }
end
local function edit(d, field, value)
  local ok, err = model.edit(d, field, value)
  if not ok then report(d, err) else refresh() end
end
local function open_one(uri)
  local bytes, err = ouro.files.read(uri, { max_bytes = 1024 * 1024 })
  if not bytes then return nil, err end
  local value, invalid = model.decode(bytes)
  if not value then return nil, invalid end
  local d = model.new(value.title, value.text, uri); refresh(); return d
end
local function activate(uris)
  for _, uri in ipairs(uris or {}) do
    local _, err = open_one(uri)
    if err then
      local d = model.new(); report(d, "Could not open " .. tostring(uri) .. ": " .. (err.message or tostring(err)))
    end
  end
end
local function save(d, save_as)
  local operation, busy = model.begin_save(d)
  if not operation then report(d, busy); return false end
  refresh()
  local path = not save_as and d.path
  if not path then
    local err; path, err = ouro.desktop.choose_save_file { parent=d.id, current_name=(d.title ~= "" and d.title or "Untitled")..".ournote", filters=filters }
    if not path then
      model.cancel_save(d, operation); refresh()
      if err and err.name ~= "Canceled" then report(d, err.message or "Save canceled") end
      return false
    end
  end
  local ok, err = ouro.files.write(path, operation.bytes)
  model.finish_save(d, operation, path, ok, err and (err.message or tostring(err))); refresh()
  if not ok then return false end
  notify {app_name="Ourokit Notes", title="Note saved", body=d.title}
  return true
end
local function close(d)
  if d.dirty or d.saving then d.closing = true; refresh() else remove(d) end
end
local function content(d)
  local children = {ouro.column { key="body", padding=18, gap=12, cross_alignment="stretch",
    on_drop_text=function(text) edit(d,"text",text) end,
    on_drop_uris=function(raw) activate(model.parse_uri_list(raw)) end,
      ouro.row {key="actions", gap=8,
        ouro.button {key="new", label="New", on_press=function() model.new(); refresh() end},
        ouro.button {key="open", label="Open…", on_press=function()
          local uris, err=ouro.desktop.choose_file {parent=d.id,multiple=true,filters=filters}
          if uris then activate(uris) elseif err and err.name~="Canceled" then report(d,err.message) end
        end},
        ouro.button {key="save", label="Save", enabled=not d.saving, on_press=function() save(d,false) end},
        ouro.button {key="save-as", label="Save as…", enabled=not d.saving, on_press=function() save(d,true) end},
      },
      ouro.text_input {key="title", label="Title", text=d.title, on_change=function(v) edit(d,"title",v) end},
      ouro.text_input {key="text", label="Text", text=d.text, multiline=true, height=240, on_change=function(v) edit(d,"text",v) end},
      ouro.text {key="path", text=d.dirty and ("Unsaved — "..(d.path or "no file")) or (d.path and ("Saved — "..d.path) or "New document — no file")},
      d.error and ouro.text {key="error", text=d.error} or ouro.box {key="no-error"},
      ouro.row {key="external", gap=8,
        ouro.button {key="website",label="Project website",on_press=function() ouro.desktop.open_uri("https://github.com/rockorager/ourokit",{parent=d.id}) end},
        ouro.button {key="external-file",label="Open externally",enabled=d.path~=nil,on_press=function()
          local fd,err=ouro.files.open(d.path); if not fd then report(d,err.message); return end
          local guard <close> = fd; local ok,e=ouro.desktop.open_file(fd,{parent=d.id}); if not ok then report(d,e.message) end
        end},
      },
      ouro.row {key="drag",gap=8,
        ouro.text {key="drag-help",text="Drop note files or text here, or start a drag:"},
        ouro.button {key="drag-text",label="Drag text",on_press=function()
          local ok,err=ouro.start_drag{text=d.text}; if not ok then report(d,err.name) end
        end},
        ouro.button {key="drag-file",label="Drag file",enabled=d.path~=nil,on_press=function()
          local ok,err=ouro.start_drag{uris={d.path}}; if not ok then report(d,err.name) end
        end},
      },
    }}
  if d.closing then
    local function cancel() d.closing=false; refresh() end
    children[#children+1] = ouro.dialog {key="close-confirm", label="Unsaved changes", width=430, on_cancel=cancel,
      ouro.column {key="body", gap=16,
        ouro.text {key="prompt",text="Save changes before closing?"},
        ouro.row {key="actions",gap=8,
          ouro.button {key="cancel",label="Cancel",on_press=cancel},
          ouro.button {key="close-save",label="Save",enabled=not d.saving,on_press=function()
            if save(d,false) and not d.dirty then remove(d) end
          end},
          ouro.button {key="discard",label="Discard",on_press=function() remove(d) end},
        },
      },
    }
  end
  return ouro.stack {key="drop", children=children}
end

local declaration = ouro.app {
  id="dev.ourokit.documents", single_instance=true,
  open=function(uris) if #model.documents==0 then for _,u in ipairs(uris or {}) do pending_uris[#pending_uris+1]=u end else activate(uris) end end,
  run=function()
    if #pending_uris>0 then local p=pending_uris; pending_uris={}; activate(p) end
    if #model.documents==0 then model.new() end
    return {windows=function()
      windows_changed()
      local result={}; for _,d in ipairs(model.documents) do result[#result+1]=ouro.window {id=d.id,title=(d.dirty and "* " or "")..d.title,width=800,height=650,on_close_request=function() close(d) end,content=function() return content(d) end} end
      return result
    end}
  end,
}
return declaration
