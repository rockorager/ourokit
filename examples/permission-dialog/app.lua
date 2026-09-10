local ouro = require("ouro")

-- One JSON request, delimited by EOF. The caller closes its write end after
-- sending the request, but keeps the child's stdout open for the decision.
local request_bytes = ""
while true do
  local chunk = ouro.stdin.read(4096)
  if chunk == nil then break end
  request_bytes = request_bytes .. chunk
  if #request_bytes > 65536 then ouro.exit(2) end
end
local request = ouro.json.decode(request_bytes)
local confirmation, message = ouro.signal(""), ouro.signal("This permission applies to one screenshot.")
local busy, terminal = ouro.signal(false), ouro.signal(false)

local function decide(allowed)
  if busy() then return end
  if allowed and confirmation() ~= "ALLOW" then
    message:set("Type ALLOW before granting screen access.")
    return
  end
  busy:set(true)
  -- Real async work: a slow reader can backpressure stdout. The UI remains
  -- responsive, but cannot send a second decision while this write is pending.
  ouro.stdout.write(ouro.json.encode({ allowed = allowed }) .. "\n")
  ouro.exit(0)
end

local function content()
  local dark = terminal()
  return ouro.theme {
    key = "dialog", color_scheme = dark and "dark" or "light",
    colors = dark and { background = "#101810", foreground = "#b4f889", primary = "#244524", primary_hover = "#365c26", primary_foreground = "#d6ffb3", input = "#568845", ring = "#b4f889" } or nil,
    typography = { family = dark and "monospace" or "sans-serif", size = 16 },
    controls = { height = 40, radius = dark and 0 or 10, border_width = dark and 1 or 0 },
    widgets = { text_input = { border_width = 1 } },
    ouro.box { key = "inset", padding = 24,
      ouro.column { key = "body", gap = 18, cross_alignment = "stretch",
        ouro.row { key = "heading", gap = 14, cross_alignment = "center",
          ouro.icon { key = "shield", src = "assets/shield-check.svg", width = 40, height = 40, alt = "Permission" },
          ouro.text { key = "title", text = "Screen access", size = 26, flex = 1 },
          ouro.button { key = "theme", label = dark and "Light style" or "Terminal style", enabled = not busy(), on_press = function() terminal:set(not terminal()) end },
        },
        ouro.text { key = "requester", text = (request.app_name or "An application") .. " wants to capture your screen." },
        ouro.text { key = "privacy", text = "Your screen may contain private information. Type ALLOW to confirm." },
        ouro.text_input { key = "confirmation", text = confirmation(), on_change = function(value)
          confirmation:set(value)
          message:set(value == "ALLOW" and "Ready to allow one screenshot." or "This permission applies to one screenshot.")
        end },
        ouro.text { key = "status", text = busy() and "Sending decision…" or message() },
        ouro.row { key = "buttons", gap = 12,
          ouro.button { key = "deny", label = "Don't allow", flex = 1, enabled = not busy(), on_press = function() decide(false) end },
          ouro.button { key = "allow", label = "Allow screenshot", flex = 1, enabled = not busy(), on_press = function() decide(true) end },
        },
      },
    },
  }
end

return ouro.app {
  id = "dev.ourokit.permission-dialog",
  -- No actions or interface: no listening socket, service, or IPC discovery.
  run = function()
    return { windows = { ouro.window { id = "permission", title = "Screenshot permission", width = 620, height = 420, content = content } } }
  end,
}
