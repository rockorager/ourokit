"""Headless CLI regression checks: module parity, diagnostics, and PNG output."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


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
