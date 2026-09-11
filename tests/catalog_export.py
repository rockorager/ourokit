#!/usr/bin/env python3
"""Production catalog-export checks. Run after zig build; no desktop required."""
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "zig-out/bin/ouroctl"
APP_ID = "dev.ourokit.catalogtest"


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    with tempfile.TemporaryDirectory(prefix="ourokit-catalog-") as temp:
        root = Path(temp)
        env = os.environ.copy()
        for key in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET", "WAYLAND_DISPLAY"):
            env.pop(key, None)
        env["XDG_RUNTIME_DIR"] = temp
        app = root / "app.lua"
        manifest = root / "ouro.json"
        manifest.write_text(json.dumps({"schema_version": 1, "id": APP_ID, "entry": "app.lua"}))
        module = root / "declaration.lua"
        module.write_text('''local o = require('ouro')
o.stdout.write('declaration log\\n')
assert(o.stdin.read(1) == nil)
return {
  Echo = {description='Echo an exact message',
    inputSchema={type='object', properties={message={type='string'}}, required={'message'}, additionalProperties=false},
    outputSchema={type='object', properties={reply={type='string'}}, required={'reply'}, additionalProperties=false},
    handler=function() error('export executed action') end},
}
''')
        original = f'''local o = require('ouro')
return o.app {{id='{APP_ID}', actions=require('declaration'),
  run=function() error('export initialized UI') end}}
'''
        app.write_text(original)
        listeners = []
        try:
            for name in (f"ourokit/apps/{APP_ID}", "ouro/settings.mcp.sock"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                listener = socket.socket(socket.AF_UNIX)
                listener.bind(str(path))
                listener.listen()
                listeners.append(listener)

            def export(path=manifest, *options):
                return subprocess.run([str(BINARY), "mcp", "export", str(path), *options],
                                      env=env, capture_output=True, timeout=10)

            first = export()
            assert first.returncode == 0, first.stderr
            assert first.stderr == b"declaration log\n", first.stderr
            catalog = json.loads(first.stdout)
            assert set(catalog) == {"schema_version", "application_id", "endpoint", "tools"}, catalog
            assert catalog["schema_version"] == 1 and catalog["application_id"] == APP_ID
            assert catalog["endpoint"] == {"runtime_path": f"ourokit/apps/{APP_ID}"}
            tools = {tool["name"]: tool for tool in catalog["tools"]}
            assert set(tools) == {"Echo", "runtime.activate", "runtime.reload", "runtime.status"}
            assert tools["Echo"]["description"] == "Echo an exact message"
            assert tools["Echo"]["inputSchema"] == {
                "type": "object", "properties": {"message": {"type": "string"}},
                "required": ["message"], "additionalProperties": False,
            }
            assert {"type": "object", "properties": {"reply": {"type": "string"}},
                    "required": ["reply"], "additionalProperties": False} in tools["Echo"]["outputSchema"]["anyOf"]
            assert export(app).stdout == first.stdout
            assert not select.select(listeners, [], [], 0)[0], "export activated a socket"
            assert not (root / "ouro/mcp").exists(), "export published a runtime catalog"
            print("PASS: module-based export uses live schemas, no UI/action/activation, stdout is JSON")

            destination = root / "installed" / f"{APP_ID}.json"
            written = export(manifest, "--output", str(destination))
            assert written.returncode == 0 and written.stdout == b"", written
            assert destination.read_bytes() == first.stdout
            assert not list(destination.parent.glob("*.tmp-*"))
            for source in ("invalid lua ???", original.replace("id='" + APP_ID, "id='dev.wrong.app"),
                           f"return require('ouro').app{{id='{APP_ID}'}}", "require('ouro').exit(0)"):
                app.write_text(source)
                failed = export(manifest, "--output", str(destination))
                assert failed.returncode != 0 and failed.stdout == b"", failed
                assert destination.read_bytes() == first.stdout, "failed export replaced installed metadata"
                assert b"panic" not in failed.stderr, failed.stderr
            print("PASS: atomic file output preserves previous catalog on malformed/disabled/mismatched/exit declarations")

            app.write_text(original)
            contacts = export(ROOT / "examples/contacts/ouro.json")
            assert contacts.returncode == 0 and contacts.stderr == b"", contacts
            contact_catalog = json.loads(contacts.stdout)
            assert {t["name"] for t in contact_catalog["tools"]} == {
                "GetContacts", "SelectContact", "RenameContact", "runtime.status", "runtime.reload", "runtime.activate",
            }
            assert contact_catalog["application_id"] == "dev.ourokit.contacts"
            assert not select.select(listeners, [], [], 0)[0]
            print("PASS: Contacts catalog exports from production action declarations without a desktop")
        finally:
            for listener in listeners:
                listener.close()


if __name__ == "__main__":
    main()
