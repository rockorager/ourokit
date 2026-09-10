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

local function decide(allowed)
  ouro.stdout.write(ouro.json.encode({ allowed = allowed }) .. "\n")
  ouro.exit(0)
end

return ouro.app {
  id = "dev.ourokit.permission-dialog",
  -- No actions or interface: no listening socket, service, or IPC discovery.
  run = function()
    return { windows = {
      ouro.window {
        id = "permission",
        title = "Screenshot permission",
        width = 520,
        height = 300,
        content = function()
          ouro.box {
            key = "dialog",
            padding = 28,
            children = function()
              ouro.column {
                key = "body",
                gap = 20,
                cross_alignment = "stretch",
                children = function()
                  ouro.label { key = "title", text = "Allow a screenshot?", size = 24 }
                  ouro.label {
                    key = "requester",
                    text = (request.app_name or "An application") .. " wants to capture your screen.",
                  }
                  ouro.label {
                    key = "privacy",
                    text = "Your screen may contain private information.",
                  }
                  ouro.label { key = "scope", text = "This permission applies to one screenshot." }
                  ouro.row {
                    key = "buttons",
                    gap = 12,
                    children = function()
                      ouro.button {
                        key = "deny", label = "Don't allow", width = 218, height = 44,
                        on_press = function() decide(false) end,
                      }
                      ouro.button {
                        key = "allow", label = "Allow screenshot", width = 218, height = 44,
                        on_press = function() decide(true) end,
                      }
                    end,
                  }
                end,
              }
            end,
          }
        end,
      },
    } }
  end,
}
