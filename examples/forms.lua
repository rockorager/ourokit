local o = require('ouro')
local content = require('forms_content')()
return o.app {id='dev.ourokit.forms', run=function() return {windows={
  o.window {id='main', title='Ourokit · Form controls', width=540, height=640, content=content},
}} end}
