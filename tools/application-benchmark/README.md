# Application benchmark

This benchmark compares three small Wayland applications with the same useful
surface: one 480×320 window and one 160×44 clickable, text-labelled control.
Ourokit uses its Lua instance/reconciliation path, HarfBuzz shaping, FreeType
software glyph cache, display list, Wayring adapter, and shared raw `io_uring`.
GTK 4 uses `GtkApplication`/`GtkButton`; Qt 6 uses
`QApplication`/`QPushButton`.

Build the release binaries:

```sh
ZIG=/path/to/zig-0.16.0 tools/application-benchmark/build.sh
```

Run under Sway (a nested or headless compositor is fine):

```sh
tools/application-benchmark/run.py --iterations 20 --output results.json
```

The harness randomizes application order in each round. Startup is process
launch to Sway's `window::new`, which occurs when the xdg-toplevel maps with a
buffer. After a configurable settling interval it reads Linux `/proc` RSS,
PSS, private memory, and consumed process CPU time. Reported values are medians
after warmups and therefore describe warm-cache launch on that machine—not cold
boot, first installation, or another compositor.

GTK is forced to its Cairo renderer and Qt uses the QWidget raster backing
store, matching Ourokit's current CPU-only backend rather than comparing it to
a GPU renderer. On a minimal compositor, run the harness inside
`dbus-run-session` so the desktop toolkits see a normal session bus.

The controls have matched dimensions and behavior, not matched pixels. GTK and
Qt include mature native theme/style machinery; Ourokit currently draws a
minimal token-colored Box/Label composition. Dynamic library pages are counted
in RSS but mostly discounted by PSS and private-memory figures, so retain all
three columns. This first harness deliberately does not claim event latency:
a valid comparison needs the same injected input timestamp and a compositor-
observed presentation timestamp for all three applications.
