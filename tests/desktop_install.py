#!/usr/bin/env python3
"""Tests for the dependency-free desktop integration generator."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools/desktop/install.py"


def run(metadata, *args, env=None):
    return subprocess.run([str(TOOL), str(metadata), *map(str, args)],
                          text=True, capture_output=True, env=env)


def main():
    with tempfile.TemporaryDirectory(prefix="ourokit-desktop-") as temporary:
        root = Path(temporary)
        assets = root / "metadata assets"
        assets.mkdir()
        (assets / "app.svg").write_text("<svg xmlns='http://www.w3.org/2000/svg'/>")
        (assets / "mime.png").write_bytes(b"not decoded by installer")
        (assets / "mime.xml").write_text(
            '<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">'
            '<mime-type type="application/x-asymmetric"><glob pattern="*.asym"/></mime-type>'
            '</mime-info>')
        metadata = assets / "desktop.json"
        data = {
            "id": "org.example.Asymmetric", "name": "Odd Notes", "comment": "Exact; entry",
            "ouroctl": '/opt/Ouro Kit/bin/ouroctl',
            "manifest": '/opt/Ouro Kit/apps/a "quote" $cash/100%/ouro.json',
            "dbus_activation": True, "mime_types": ["application/x-asymmetric"],
            "schemes": ["asym+note"], "categories": ["Office", "Utility"],
            "icon": {"source": "app.svg", "size": "scalable"},
            "custom_mime_xml": "mime.xml",
            "mime_icons": {"application/x-asymmetric": {"source": "mime.png", "size": "64x64"}},
        }
        metadata.write_text(json.dumps(data))
        output = root / "generated"
        result = run(metadata, "--output", output)
        assert result.returncode == 0, result.stderr
        desktop = (output / "share/applications/org.example.Asymmetric.desktop").read_text()
        assert desktop == r'''[Desktop Entry]
Type=Application
Name=Odd Notes
Comment=Exact; entry
Exec="/opt/Ouro Kit/bin/ouroctl" "run" "/opt/Ouro Kit/apps/a \\"quote\\" \\$cash/100%%/ouro.json" -- %U
DBusActivatable=true
Terminal=false
Icon=org.example.Asymmetric
MimeType=application/x-asymmetric;x-scheme-handler/asym+note;
Categories=Office;Utility;
''', repr(desktop)
        service = (output / "share/dbus-1/services/org.example.Asymmetric.service").read_text()
        assert service == "[D-BUS Service]\nName=org.example.Asymmetric\nExec='/opt/Ouro Kit/bin/ouroctl' run '/opt/Ouro Kit/apps/a \"quote\" $cash/100%/ouro.json' --dbus-activated\n"
        assert (output / "share/icons/hicolor/scalable/apps/org.example.Asymmetric.svg").exists()
        assert (output / "share/icons/hicolor/64x64/mimetypes/application-x-asymmetric.png").exists()
        assert (output / "share/mime/packages/org.example.Asymmetric.xml").exists()

        validator = shutil.which("desktop-file-validate")
        if validator:
            checked = subprocess.run([validator, str(output / "share/applications/org.example.Asymmetric.desktop")],
                                     text=True, capture_output=True)
            assert checked.returncode == 0, checked.stderr or checked.stdout

        plain = dict(data)
        plain.pop("dbus_activation")
        plain.pop("custom_mime_xml")
        metadata.write_text(json.dumps(plain))
        user_data = root / "user data"
        env = os.environ.copy()
        env["XDG_DATA_HOME"] = str(user_data)
        installed = run(metadata, "--user", env=env)
        assert installed.returncode == 0, installed.stderr
        user_desktop = (user_data / "applications/org.example.Asymmetric.desktop").read_text()
        assert "DBusActivatable" not in user_desktop
        assert not (user_data / "dbus-1/services/org.example.Asymmetric.service").exists()

        stage = root / "stage"
        packaged = run(metadata, "--prefix", "/usr", "--destdir", stage)
        assert packaged.returncode == 0, packaged.stderr
        assert (stage / "usr/share/applications/org.example.Asymmetric.desktop").exists()
        assert not (root / "usr").exists()
        escaped = run(metadata, "--prefix", "/usr/../../escaped", "--destdir", stage)
        assert escaped.returncode != 0 and not (root / 'escaped').exists()

        # Exercise an independent desktop-entry parser and launcher, rather than
        # verifying our encoder against a copy of its own rules. The executable
        # records argv only; no app, desktop service, or real installation runs.
        if shutil.which('gio'):
            executable = root / 'capture "quote" $cash \\ slash'
            captured = root / 'argv.json'
            executable.write_text('#!/usr/bin/env python3\nimport json,sys\n'
                                  + 'open('+repr(str(captured))+',"w").write(json.dumps(sys.argv[1:]))\n'
                                  + 'if "--dbus-activated" in sys.argv: sys.exit(1)\n')
            executable.chmod(0o755)
            launch = dict(plain, ouroctl=str(executable))
            metadata.write_text(json.dumps(launch))
            assert run(metadata, '--output', root / 'launch').returncode == 0
            entry = root / 'launch/share/applications/org.example.Asymmetric.desktop'
            uris = ['asym+note://first/a%20b', 'asym+note://second/c']
            launched = subprocess.run(['gio','launch',str(entry),*uris], text=True, capture_output=True,
                                      env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS='unix:path='+str(root/'no-bus')))
            assert launched.returncode == 0, launched.stderr
            deadline = time.monotonic()+5
            while not captured.exists() and time.monotonic()<deadline: time.sleep(.01)
            assert json.loads(captured.read_text()) == ['run',data['manifest'],'--',*uris]
            if shutil.which('dbus-run-session') and shutil.which('gdbus'):
                captured.unlink()
                launch['dbus_activation'] = True
                metadata.write_text(json.dumps(launch))
                assert run(metadata, '--output', root/'activation').returncode == 0
                activated = subprocess.run(['dbus-run-session','--','gdbus','call','--session',
                    '--dest','org.freedesktop.DBus','--object-path','/org/freedesktop/DBus',
                    '--timeout','5','--method','org.freedesktop.DBus.StartServiceByName',data['id'],'0'],
                    env=dict(os.environ, XDG_DATA_HOME=str(root/'activation/share'), XDG_DATA_DIRS=str(root/'empty')),
                    capture_output=True, text=True, timeout=10)
                # The argv recorder deliberately exits without owning the name.
                assert activated.returncode != 0 and captured.exists(), activated.stderr
                assert json.loads(captured.read_text()) == ['run',data['manifest'],'--dbus-activated']

        for mutation in (
            {"id": "bad/id"},
            {"ouroctl": "relative; touch PWNED"},
            {"ouroctl": "/opt/bin/unsupported%name"},
            {"mime_types": ["bad mime"]},
            {"dbus_activation": "yes"},
            {"unknown": True},
        ):
            invalid = dict(data)
            invalid.update(mutation)
            metadata.write_text(json.dumps(invalid))
            destination = root / ("invalid-" + str(len(list(root.glob("invalid-*")))))
            failed = run(metadata, "--output", destination)
            assert failed.returncode != 0 and not destination.exists(), (mutation, failed)
        print("PASS: exact escaping, optional activation, conventional assets, staging, and validation")


if __name__ == "__main__":
    main()
