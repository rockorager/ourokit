-- When a state counts as stuck (an amber alarm in the overview).
--
-- By default only busy leaf states are watched: states with an invoke or an
-- `after` timer, where waiting is the exception. A watched state alarms when
-- its current dwell exceeds `factor` x the median of its earlier dwells
-- (after `samples` completed dwells), and at least `min_ms`. Per chart,
-- override the defaults or list states: {max_ms = n} sets a fixed limit
-- (no samples needed), false stops watching, {} watches with the defaults.
return {
  default = {factor = 10, min_ms = 1000, samples = 3},
  charts = {
    -- document = {factor = 5, states = {['open.io.saving.writing'] = {max_ms = 5000}}},
  },
}
