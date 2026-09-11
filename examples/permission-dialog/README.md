# Permission dialog

A standalone UI subprocess. No `actions`, MCP socket, or systemd service.
It reads one JSON document up to EOF on stdin and writes one JSON decision on
stdout. Reads and both stdout/stderr writes are asynchronous.

From the repository root, in a Wayland session:

```sh
zig build
printf '%s' '{"app_name":"Screenshot tool"}' |
  zig-out/bin/ouroctl run examples/permission-dialog/ouro.json --software
```

Type exactly `ALLOW`, then click Allow screenshot to print `{"allowed":true}`.
An empty or lowercase confirmation shows a validation message and produces no
decision. Don't allow needs no confirmation and prints
`{"allowed":false}`. Closing the window produces no decision. A caller must
grant permission only after a successful exit and an explicit valid allow
response. Treat crashes, invalid input/output, or a missing decision as denial.
Terminate/reap the dialog if the parent request is canceled.

Terminal style changes the entire dialog without clearing the confirmation.
While stdout is backpressured, the dialog shows Sending decision and disables
decision buttons until the async write finishes. There is no artificial delay.
Ordinary XKB typing works without text-input-v3; when that protocol is present,
the compositor/input method owns committed text instead.

Copy `assets/` with the app when relocating it. The shield icon is from Lucide
0.468.0, distributed with `assets/LUCIDE-LICENSE`.

This is a UI example, not a screenshot portal implementation. For actual portal
permission enforcement, the trusted portal backend must own the request and
launch the dialog. Requester-supplied display text is not authentication.
