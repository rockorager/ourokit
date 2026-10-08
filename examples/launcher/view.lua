-- The launcher's UI as a function of the chart snapshot. Shared by app.lua
-- and stories.lua; it reads the actor and sends it events, nothing else.
-- `filter` is the chart's memoized results selector (charts.lua).
return function(ouro, model, filter)
  local M = {}

  local Caption = ouro.stateless(function(p, _, theme)
    return ouro.text { key = p.key, text = p.text, size = 12, foreground = theme.colors.muted_foreground }
  end)

  local function row(launcher, entry, i, selected)
    local icon = model.icon(entry)
    return ouro.button {
      key = "row", label = model.text(entry.name) or entry.id, height = "auto",
      variant = selected and "soft" or "ghost", tone = selected and "accent" or "neutral",
      -- A click activates the entry the user saw, by id.
      send = launcher:event { type = "ACTIVATE", id = entry.id },
      children = {
        ouro.row { key = "content", gap = 12, cross_alignment = "center", padding = 6,
          icon and ouro.xdg.icon { key = "icon", name = icon, theme = "Adwaita", width = 32, height = 32, alt = "" }
            or ouro.box { key = "icon", width = 32, height = 32 },
          ouro.column { key = "labels", gap = 2, flex = 1,
            ouro.text { key = "name", text = model.text(entry.name) or entry.id, weight = "medium" },
            Caption { key = "detail", text = model.detail(entry) },
          },
        },
      },
    }
  end

  local function status(launcher, c, count)
    if launcher:matches("open.failed") then
      return "Could not list applications: " .. (c.error or "unknown error") .. " — press Enter to retry"
    elseif c.error then
      return "Could not launch: " .. c.error
    elseif launcher:matches("open.launching") then
      return "Launching " .. (model.text(c.launching.name) or c.launching.id) .. "…"
    elseif launcher:matches("open.loading") then
      return "Scanning applications…"
    elseif count == 0 then
      return c.query == "" and "No applications installed" or ("No matches for “" .. c.query .. "”")
    end
    return count == 1 and "1 application" or (count .. " applications")
  end

  -- Enter names the selected entry as of dispatch, not as of this render:
  -- a lazy payload resolves from the current snapshot, so Enter typed right
  -- after a character that has not rebuilt the view yet still launches the
  -- current top match. It resolves to nothing when nothing matches; in
  -- `open.failed` it retries the scan.
  function M.submit(launcher)
    return launcher:event(function(s)
      if ouro.machine.matches(s, "open.failed") then return { type = "ACTIVATE" } end
      local c = s.context
      local entry = filter(c.entries, c.query)[c.selected]
      return entry and { type = "ACTIVATE", id = entry.id }
    end)
  end

  function M.content(launcher)
    local c = launcher:context()
    local results = filter(c.entries, c.query)
    local close = launcher:event("CLOSE")
    local submit = M.submit(launcher)
    local list
    if #results > 0 then
      list = ouro.virtual_list {
        key = "results", flex = 1, item_count = #results, item_height = 52,
        ensure_visible = c.selected,
        item_key = function(i) return results[i].id end,
        render_item = function(i) return row(launcher, results[i], i, i == c.selected) end,
      }
    else
      list = ouro.box { key = "results", flex = 1 }
    end
    return ouro.box {
      key = "scrim", width = "fill", height = "fill", alignment = "center",
      commands = { close = close }, shortcuts = { Escape = "close" },
      ouro.box {
        key = "panel", width = 620, height = 460, padding = 14, surface = "card", border_width = 1, radius = 14,
        on_pointer_down_outside = { propagate = false, handler = close },
        ouro.column { key = "body", gap = 10, cross_alignment = "stretch",
          ouro.text_input {
            key = "search", text = c.query, label = "Search applications",
            placeholder = "Search applications…", autofocus = true,
            send = launcher:event("QUERY"),
            on_command = {
              next = launcher:event { type = "MOVE", delta = 1 },
              previous = launcher:event { type = "MOVE", delta = -1 },
              submit = submit,
              cancel = close,
            },
          },
          list,
          Caption { key = "status", text = status(launcher, c, #results) },
        },
      },
    }
  end

  -- The reactive window declaration: the surface exists exactly while the
  -- chart is open, and `send = launcher` makes it report back: mapped,
  -- close_requested, failed and closed arrive as surface.*.launcher events.
  -- Keep `content` stable so a retained surface is not rebuilt just because
  -- the declaration reran.
  function M.windows(launcher)
    local function content() return M.content(launcher) end
    return function()
      if not launcher:matches("open") then return {} end
      return { ouro.layer_surface {
        id = "launcher", namespace = "ourokit-launcher", layer = "overlay",
        width = 0, height = 0, anchors = { "top", "bottom", "left", "right" },
        keyboard_interactivity = "exclusive", background = "#10141c99",
        send = launcher, content = content,
      } }
    end
  end

  return M
end
