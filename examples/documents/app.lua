local ouro = require("ouro")
local model = require("model")(ouro.json)
local storage = require("storage")
local filters = {{ name = "Ourokit notes", patterns = {"*.ournote"}, mime_types = {"application/vnd.ourokit.note+json"} }}

local function notify(options)
  local client = ouro.desktop.notifications()
  if client then local notifications <close> = client; notifications:send(options) end
end

local charts = require("charts")(ouro, model, {
  choose = function(name)
    return ouro.desktop.choose_save_file { parent = "main", current_name = name, filters = filters }
  end,
  write = function(path, bytes) return ouro.files.write(path, bytes) end,
  notify = notify,
  persist = function(split, paths, selected)
    local documents = {}
    for i, path in ipairs(paths) do documents[i] = { path = path } end
    local ok, err = storage.save(split, documents, selected and { path = selected })
    if not ok then ouro.stderr.write("Could not save Notes session: " .. err.name .. "\n") end
  end,
  exit = function() ouro.exit(0) end,
})

local notes -- The application actor, started by run.
local pending_uris = {}

-- Reading files has no state of its own; results arrive as ADD events.
local function read_note(uri)
  local bytes, err = ouro.files.read(uri, { max_bytes = 1024 * 1024 })
  if not bytes then return nil, err end
  local value, invalid = model.decode(bytes)
  if not value then return nil, invalid end
  return value
end
local function activate(uris)
  for _, uri in ipairs(uris or {}) do
    local value, err = read_note(uri)
    if value then
      notes:send { type = "ADD", title = value.title, text = value.text, path = uri }
    else
      local message = "Could not open " .. tostring(uri) .. ": " .. model.message(err)
      notify { app_name = "Ourokit Notes", title = "Ourokit Notes", body = message }
      notes:send { type = "ADD", error = message }
    end
  end
end

local function content(doc)
  local d = doc:context()
  local function report(err) doc:send { type = "REPORT", message = model.message(err) } end
  local function edit(field) return function(value) doc:send { type = "EDIT", field = field, value = value } end end
  local children = {
      ouro.row {key="actions", gap=8,
        ouro.button {key="new", label="New", on_press=notes:sender("NEW")},
        ouro.button {key="open", label="Open…", on_press=function()
          local uris, err=ouro.desktop.choose_file {parent="main",multiple=true,filters=filters}
          if uris then activate(uris) elseif err and err.name~="Canceled" then report(err) end
        end},
        ouro.button {key="save", label="Save", enabled=doc:can("SAVE"), on_press=doc:sender("SAVE")},
        ouro.button {key="save-as", label="Save as…", enabled=doc:can("SAVE_AS"), on_press=doc:sender("SAVE_AS")},
      },
      ouro.text_input {key="title", label="Title", text=d.title, on_change=edit("title")},
      ouro.text_input {key="text", label="Text", text=d.text, multiline=true, flex=1, on_change=edit("text")},
      ouro.text {key="path", text=model.dirty(d) and ("Unsaved — "..(d.path or "no file")) or (d.path and ("Saved — "..d.path) or "New document — no file")},
      d.error and ouro.text {key="error", text=d.error} or ouro.box {key="no-error"},
      ouro.row {key="external", gap=8,
        ouro.button {key="website",label="Project website",on_press=function() ouro.desktop.open_uri("https://github.com/rockorager/ourokit",{parent="main"}) end},
        ouro.button {key="external-file",label="Open externally",enabled=d.path~=nil,on_press=function()
          local fd,err=ouro.files.open(d.path); if not fd then report(err); return end
          local guard <close> = fd; local ok,e=ouro.desktop.open_file(fd,{parent="main"}); if not ok then report(e) end
        end},
      },
      ouro.text {key="drag-help",text="Drop note files or text here, or start a drag:"},
      ouro.row {key="drag",gap=8,
        -- Drags need the press's input capability, so they stay in the callback.
        ouro.button {key="drag-text",label="Drag text",on_press=function() local ok,err=ouro.start_drag{text=d.text}; if not ok then report(err) end end},
        ouro.button {key="drag-file",label="Drag file",enabled=d.path~=nil,on_press=function() local ok,err=ouro.start_drag{uris={d.path}}; if not ok then report(err) end end},
      },
  }
  local dialog
  if doc:matches("open.lifecycle.confirming") then
    dialog = ouro.dialog {key="close-confirm", label="Unsaved changes", width=430, on_cancel=doc:sender("CANCEL"),
      ouro.column {key="body", gap=16,
        ouro.text {key="prompt",text="Save changes to “"..d.title.."” before closing?"},
        ouro.row {key="actions",gap=8,
          ouro.button {key="cancel",label="Cancel",on_press=doc:sender("CANCEL")},
          ouro.button {key="close-save",label="Save",enabled=doc:can("SAVE"),on_press=doc:sender("SAVE")},
          ouro.button {key="discard",label="Discard",enabled=doc:can("DISCARD"),on_press=doc:sender("DISCARD")},
        },
      },
    }
  end
  return ouro.box {key="drop", width="fill", height="fill", padding=18,
    on_drop_text=edit("text"),
    on_drop_uris=function(raw) activate(model.parse_uri_list(raw)) end,
    ouro.stack {key="layers",
      ouro.column {key="body", gap=12, cross_alignment="stretch", children=children},
      dialog,
    },
  }
end

local function main_content()
  local app = notes:context()
  local options, tabs = {}, {}
  for _, doc in ipairs(notes:children()) do
    local d = doc:context()
    local dirty = model.dirty(d)
    options[#options+1] = ouro.option {key=d.id, value=d.tab_value, label=(dirty and "• " or "")..d.title}
    tabs[#tabs+1] = {value=d.tab_value, label=(dirty and "* " or "")..d.title, closable=true, content=content(doc)}
  end
  local function select(value) notes:send {type="SELECT", value=value} end
  return ouro.split_view {key="documents", axis="horizontal", position=app.split, min_first=160, min_second=560,
    on_change=function(fraction) notes:send {type="RESIZE", position=fraction} end,
    ouro.box {key="sidebar", padding=10, surface="sidebar",
      ouro.column {key="body", gap=8, cross_alignment="stretch",
        ouro.text {key="heading", text="Documents"},
        ouro.listbox {key="list", selected=app.selected, on_select=select, children=options},
      },
    },
    ouro.tabs {key="tabs", label="Open documents", selected=app.selected, on_select=select,
      on_close=function(value) notes:send {type="CLOSE_TAB", value=value} end,
      tabs=tabs,
    },
  }
end

return ouro.app {
  id="dev.ourokit.documents", single_instance=true,
  open=function(uris)
    if not notes or #notes:children()==0 then
      for _,u in ipairs(uris or {}) do pending_uris[#pending_uris+1]=u end
    else activate(uris) end
  end,
  run=function()
    local split,restored,selected=storage.load()
    notes = charts.notes:start { input = { split = split } }
    if #pending_uris==0 then
      -- Reopen saved files only. Never resurrect discarded edits or overwrite files.
      local selected_value
      for _,uri in ipairs(restored) do
        local value = read_note(uri)
        if value then
          notes:send { type = "ADD", title = value.title, text = value.text, path = uri }
          if uri == selected then selected_value = notes:context().selected end
        end
      end
      if selected_value then notes:send { type = "SELECT", value = selected_value } end
    end
    if #pending_uris>0 then local p=pending_uris; pending_uris={}; activate(p) end
    if #notes:children()==0 then notes:send("NEW") end
    return {windows=function()
      return {ouro.window {id="main",title="Ourokit Notes",width=1000,height=720,
        on_close_request=notes:sender("CLOSE_WINDOW"),content=main_content}}
    end}
  end,
}
