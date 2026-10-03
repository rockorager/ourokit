"""Headless CLI regression checks: module parity, diagnostics, and PNG output."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from development_runtime import png_pixel


binary = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ["OUROKIT_TEST_BINARY"]).resolve()
with tempfile.TemporaryDirectory(prefix="ouro-storybook-") as directory:
    root = Path(directory)
    (root / "model").mkdir()
    (root / "model" / "init.lua").write_text("return {text='Module-backed story'}")
    (root / "view.lua").write_text("""
local o = require('ouro')
local model = require('model')
assert(require('model') == model)
return function()
  assert(require('model') == model) -- cached imports must survive bootstrap
  return o.column {key='root',
    o.text {key='title', text=model.text},
    o.text {key='status', text=''},
  }
end
""")
    catalog = """
local o = require('ouro')
local view = require('view')
assert(io == nil and package == nil and os == nil)
return o.storybook {stories={o.story {
  id='modules', name='Modules', viewport={width=960,height=760},
  snapshot_scale=2, content=view,
}}}
"""
    entry = root / "stories.lua"
    entry.write_text(catalog)
    environment = os.environ.copy()
    if environment.get("OUROKIT_TEST_WAYLAND_DISPLAY"):
        environment["WAYLAND_DISPLAY"] = environment["OUROKIT_TEST_WAYLAND_DISPLAY"]

    def run(command, *arguments, failure=None):
        result = subprocess.run(
            [str(binary), "storybook", command, str(entry), *arguments],
            cwd="/", env=environment, capture_output=True, text=True, timeout=30,
        )
        if failure is None:
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode != 0, result.stdout
            assert "panic" not in result.stderr, result.stderr
            for detail in failure:
                assert detail in result.stderr, result.stderr
        return result

    assert json.loads(run("list", "--json").stdout)["stories"][0]["id"] == "modules"
    run("snapshot", "--output", str(root / "out"), "--json")
    png = (root / "out" / "modules.png").read_bytes()
    assert png[:8] == b"\x89PNG\r\n\x1a\n"
    assert int.from_bytes(png[16:20], "big") == 1920
    assert int.from_bytes(png[20:24], "big") == 1520
    assert len(png) < 1_000_000, len(png)
    print(f"module-backed 1920x1520 PNG: {len(png):,} bytes")
    for name, padding, scheme, ink in (
        ('default-inset', None, 'light', b'\xb4\x28\x53\xff'),
        ('zero-inset', 0, 'dark', b'\x19\x3b\xc7\xff'),
        ('fractional-inset', 3.5, 'light', b'\xb4\x28\x53\xff'),
    ):
        field = '' if padding is None else f'padding={padding},'
        entry.write_text("""local o=require('ouro')
local Content=o.stateless(function(p, children, theme)
  assert(theme.color_scheme == '%s')
  return o.box {key='root',width='fill',height='fill',alignment='center',
    background=theme.color_scheme == 'dark' and '#193bc7' or '#b42853',
    o.text {key='label',text='%s',foreground='#ffffff'}}
end)
return o.storybook {stories={o.story {id='padding',name='Padding',
  viewport={width=260,height=130},snapshot_scale=2,color_scheme='%s',%s
  content=function() return Content {} end}}}
""" % (scheme, name, scheme, field))
        run('snapshot', '--output', str(root / 'padding'), '--json')
        output = root / 'padding' / 'padding.png'
        inset = int(2 * (12 if padding is None else padding))
        for x, y in ((0, 0), (519, 0), (0, 259), (519, 259)):
            assert png_pixel(output, x, y) == (520, 260, ink if inset == 0 else b'\xff\xff\xff\xff')
        assert png_pixel(output, inset, inset)[2] == ink
        if inset:
            assert png_pixel(output, inset-1, inset-1)[2] == b'\xff\xff\xff\xff'
        if os.environ.get('OUROKIT_WINDOW_THEME_CAPTURE'):
            target = Path(os.environ['OUROKIT_WINDOW_THEME_CAPTURE'])
            target.mkdir(parents=True, exist_ok=True)
            (target / ('storybook-' + name + '.png')).write_bytes(output.read_bytes())
    print('Storybook resolved schemes and omitted/zero/fractional padding pixels: PASS')
    entry.write_text(catalog)
    if environment.get("OUROKIT_TEST_WAYLAND_DISPLAY"):
        run("run", "--software", "--exit-after-first-frame")
        print("module-backed native Storybook browser: PASS")
    entry.write_text("require('ouro').spawn(function() done=true end); " + catalog)
    run("list", "--json")
    (root / "waiting.lua").write_text("require('ouro').exit()")

    for source, detail in [
        ("require('missing')", ("missing", "FileNotFound", "missing.lua", "missing/init.lua")),
        ("local function broken() error('catalog failure') end; broken()", ("catalog failure", "stories.lua:1", "stack traceback:")),
        ("this is not Lua", ("stories.lua:1",)),
        ("require('ouro').sleep(1)", ("sleep",)),
        ("require('ouro').exit()", ("StorybookEvaluationCanceled",)),
        ("require('waiting')", ("StorybookEvaluationCanceled",)),
        ("require('ouro').spawn(function() error('child failure') end); require('model')", ("child failure", "LuaRuntimeError")),
        ("return", ("LuaBootstrapResultRequired",)),
        ("return {}, {}", ("LuaBootstrapResultRequired",)),
    ]:
        entry.write_text(source)
        run("list", failure=detail)

    entry.write_text(catalog)
    for body, details in [
        ("return o.text {key='hint', text='Hint', alignment='right'}", ("widget 'hint'", "alignment", "start, center, end")),
        ("local function broken() error('content failure') end; broken()", ("content failure", "view.lua", "stack traceback:")),
        ("return o.box {key='empty-button', role='button', label=''}", ("empty-button", "SemanticLabelRequired")),
    ]:
        (root / "view.lua").write_text("local o=require('ouro'); return function() " + body + " end")
        run("snapshot", "--output", str(root / "out"), failure=details)

print("Storybook modules, cached render imports, diagnostics, empty text, and compressed snapshots: PASS")
