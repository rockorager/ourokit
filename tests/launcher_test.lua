-- examples/launcher's real view over its chart, with fake discovery and
-- launching: typing and Enter launch the current top match, and a click
-- launches the row it hit, by id.
local o = require('ouro')
local machine = o.machine
local model = require('examples.launcher.model')
local make_charts = require('examples.launcher.charts')
local make_view = require('examples.launcher.view')
local null = o.json.null

local function entry(id, name)
  return { id = id .. '.desktop', path = '/apps/' .. id .. '.desktop', name = name, generic_name = null,
    comment = null, icon = null, exec = id, working_directory = null, keywords = {}, actions = {},
    hidden = false, no_display = false, terminal = false, dbus_activatable = false, visible = true }
end
local apps = { entry('firefox', 'Firefox'), entry('files', 'Files'), entry('terminal', 'Terminal') }

local function open(t, content)
  local launched = {}
  local charts = make_charts(o, model, {
    scan = function() return apps end,
    launch = function(e) launched[#launched + 1] = e.id; return true end,
  })
  local clock = machine.manual_scheduler()
  local launcher = charts.launcher:start { scheduler = clock }
  launcher:send('OPEN')
  clock.run_tasks()
  local view = make_view(o, model, charts.results)
  t:mount(function() return (content or view.content)(launcher, view) end, { width = 700, height = 520 })
  return launcher, launched
end

return {
  ['typing then Enter launches the current top match'] = function(t)
    local launcher = open(t)
    t:click('scrim/panel/body/search')
    t:text('te')
    t:key('enter')
    assert(launcher:matches('open.launching') and launcher:context().launching.id == 'terminal.desktop',
      launcher:context().launching and launcher:context().launching.id)
  end,

  ['Enter does nothing while nothing matches'] = function(t)
    local launcher = open(t)
    t:click('scrim/panel/body/search')
    t:text('zzz')
    t:key('enter')
    assert(launcher:matches('open.ready') and launcher:context().launching == nil)
  end,

  ['a click launches the row it hit, by id'] = function(t)
    local launcher = open(t)
    t:click('scrim/panel/body/results/firefox.desktop/row')
    assert(launcher:context().launching.id == 'firefox.desktop' and launcher:context().selected == 2, 'rows sort by name: Files, Firefox, Terminal')
  end,

  -- One keystroke edits the query and submits, so the submit runs before the
  -- rebuild the edit causes: the view's Enter binding (view.submit) must
  -- resolve its payload at dispatch. "fir" matches only Firefox; "fi" puts
  -- Files first.
  ['an edit and Enter in one turn launch the new top match'] = function(t)
    local launcher = open(t, function(l, view)
      return o.text_input { key = 'search', label = 'Search', text = l:context().query,
        send = l:event('QUERY'), key_bindings = { Enter = { 'delete_backward', 'submit' } },
        on_command = { submit = view.submit(l) } }
    end)
    t:click('search')
    t:text('fir')
    t:key('enter')
    assert(launcher:context().query == 'fi')
    assert(launcher:context().launching.id == 'files.desktop', 'stale payload: ' .. launcher:context().launching.id)
  end,
}
