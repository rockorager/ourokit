#!/usr/bin/env python3
"""Statechart state survives `ouroctl dev reload`.

Runs private copies of examples on the private compositor that
verify_development.py provides:

- documents: make a document dirty, rename the state it is in, and reload.
  The document must still be dirty: the actor was restored, not restarted.
  A broken candidate must leave the live actor alone.
- launcher: type a query and reload. The query, which is chart state, and the
  results it filters must survive; a restarted launcher would reopen empty.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from application_services import development_path
from desktop_native import BINARY, ROOT, inspect, node, run, terminate, wait_for

WINDOW = "main"


def panel(value, leaf):
    return f"documents/tabs/control/panels/{value}/drop/layers/body/{leaf}"


def tab_labels(env, endpoint):
    nodes = inspect(env, endpoint, WINDOW)["windows"][0]["nodes"]
    return [n.get("label", "") for n in nodes if n.get("role") == "tab"]


def reload(env, endpoint):
    result = subprocess.run([str(BINARY), "dev", "reload", str(endpoint)], env=dict(
        env, XDG_RUNTIME_DIR=str(Path(endpoint).parents[2])), capture_output=True, text=True, timeout=20)
    return result.returncode == 0, result.stdout + result.stderr


def documents():
    with tempfile.TemporaryDirectory(prefix="ouro-chart-reload-") as temporary:
        root = Path(temporary)
        app_root = root / "documents"
        shutil.copytree(ROOT / "examples/documents", app_root)
        charts = app_root / "charts.lua"
        env = dict(os.environ, WAYLAND_DISPLAY=os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"],
                   XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"))
        errors = root / "documents.stderr"
        with errors.open("w+") as error_file:
            app = subprocess.Popen([str(BINARY), "run", str(app_root / "app.lua"), "--dev", "--software"],
                                   env=env, stdout=subprocess.DEVNULL, stderr=error_file)
            try:
                endpoint = development_path(Path(env["XDG_RUNTIME_DIR"]), app)
                wait_for(lambda: inspect(env, endpoint).get("windows"), "document window did not appear")

                def type_text(text):
                    tree = inspect(env, endpoint, WINDOW)["windows"][0]
                    run(str(BINARY), "dev", "input", str(endpoint), json.dumps({
                        "window": WINDOW, "token": tree["token"], "action": "click", "target": panel(1, "text")}), env=env)
                    tree = inspect(env, endpoint, WINDOW)["windows"][0]
                    run(str(BINARY), "dev", "input", str(endpoint), json.dumps({
                        "window": WINDOW, "token": tree["token"], "action": "text", "text": text}), env=env, timeout=60)

                assert tab_labels(env, endpoint) == ["Untitled"], tab_labels(env, endpoint)
                type_text("unsaved work")
                wait_for(lambda: tab_labels(env, endpoint) == ["* Untitled"], "editing did not mark the document dirty")

                # Rename the lifecycle state the document is in. Restore falls
                # back to its parent and enters the new initial state; context,
                # including the unsaved revision, is kept.
                source = charts.read_text()
                edited = source.replace('initial = "active", states = {\n            active = {',
                                        'initial = "editing", states = {\n            editing = {', 1)
                edited = edited.replace('CANCEL = { target = "active"', 'CANCEL = { target = "editing"', 1)
                assert edited != source and 'target = "active"' not in edited
                charts.write_text(edited)
                ok, output = reload(env, endpoint)
                assert ok and "as generation 2" in output, output
                labels = tab_labels(env, endpoint)
                assert labels == ["* Untitled"], f"document lost its unsaved state across reload: {labels}"
                assert node(env, endpoint, WINDOW, panel(1, "text"))["value"] == "unsaved work"

                # The restored actor keeps working in the new generation.
                type_text(" and more")
                wait_for(lambda: node(env, endpoint, WINDOW, panel(1, "text"))["value"] == "unsaved work and more",
                         "restored document did not accept edits")
                assert tab_labels(env, endpoint) == ["* Untitled"]

                # A failing candidate leaves the live actor and its state alone.
                charts.write_text(edited + "\nthis is not lua\n")
                ok, output = reload(env, endpoint)
                assert not ok, output
                assert tab_labels(env, endpoint) == ["* Untitled"]
                type_text("!")
                wait_for(lambda: node(env, endpoint, WINDOW, panel(1, "text"))["value"] == "unsaved work and more!",
                         "live document stopped accepting edits after a failed reload")

                # A later good reload still restores the latest live state.
                charts.write_text(edited)
                ok, output = reload(env, endpoint)
                assert ok and "as generation 3" in output, output
                assert tab_labels(env, endpoint) == ["* Untitled"]
                assert node(env, endpoint, WINDOW, panel(1, "text"))["value"] == "unsaved work and more!"
                print("PASS chart reload: dirty document survives a chart edit; failed candidate leaves live state")
            except BaseException:
                error_file.flush()
                print(errors.read_text())
                raise
            finally:
                terminate(app)


def launcher():
    with tempfile.TemporaryDirectory(prefix="ouro-launcher-reload-") as temporary:
        root = Path(temporary)
        app_root = root / "launcher"
        shutil.copytree(ROOT / "examples/launcher", app_root)
        data = root / "data"
        (data / "applications").mkdir(parents=True)
        for name, label in (("alpha", "Alpha Editor"), ("beta", "Beta Terminal"), ("gamma", "Gamma Viewer")):
            (data / "applications" / f"{name}.desktop").write_text(
                f"[Desktop Entry]\nType=Application\nName={label}\nExec={name}\n")
        env = dict(os.environ, WAYLAND_DISPLAY=os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"],
                   XDG_DATA_HOME=str(data), XDG_DATA_DIRS=str(root / "share"))
        errors = root / "launcher.stderr"
        status, search = "scrim/panel/body/status", "scrim/panel/body/search"
        with errors.open("w+") as error_file:
            app = subprocess.Popen([str(BINARY), "run", str(app_root / "ouro.json"), "--dev", "--software"],
                                   env=env, stdout=subprocess.DEVNULL, stderr=error_file)
            try:
                endpoint = development_path(Path(env["XDG_RUNTIME_DIR"]), app)

                def label(path):
                    windows = inspect(env, endpoint).get("windows", [])
                    if not any(w["window"] == "launcher" for w in windows):
                        return None
                    found = [n for n in inspect(env, endpoint, "launcher")["windows"][0]["nodes"] if n["path"] == path]
                    return found[0].get("label") if found else None

                wait_for(lambda: label(status) == "3 applications", "launcher did not open with three applications")
                for _ in range(5):  # icons load asynchronously and refresh the token
                    tree = inspect(env, endpoint, "launcher")["windows"][0]
                    result = run(str(BINARY), "dev", "input", str(endpoint), json.dumps({
                        "window": "launcher", "token": tree["token"], "action": "text", "text": "ga"}), env=env, ok=None)
                    if result.returncode == 0:
                        break
                wait_for(lambda: label(status) == "1 application", "the query did not filter")

                # An edit to the view; the chart and its state are carried.
                view = app_root / "view.lua"
                view.write_text(view.read_text() + "\n-- edited during the reload test\n")
                ok, output = reload(env, endpoint)
                assert ok and "as generation 2" in output, output
                wait_for(lambda: label(status) is not None, "launcher surface did not come back")
                assert label(status) == "1 application", f"launcher query did not survive reload: {label(status)}"
                assert node(env, endpoint, "launcher", search)["value"] == "ga"
                print("PASS chart reload: the launcher query and its results survive a reload")

                # The carried entry came from ouro.xdg.applications: its empty
                # lists are marked JSON arrays, which prepare_launch needs to
                # decode it. Launching then reaches systemd over D-Bus, which
                # this private session bus does not have.
                for _ in range(5):
                    tree = inspect(env, endpoint, "launcher")["windows"][0]
                    row = next(n["path"] for n in tree["nodes"] if n.get("role") == "button" and n.get("label") == "Gamma Viewer")
                    result = run(str(BINARY), "dev", "input", str(endpoint), json.dumps({
                        "window": "launcher", "token": tree["token"], "action": "click", "target": row}), env=env, ok=None)
                    if result.returncode == 0:
                        break
                wait_for(lambda: (label(status) or "").startswith("Could not launch"), "activating did not try to launch")
                assert "systemd1" in label(status), f"the carried entry did not reach D-Bus: {label(status)}"
                print("PASS chart reload: a carried desktop entry still prepares a launch")
            except BaseException:
                error_file.flush()
                print(errors.read_text())
                raise
            finally:
                terminate(app)


if __name__ == "__main__":
    documents()
    launcher()
