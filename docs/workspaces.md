# Shell workspaces

Ouro exposes the optional Wayland `ext-workspace-v1` protocol as a reactive Lua
API under `ouro.shell.workspaces`. Merely loading `ouro` does not bind the
protocol. Calling `connect` opts that application connection in:

```lua
local ouro = require("ouro")
local workspaces = ouro.shell.workspaces.connect()

local function content()
  local state = workspaces()
  if not state.available then
    return ouro.label { key = "unavailable", text = "Workspaces unavailable" }
  end

  return ouro.row {
    key = "workspaces",
    children = function()
      for index, workspace in ipairs(state.workspaces) do
        ouro.button {
          key = workspace.id or tostring(index),
          label = workspace.name,
          enabled = workspace.can_activate and not workspace.active,
          on_press = workspace.activate,
        }
      end
    end,
  }
end
```

The session is callable. Each call returns the latest complete protocol
snapshot and subscribes the current UI build like an Ouro signal. Changes are
published only after the compositor's `done` event, so a build never observes a
partially updated protocol batch.

`state.available` becomes true after the first complete snapshot. It remains
false when the compositor does not advertise `ext_workspace_manager_v1`.
`state.workspaces` contains workspace tables with:

- `id` (optional stable string), `name`, and `coordinates`;
- `active`, `urgent`, and `hidden` state flags;
- `can_activate`, `can_deactivate`, and `can_remove` capability flags;
- `activate()`, `deactivate()`, and `remove()` request functions.

Requests are queued until Ouro's task safe point and sent as one protocol batch
followed by `ext_workspace_manager_v1.commit`. The compositor may ignore a
request; applications should use the corresponding capability flag when
deciding whether to expose an action.

The first API intentionally omits workspace-group creation and assignment.
Those require a useful Lua representation for output/group identity rather
than leaking transient Wayland object IDs.
