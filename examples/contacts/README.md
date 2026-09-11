# Contacts

One Lua application with schema-validated MCP tools and an optional UI. The sample
address book and selection are in memory; they reset after exit or source reload.
No real address-book storage or portal integration is implied.

The list contains 500 synthetic contacts with three different note lengths.
`ouro.virtual_list` measures row heights and mounts only the visible range plus
its buffer. Ada and Grace have original illustrated PNG avatars; contacts with
no avatar metadata use seeded initials. This is not an image-load-error fallback.
The source SVGs are included; regenerate PNGs with `magick -background none
assets/ada.svg assets/ada.png` (and the equivalent Grace command).

Select a contact, edit its name, and click Apply name. Selection and edits live
outside row lifetimes, so scrolling rows out of view does not discard them.
Terminal style toggles font, colors, and control geometry around the same tree.
The generic viewport handles wheel/Up/Down/Home/End/Page Up/Page Down scrolling;
Tab and Enter operate the row buttons. Unlike the original three-item listbox,
arrow keys scroll rather than change the selected contact.

`mail.svg` and `log-out.svg` are Lucide 0.468.0 icons, distributed with
`assets/LUCIDE-LICENSE`. Avatar artwork follows this repository's license.

## Direct development run

```sh
zig build
zig-out/bin/ouroctl run examples/contacts/ouro.json --software
```

This opens the UI and binds `$XDG_RUNTIME_DIR/ourokit/apps/dev.ourokit.contacts`.
Repeating the manifest launch forwards `Activate` to that process.

## Systemd user socket activation

Install the example into your own account (run these commands from the repo):

```sh
install -Dm755 zig-out/bin/ouroctl "$HOME/.local/bin/ouroctl"
mkdir -p "$HOME/.local/share/ourokit/contacts" "$HOME/.config/systemd/user"
cp examples/contacts/{app.lua,ouro.json} "$HOME/.local/share/ourokit/contacts/"
cp -R examples/contacts/assets "$HOME/.local/share/ourokit/contacts/"
cp examples/contacts/dev.ourokit.contacts.{socket,service} "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user import-environment WAYLAND_DISPLAY
systemctl --user enable --now dev.ourokit.contacts.socket
```

The manager must have the current session's `WAYLAND_DISPLAY`. The service's
`XDG_RUNTIME_DIR` is supplied by the user manager. Headless requests do not need
a compositor; only `Activate` does. Start the socket, not the service, to let
systemd activate the process on the first connection.

Invoke tools from a standalone Ourokit Lua script (for example, `/tmp/contacts-call.lua`):

```lua
local ouro = require("ouro")
local address = "unix:" .. assert(ouro.xdg.runtime_dir) .. "/ourokit/apps/dev.ourokit.contacts"
local discovery = ouro.mcp.request(address, "tools/list")
assert(discovery.error == nil)
ouro.stdout.write(ouro.json.encode(discovery.result) .. "\n")
local selected = ouro.mcp.call(address, "SelectContact", {id = "grace"})
assert(selected.error == nil and not selected.result.isError)
local renamed = ouro.mcp.call(address, "RenameContact", {
  id = "grace", name = "Rear Admiral Grace Hopper",
})
assert(renamed.error == nil and not renamed.result.isError)
ouro.stdout.write(ouro.json.encode(renamed.result.structuredContent) .. "\n")
ouro.exit(0)
```

```sh
"$HOME/.local/bin/ouroctl" run /tmp/contacts-call.lua --software
"$HOME/.local/bin/ouroctl" activate dev.ourokit.contacts
```

The first calls return data/change selection without creating a window.
Activation shows the selected contact. Renaming it updates the live UI through
the same shared signal. Missing IDs return an `isError: true` tool result with
`structuredContent.error.code = "ContactNotFound"` and the ID in
`structuredContent.error.parameters.id`. The native runtime validates arguments
and successful output against each action's JSON Schemas. `GetContacts` returns
all 500 records; `runtime.status`, `runtime.reload`, and `runtime.activate` share
the same MCP socket. No `initialize` handshake or legacy endpoint is supported.

When no UI has been activated, the process exits after 30 seconds with no
connections or tasks. Systemd retains its listening socket. Closing the last
window drains pending calls/output and exits; Quit explicitly requests exit.
To remove the example's activation, stop and disable its socket and service.
