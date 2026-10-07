-- The stopwatch's UI as a function of the chart snapshot. It reads the actor
-- and sends it events; it holds no state of its own.
local ouro = require('ouro')

local M = {}

-- m:ss, with tenths when asked: format(61234, true) == '1:01.2'.
function M.format(ms, tenths)
  local s = ms // 1000
  local text = string.format('%d:%02d', s // 60, s % 60)
  if tenths then text = text .. string.format('.%d', (ms % 1000) // 100) end
  return text
end

local function laps(c)
  local rows = {}
  for i, lap in ipairs(c.laps) do
    rows[i] = ouro.text { key = 'lap-' .. i,
      text = string.format('Lap %d  %s  (+%s)', i, M.format(lap.total, c.show_tenths), M.format(lap.split, c.show_tenths)) }
  end
  return ouro.column { key = 'laps', gap = 4, children = rows }
end

local function settings(sw, c)
  return ouro.dialog { key = 'settings', label = 'Settings', on_cancel = sw:event('CANCEL'),
    ouro.column { key = 'body', gap = 12,
      ouro.text { key = 'title', text = 'Settings', size = 20 },
      ouro.row { key = 'laps', gap = 8, cross_alignment = 'center',
        ouro.spinbox { key = 'spinbox', label = 'Laps kept', value = c.draft_max_laps,
          min = 1, max = 20, step = 1, send = sw:event('MAX_LAPS') },
        ouro.text { key = 'label', text = 'Laps kept' },
      },
      ouro.row { key = 'tenths', gap = 8, cross_alignment = 'center',
        ouro.switch { key = 'switch', label = 'Show tenths', checked = c.draft_show_tenths, send = sw:event('TENTHS') },
        ouro.text { key = 'label', text = 'Show tenths' },
      },
      ouro.row { key = 'actions', gap = 8,
        ouro.button { key = 'cancel', label = 'Cancel', send = sw:event('CANCEL') },
        ouro.button { key = 'save', label = 'Save', send = sw:event('SAVE_SETTINGS') },
      },
    },
  }
end

-- Buttons take event bindings, so each is enabled exactly while the chart
-- would take its event: Lap only while running, Reset only once paused.
function M.content(sw)
  return function()
    local c = sw:context()
    local running = sw:matches('clock.running')
    return ouro.stack { key = 'root',
      ouro.column { key = 'page', gap = 12,
        ouro.text { key = 'time', text = M.format(c.elapsed, c.show_tenths), size = 40 },
        ouro.row { key = 'controls', gap = 8,
          ouro.button { key = 'toggle', label = running and 'Stop' or 'Start', send = sw:event(running and 'STOP' or 'START') },
          ouro.button { key = 'lap', label = 'Lap', send = sw:event('LAP') },
          ouro.button { key = 'reset', label = 'Reset', send = sw:event('RESET') },
          ouro.button { key = 'settings', label = 'Settings', send = sw:event('OPEN_SETTINGS') },
        },
        laps(c),
      },
      sw:matches('settings.open') and settings(sw, c) or nil,
    }
  end
end

return M
