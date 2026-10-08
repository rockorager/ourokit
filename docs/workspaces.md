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
    return ouro.text { key = "unavailable", text = "Workspaces unavailable" }
  end

  local children = {}
  for index, workspace in ipairs(state.workspaces) do
    children[#children + 1] = ouro.button {
      key = workspace.id or tostring(index),
      label = workspace.name,
      enabled = workspace.can_activate and not workspace.active,
      on_press = workspace.activate,
    }
  end
  return ouro.row {
    key = "workspaces",
    children = children,
  }
end
```

The content function returns one root description. The loop builds a dense,
ordered child table; widget constructors return descriptions rather than
emitting UI. Native lowering consumes the returned tree during reconciliation.

The session is callable. Each call returns the latest complete protocol
snapshot and subscribes the current UI build like an Ouro signal. Changes are
published only after the compositor's `done` event, so a build never observes a
partially updated protocol batch.

`state.available` becomes true after the first complete snapshot. It remains
false when the compositor does not advertise `ext_workspace_manager_v1`.
`state.workspaces` contains workspace tables with:

- `id` (optional stable string), `name`, and `coordinates`;
- `outputs`, a dense array of `wl_output.name` strings for every output in the
  workspace's group (empty until an output has supplied a name);
- `active`, `urgent`, and `hidden` state flags;
- `can_activate`, `can_deactivate`, and `can_remove` capability flags;
- `activate()`, `deactivate()`, and `remove()` request functions.

Requests are queued until Ouro's task safe point and sent as one protocol batch
followed by `ext_workspace_manager_v1.commit`. The compositor may ignore a
request; applications should use the corresponding capability flag when
deciding whether to expose an action.

Output and workspace membership changes become visible together at the
workspace manager's `done` boundary. Output discovery, renaming, and removal
also refresh snapshots; names are copied and no transient Wayland object IDs
are exposed. The API intentionally omits workspace-group creation and
assignment.

## Watching workspaces from a chart

A statechart cannot read the reactive session: its state changes come from
events. `ouro.shell.workspaces.watch()` is the event source. It returns a
watcher whose `watcher:next()` returns the current snapshot on the first call.
Each later call parks the calling task until the next `done` batch and then
returns that snapshot. Run it in an invoke, which owns the task, and send each
snapshot to the chart:

```lua
local ouro = require("ouro")
local machine = ouro.machine

local bar = machine.create {
  id = "bar", initial = "watching",
  context = { available = false, workspaces = {} },
  events = { WORKSPACES = { snapshot = "table" }, ACTIVATE = { handle = "string" } },
  actions = {
    store = machine.assign(function(_, e)
      return { available = e.snapshot.available, workspaces = e.snapshot.workspaces }
    end),
    activate = function(_, e) ouro.shell.workspaces.activate(e.handle) end,
  },
  actors = {
    watch = function(_, send)
      local watcher <close> = ouro.shell.workspaces.watch()
      while true do send { type = "WORKSPACES", snapshot = watcher:next() } end
    end,
  },
  states = {
    watching = { invoke = { src = "watch" }, on = { WORKSPACES = { actions = "store" }, ACTIVATE = { actions = "activate" } } },
  },
}
```

The view reads `bar:context().workspaces` and sends
`{ type = "ACTIVATE", handle = workspace.handle }`.

Watch snapshots have the same `available` and workspace fields as the session,
except that they are plain data and can be kept in context, persisted, and
carried across reload. Instead of request closures, each workspace has an
opaque `handle` string. Pass it to `ouro.shell.workspaces.activate(handle)`,
`deactivate(handle)` or `remove(handle)`. These queue the same batched
requests as the session's functions, and they raise an error for a workspace
that no longer exists. They do not wait, so a chart action may call them.

Watching costs nothing until it is used. The protocol is bound only after the
first `connect()` or `watch()`, and a watcher holds no native resources while
its task is not parked in `next`. Closing the watcher stops it. So does its
scope ending: a `<close>` local in an invoke closes when the state exits. A
task parked in `next` when its watcher is closed from elsewhere resumes with
the error `workspace watch canceled`. Several watchers may be open at once, and
`watch()` can be used with or without `connect()`.

### Testing

The Sway used by `tests/desktop_native.py`, and so by
`tests/verify_development.py`, does not implement ext-workspace-v1. CI
therefore runs the workspace test through `tests/workspace_proxy.py`. The proxy
forwards all traffic between the application and Sway, file descriptors
included, and serves a fake `ext_workspace_manager_v1` with a scripted group
and workspaces. Behavior against real compositors with ext-workspace-v1 is
checked manually.
