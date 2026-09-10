# Permission dialog

A standalone UI subprocess. No `actions`, Varlink socket, or systemd service.
It reads one JSON document up to EOF on stdin and writes one JSON decision on
stdout. Reads and both stdout/stderr writes are asynchronous.

From the repository root, in a Wayland session:

```sh
zig build
printf '%s' '{"app_name":"Screenshot tool"}' |
  zig-out/bin/ouroctl run examples/permission-dialog/ouro.json --software
```

Clicking Allow prints `{"allowed":true}`; Don't allow prints
`{"allowed":false}`. Closing the window produces no decision. A caller must
grant permission only after a successful exit and an explicit valid allow
response. Treat crashes, invalid input/output, or a missing decision as denial.
Terminate/reap the dialog if the parent request is canceled.

This is a UI example, not a screenshot portal implementation. For actual portal
permission enforcement, the trusted portal backend must own the request and
launch the dialog. Requester-supplied display text is not authentication.
