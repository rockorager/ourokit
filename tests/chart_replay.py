#!/usr/bin/env python3
"""Statechart recording and replay with the real example apps.

Runs on the private compositor that verify_development.py provides. Each
example runs as a development instance and is driven through the
development endpoint, so inputs take the real widget, surface and invoke
paths. The recorded log must then replay headless to identical records and
snapshots (`ouroctl replay`). A deliberately changed chart must produce a
divergence report that names the first differing step. Generated tests and
the visualizer's record expansion run on the same recordings.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

from application_services import call, development_path
from desktop_native import BINARY, inspect, run, terminate, wait_for

ROOT = Path(__file__).resolve().parents[1]
EXAMPLES = ROOT / "examples"


class Instance:
    def __init__(self, env, root, name, record=True):
        self.env, self.root, self.name = env, root, name
        self.log = root / f"{name}.jsonl"
        args = [str(BINARY), "run", str(EXAMPLES / name / "ouro.json"), "--dev", "--software"]
        if record:
            args += ["--record", str(self.log)]
        self.stderr = (root / f"{name}.stderr").open("w+")
        sockets = Path(env["XDG_RUNTIME_DIR"]) / "ourokit/dev"
        before = set(sockets.glob("*")) if sockets.is_dir() else set()
        self.process = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=self.stderr)
        self.endpoint = development_path(Path(env["XDG_RUNTIME_DIR"]), self.process, exclude=before)
        wait_for(lambda: inspect(env, self.endpoint).get("windows"), f"{name}: no window appeared")

    def tree(self, window):
        return inspect(self.env, self.endpoint, window)["windows"][0]

    def act(self, window, body, retries=3):
        # Ticking UIs rebuild often: pin the input to the inspected node and
        # retry a stale token.
        for attempt in range(retries):
            try:
                tree = self.tree(window)
            except AssertionError:
                if attempt == 0:
                    raise
                return  # The stale-looking input closed its window after all.
            node = next((n for n in tree["nodes"] if n.get("path") == body.get("target")), None)
            request = dict(body, window=window, token=tree["token"])
            if node:
                request["node"] = node["id"]
            result = run(str(BINARY), "dev", "input", str(self.endpoint), json.dumps(request), env=self.env, ok=None)
            if result.returncode == 0:
                return
            assert "Stale" in result.stdout, (request, result.stdout, result.stderr)
        raise AssertionError(f"{self.name}: input stayed stale: {body}")

    def click(self, window, target):
        self.act(window, {"action": "click", "target": target})

    def type(self, window, target, text):
        self.click(window, target)
        self.act(window, {"action": "text", "text": text})

    def key(self, window, key):
        self.act(window, {"action": "key", "key": key})

    def label(self, window, path):
        return next((n.get("label") for n in self.tree(window)["nodes"] if n.get("path") == path), None)

    def stop(self):
        terminate(self.process)
        self.stderr.seek(0)
        text = self.stderr.read()
        self.stderr.close()
        assert "panic" not in text, text
        return text


def replay(log, app, ok=True, *extra):
    result = subprocess.run([str(BINARY), "replay", str(log), str(app), *extra], capture_output=True, text=True,
                            timeout=60)
    assert (result.returncode == 0) == ok, (log, app, result.returncode, result.stdout, result.stderr)
    return result.stdout


def entries(log):
    lines = Path(log).read_text().splitlines()
    header = json.loads(lines[0])
    assert header["format"] == "ouro.machine.log" and header["version"] == 1, header
    return [json.loads(line) for line in lines[1:]]


def stopwatch(env, root):
    app = Instance(env, root, "stopwatch")
    controls = "root/page/controls/"
    app.click("main", controls + "toggle")
    time.sleep(0.45)
    app.click("main", controls + "lap")
    time.sleep(0.25)
    app.click("main", controls + "toggle")
    app.click("main", controls + "settings")
    app.click("main", "root/settings/body/laps/spinbox/control/decrease")
    app.click("main", "root/settings/body/tenths/switch")
    app.click("main", "root/settings/body/actions/save")
    app.click("main", controls + "toggle")
    time.sleep(0.3)
    app.click("main", controls + "toggle")
    app.click("main", controls + "reset")
    assert app.label("main", "root/page/time") == "0:00"
    app.stop()
    log = entries(app.log)
    kinds = [e["k"] for e in log]
    assert kinds[0] == "start" and kinds.count("timer") >= 6, kinds
    assert {e["o"] for e in log if e["k"] == "event"} == {"widget"}, log
    # Ticks land on deadlines: each timer fires exactly 100 ms after the
    # previous tick or the START that armed it.
    timers = [e for e in log if e["k"] == "timer"]
    starts = [e["t"] for e in log if e["k"] == "event" and e["e"]["type"] == "START"]
    assert all((t["t"] - starts[0]) % 100 == 0 for t in timers if t["t"] < starts[1]), (starts, timers)
    assert all(t["e"]["time_ms"] == t["t"] + json.loads(app.log.read_text().splitlines()[0])["t0"] for t in timers)

    out = replay(app.log, EXAMPLES / "stopwatch")
    assert out.startswith(f"replay matched: {len(log)} entries"), out

    # The visualizer's input: the replay's inspection records, graph included.
    records = root / "stopwatch.records.jsonl"
    replay(app.log, EXAMPLES / "stopwatch", True, "--records", str(records))
    first = json.loads(records.read_text().splitlines()[0])
    assert first["kind"] == "actor" and first["graph"]["format"] == "ouro.machine.graph", first

    # A deliberately changed chart: ticks every 50 ms. The first tick is the
    # first divergent step, reported with its time and the differing fields.
    changed = root / "stopwatch-changed"
    shutil.copytree(EXAMPLES / "stopwatch", changed)
    charts = changed / "charts.lua"
    charts.write_text(charts.read_text().replace("local TICK = 100", "local TICK = 50"))
    report = replay(app.log, changed, False)
    first_timer = kinds.index("timer") + 1
    assert report.startswith(f"DIVERGED at step {first_timer} "), report
    assert "after.50.clock.running" in report and "after.100.clock.running" in report, report
    print(report)

    # Generated tests: full coverage, replayed by `ouroctl test`, and broken
    # by the same chart change.
    generated = root / "stopwatch-generated"
    shutil.copytree(EXAMPLES / "stopwatch", generated, ignore=shutil.ignore_patterns("tests"))
    out = run(str(BINARY), "test", "--generate", str(generated), env=env, timeout=120).stdout
    assert "stopwatch: " in out and "reach 7/7 states and 11/11 transitions" in out, out
    out = run(str(BINARY), "test", str(generated), env=env, timeout=120).stdout
    assert "PASS" in out and "1 passed, 0 failed" in out, out
    (generated / "charts.lua").write_text(charts.read_text())
    out = run(str(BINARY), "test", str(generated), env=env, ok=False, timeout=120).stdout
    assert "FAIL" in out and "DIVERGED at step" in out, out
    return len(log)


def contacts(env, root):
    app = Instance(env, root, "contacts")
    panels = "app/inset/body/panels/"
    wait_for(lambda: app.label("main", panels + "people/grace/row/content/text/select"), "contacts did not load")
    app.click("main", panels + "people/grace/row/content/text/select")
    app.type("main", panels + "details/rename", " B.")
    app.click("main", panels + "details/save")
    wait_for(lambda: (app.label("main", panels + "people/grace/row/content/text/select") or "").endswith("Grace Hopper B."),
             "rename did not apply: " + str(app.label("main", panels + "people/grace/row/content/text/select")) +
             "\n" + app.log.read_text())
    app.click("main", "app/inset/body/heading/theme")
    app.click("main", panels + "people/alan/row/content/text/select")
    time.sleep(0.3)  # the background save completes
    app.stop()
    log = entries(app.log)
    invokes = [e["e"]["type"] for e in log if e["k"] == "invoke"]
    assert "done.invoke.load" in invokes and "done.invoke.save" in invokes, invokes
    assert any(e["k"] == "start" and e["a"] == "appearance" for e in log)
    out = replay(app.log, EXAMPLES / "contacts")
    assert out.startswith(f"replay matched: {len(log)} entries"), out
    # Recorded invoke results unlock the states behind `load`.
    out = run(str(BINARY), "test", "--generate", str(EXAMPLES / "contacts"), "--output", str(root / "contacts-tests"),
              "--from", str(app.log), env=env, timeout=300).stdout
    assert "contacts: " in out and "reach 12/12 states" in out, out
    return len(log)


def documents(env, root):
    # No --record: development instances record to the state directory.
    app = Instance(env, root, "documents", record=False)
    default = Path(env["XDG_STATE_HOME"]) / "ourokit" / "recordings" / "dev.ourokit.documents.jsonl"
    diagnostics = call(app.endpoint, "runtime.diagnostics")["structuredContent"]
    assert diagnostics["recording"]["path"] == str(default) and not diagnostics["recording"]["failed"], diagnostics
    body = "documents/tabs/control/panels/%d/drop/layers/body/"
    app.type("main", body % 1 + "title", " draft")
    app.type("main", body % 1 + "text", "hello")
    app.click("main", body % 1 + "actions/new")
    app.type("main", body % 2 + "text", "second")
    app.click("main", "documents/tabs/control/strip/bar/1")
    app.click("main", "documents/tabs/control/strip/bar/2/close")
    app.click("main", "documents/tabs/control/panels/2/drop/layers/close-confirm/body/actions/discard")
    wait_for(lambda: app.label("main", "documents/tabs/control/strip/bar/2") is None, "discard did not close the tab")
    app.stop()
    log = entries(default)
    assert any(e["k"] == "start" and e["a"] == "notes" for e in log)
    assert any(e["a"] == "notes/document.2" and e["k"] == "event" for e in log), "child events are recorded"
    out = replay(default, EXAMPLES / "documents")
    assert out.startswith(f"replay matched: {len(log)} entries"), out
    return len(log)


def launcher(env, root):
    app = Instance(env, root, "launcher")

    def mapped():
        try:
            return app.label("launcher", "scrim/panel/body/search") is not None
        except AssertionError:
            return False
    wait_for(mapped, "the launcher surface did not map")
    app.type("launcher", "scrim/panel/body/search", "a")
    app.key("launcher", "arrow_down")
    app.key("launcher", "arrow_up")
    app.key("launcher", "escape")
    time.sleep(0.3)
    app.stop()
    log = entries(app.log)
    origins = {e.get("o") for e in log if e["k"] == "event"}
    assert {"app", "widget", "surface"} <= origins, origins
    assert any(e["k"] == "invoke" and e["e"]["type"] == "done.invoke.scan" for e in log)
    out = replay(app.log, EXAMPLES / "launcher")
    assert out.startswith(f"replay matched: {len(log)} entries"), out
    return len(log)


def main():
    with tempfile.TemporaryDirectory(prefix="ouro-chart-replay-") as directory:
        root = Path(directory)
        env = dict(os.environ, WAYLAND_DISPLAY=os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"])
        counts = {name: fn(env, root) for name, fn in
                  (("stopwatch", stopwatch), ("contacts", contacts), ("documents", documents), ("launcher", launcher))}
        print("PASS chart replay: real stopwatch, contacts, documents and launcher sessions replay to identical "
              "records and snapshots " + json.dumps(counts) + "; a changed chart reports its first divergent step; "
              "generated tests cover the stopwatch and fail on the change; seeded generation covers contacts")


if __name__ == "__main__":
    main()
