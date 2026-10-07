-- The launcher's UI as a function of the chart snapshot. Shared by app.lua
-- and stories.lua; it reads the actor and sends it events, nothing else.
return function(ouro, model)
  local M = {}

  local Caption = ouro.stateless(function(p, _, theme)
    return ouro.text { key = p.key, text = p.text, size = 12, foreground = theme.colors.muted_foreground }
  end)

  local function row(launcher, entry, i, selected)
    local icon = model.icon(entry)
    return ouro.button {
      key = "row", label = model.text(entry.name) or entry.id, height = "auto",
      variant = selected and "soft" or "ghost", tone = selected and "accent" or "neutral",
      on_press = launcher:sender { type = "ACTIVATE", index = i },
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

  function M.content(launcher)
    local c = launcher:context()
    local results = model.results(c.entries, c.query)
    local close = launcher:sender("CLOSE")
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
            on_change = function(text) launcher:send { type = "QUERY", text = text } end,
            on_command = function(command)
              if command == "next" then launcher:send { type = "MOVE", delta = 1 }
              elseif command == "previous" then launcher:send { type = "MOVE", delta = -1 }
              elseif command == "submit" then launcher:send("ACTIVATE")
              elseif command == "cancel" then close() end
            end,
          },
          list,
          Caption { key = "status", text = status(launcher, c, #results) },
        },
      },
    }
  end

  -- The reactive window declaration: the surface exists exactly while the
  -- chart is open. Keep `content` stable so a retained surface is not rebuilt
  -- just because the declaration reran.
  function M.windows(launcher)
    local function content() return M.content(launcher) end
    return function()
      if not launcher:matches("open") then return {} end
      return { ouro.layer_surface {
        id = "launcher", namespace = "ourokit-launcher", layer = "overlay",
        width = 0, height = 0, anchors = { "top", "bottom", "left", "right" },
        keyboard_interactivity = "exclusive", background = "#10141c99",
        on_close_request = launcher:sender("CLOSE"),
        content = content,
      } }
    end
  end

  return M
end
