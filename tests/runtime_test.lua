-- A downstream editor contract test: only require('ouro') and ouroctl test.
local o = require('ouro')
assert(o.runtime and o.runtime.api_level >= 1, 'Editor requires Ourokit runtime API 1')
local editor = o.editor_controller()

return {
  ['runtime API 1 supplies the retained editor contract'] = function(t)
    assert(type(o.runtime.version) == 'string' and #o.runtime.version > 0)
    assert(type(o.runtime.revision) == 'string' and #o.runtime.revision > 0)
    assert(io == nil and os == nil and package == nil and debug == nil)
    assert(load == nil and dofile == nil and not pcall(require, '../outside'))
    t:mount(function()
      return o.column {key='root',
        o.text_input {key='edit', controller=editor, default_text='aéZ\nlast',
          multiline=true, text_entry=false, caret_shape='block',
          key_bindings={['Home']='move_logical_line_start'}},
        o.button {key='replace', label='Replace selection', on_press=function()
          local s = assert(editor:state())
          assert(editor:read(s.token, 1, 3) == 'é')
          local _, err = editor:replace(s.token, 1, 2, 'bad')
          assert(err.name == 'InvalidGraphemeBoundary')
          s = assert(editor:select(s.token, {anchor=1, extent=1,
            character_caret={anchor=1, extent=1, column=1}}))
          assert(s.selection.anchor == 1 and s.selection.extent == 3)
          s = assert(editor:select(s.token, s.selection))
          assert(s.selection.character_caret.extent == 1)
          local old = s.token
          s = assert(editor:begin_undo_group(s.token))
          s = assert(editor:replace(s.token, 1, 3, 'Ω'))
          _, err = editor:replace(old, 1, 3, 'bad')
          assert(err.name == 'StaleEditorRevision')
          s = assert(editor:replace(s.token, 3, 3, '!'))
          assert(editor:end_undo_group(s.token))
        end},
      }
    end)
    t:click('root/edit')
    t:key('home')
    local ok, err = pcall(function() t:text('ignored') end)
    assert(not ok and err:find('DevelopmentTargetTextEntryDisabled', 1, true), tostring(err))
    assert(t:node('root/edit').value == 'aéZ\nlast', 'command mode inserted text')
    t:click('root/replace')
    assert(t:node('root/edit').value == 'aΩ!Z\nlast')
    t:click('root/edit')
    t:key('z', {control=true})
    assert(t:node('root/edit').value == 'aéZ\nlast', 'undo group was split')
  end,
}
