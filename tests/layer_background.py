#!/usr/bin/env python3
"""Native layer-background checks on a disposable 800x600 Sway output.

Run after zig build. Requires SWAYSOCK, OUROKIT_TEST_WAYLAND_DISPLAY (absolute
socket), swaymsg, grim, ImageMagick, wayland-info and systemd-socket-activate.
The compositor must NOT advertise ext-background-effect-v1: this tests fallback,
not actual blur. Changes output background/scale; never use a personal session.
Optional OUROKIT_LAYER_ARTIFACTS saves representative compositor captures.
"""
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from application_services import BINARY, call, record


def sway(*args):
    subprocess.run(["swaymsg", *args], check=True, stdout=subprocess.DEVNULL)


def source(background="'#111820B8'", effect="'blur'", width=400, height=200, broken=False):
    content = "error('rejected candidate')" if broken else "return ouro.text {key='label', text='Native layer background', foreground='#FFFFFF'}"
    return f"""local ouro = require('ouro')
local visible = ouro.signal(true)
return ouro.app {{ id='dev.ourokit.layer-background-test', actions={{
  Exit={{description='Exit test', inputSchema={{type='object'}}, outputSchema={{type='object'}},
    handler=function() ouro.exit(0) end}},
  SetOpen={{description='Set visibility',
    inputSchema={{type='object', properties={{open={{type='boolean'}}}}, required={{'open'}}}},
    outputSchema={{type='object', properties={{open={{type='boolean'}}}}, required={{'open'}}}},
    handler=function(input) visible:set(input.open) return {{open=visible()}} end}},
}},
  run=function() return {{ windows=function()
    if not visible() then return {{}} end
    return {{ ouro.layer_surface {{
    id='panel', namespace='ourokit-background-test', output='HEADLESS-1',
    layer='overlay', width={width}, height={height},
    background={background}, background_effect={effect},
    content=function() {content} end,
  }} }} end }} end,
}}
"""


def main():
    env = os.environ.copy()
    env["WAYLAND_DISPLAY"] = os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"]
    for key in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET"):
        env.pop(key, None)
    info = subprocess.check_output(["wayland-info"], env=env, stderr=subprocess.DEVNULL)
    assert b"ext_background_effect_manager_v1" not in info, "use a compositor without blur for this fallback test"
    artifacts = Path(os.environ["OUROKIT_LAYER_ARTIFACTS"]) if "OUROKIT_LAYER_ARTIFACTS" in os.environ else None
    if artifacts:
        artifacts.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ourokit-layer-background-") as temp:
        directory = Path(temp)
        env["XDG_RUNTIME_DIR"] = str(directory)
        wallpaper = directory / "wallpaper.png"
        subprocess.run(["magick", "-size", "800x600", "xc:#E08040", "-fill", "#2080E0",
                        "-draw", "rectangle 400,0 799,599", str(wallpaper)], check=True)
        sway("output", "HEADLESS-1", "scale", "1")
        sway("output", "HEADLESS-1", "bg", str(wallpaper), "stretch")
        app = directory / "app.lua"
        app.write_text(source())
        address = directory / "control.socket"
        log = directory / "app.log"
        with log.open("wb") as errors:
            process = subprocess.Popen(["systemd-socket-activate", f"--listen={address}", "--fdname=mcp",
                "--setenv=XDG_RUNTIME_DIR", "--setenv=WAYLAND_DISPLAY", str(BINARY), "run", str(app), "--software"],
                env=env, stdout=subprocess.DEVNULL, stderr=errors)
            try:
                for _ in range(100):
                    if address.exists():
                        break
                    time.sleep(.02)
                assert not call(address, "runtime.activate").get("isError"), log.read_text()

                def check(name, tint=(17, 24, 32, 184), width=400, height=200, scale=1):
                    capture = directory / "capture.png"
                    # Sample both warm and cool backdrops inside the layer,
                    # away from text. A doubly tinted/opaque root differs here.
                    points = [(round((800 - width * scale) / 2 + 40 * scale), 310),
                              (round((800 + width * scale) / 2 - 40 * scale), 310)]
                    backgrounds = [(224, 128, 64), (32, 128, 224)]
                    expected = [tuple(round(c * tint[3] / 255) + round(b * (255 - tint[3]) / 255)
                                      for c, b in zip(tint[:3], bg)) for bg in backgrounds]
                    # Just outside the declared width/height must be untouched.
                    points += [(round((800 - width * scale) / 2 - 3), 310),
                               (round((800 + width * scale) / 2 + 3), 310),
                               (points[0][0], round((600 - height * scale) / 2 - 3))]
                    expected += [backgrounds[0], backgrounds[1], backgrounds[0]]
                    for _ in range(60):
                        assert process.poll() is None, log.read_text()
                        subprocess.run(["grim", "-o", "HEADLESS-1", str(capture)], env=env, check=True)
                        data = subprocess.check_output(["magick", str(capture), "-depth", "8", "rgb:-"])
                        assert len(data) == 800 * 600 * 3, f"unexpected capture size: {len(data)}"
                        actual = [tuple(data[(y * 800 + x) * 3: (y * 800 + x) * 3 + 3]) for x, y in points]
                        if all(abs(a - e) <= 2 for pixel, target in zip(actual, expected) for a, e in zip(pixel, target)):
                            break
                        time.sleep(.05)
                    else:
                        raise AssertionError(f"{name}: expected {expected}, got {actual}; {log.read_text()}")
                    if artifacts and name in ("fallback-alpha", "resized-scaled", "reopened"):
                        (artifacts / f"{name}.png").write_bytes(capture.read_bytes())
                    print(f"PASS: {name}: {actual}")

                def reload(text, fails=False):
                    app.write_text(text)
                    result = call(address, "runtime.reload")
                    assert result.get("isError", False) == fails, result

                check("fallback-alpha")
                reload(source(effect="nil"))
                check("blur-omitted-identical")
                reload(source(background="'#A0206080'", width=300, height=120))
                check("updated-tint-size", (160, 32, 96, 128), 300, 120)
                reload(source(background="'#GG1820B8'"), fails=True)
                check("invalid-color-rollback", (160, 32, 96, 128), 300, 120)
                reload(source(effect="'frost'"), fails=True)
                check("invalid-effect-rollback", (160, 32, 96, 128), 300, 120)
                reload(source(broken=True), fails=True)
                check("failed-content-rollback", (160, 32, 96, 128), 300, 120)
                reload(source(background="nil", effect="nil"))
                check("omitted-theme-background", (255, 255, 255, 255))
                reload(source(width=300, height=120))
                sway("output", "HEADLESS-1", "scale", "1.5")
                check("resized-scaled", width=300, height=120, scale=1.5)
                for _ in range(3):
                    assert call(address, "SetOpen", {"open": False})["structuredContent"] == {"open": False}
                    check("closed", (0, 0, 0, 0), width=300, height=120, scale=1.5)
                    assert not call(address, "SetOpen", {"open": True}).get("isError")
                    check("reopened", width=300, height=120, scale=1.5)
                # Exercise output disable/enable without terminating the app.
                sway("output", "HEADLESS-1", "disable")
                time.sleep(.25)
                sway("output", "HEADLESS-1", "enable")
                check("output-reenabled", width=300, height=120, scale=1.5)
                assert call(address, "SetOpen", {"open": False})["structuredContent"] == {"open": False}
                check("closed-after-output-change", (0, 0, 0, 0), width=300, height=120, scale=1.5)
                assert call(address, "SetOpen", {"open": True})["structuredContent"] == {"open": True}
                check("reopened", width=300, height=120, scale=1.5)
                # Exit intentionally closes the RPC connection without a reply.
                with socket.socket(socket.AF_UNIX) as client:
                    client.connect(str(address))
                    client.sendall(record("tools/call", {"name": "Exit", "arguments": {}}))
                    process.wait(timeout=8)
            finally:
                if process.poll() is None:
                    process.terminate()
                process.wait(timeout=8)
                sway("output", "HEADLESS-1", "scale", "1")
                sway("output", "HEADLESS-1", "bg", "#E08040", "solid_color")
                if process.returncode != 0:
                    print(log.read_text())
        assert process.returncode == 0, log.read_text()


if __name__ == "__main__":
    main()
