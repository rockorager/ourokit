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
zig-out/bin/ouroctl run examples/contacts/ouro.json --software --dev
```

This opens an independent UI and prints a private development socket. Use
`ouroctl dev status <socket>` or `ouroctl dev reload <socket>` for that instance.
Repeated development launches create independent copies. Without `--dev`, the
sample's `single_instance=true` forwards subsequent launches through the session
bus, not MCP. Ordinary launch starts no MCP server.

## Desktop and session-bus activation

Install the example into your own account (run these commands from the repo):

```sh
install -Dm755 zig-out/bin/ouroctl "$HOME/.local/bin/ouroctl"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
mkdir -p "$data/ourokit/contacts" "$data/applications" "$data/dbus-1/services"
cp examples/contacts/{app.lua,ouro.json} "$data/ourokit/contacts/"
cp -R examples/contacts/assets "$data/ourokit/contacts/"
sed -e "s|/usr/bin/ouroctl|$HOME/.local/bin/ouroctl|g" \
    -e "s|/usr/share/ourokit/contacts|$data/ourokit/contacts|g" \
    examples/contacts/dev.ourokit.contacts.desktop > "$data/applications/dev.ourokit.contacts.desktop"
sed -e "s|/usr/bin/ouroctl|$HOME/.local/bin/ouroctl|g" \
    -e "s|/usr/share/ourokit/contacts|$data/ourokit/contacts|g" \
    examples/contacts/dev.ourokit.contacts.service > "$data/dbus-1/services/dev.ourokit.contacts.service"
dbus-update-activation-environment WAYLAND_DISPLAY XDG_RUNTIME_DIR
"$HOME/.local/bin/ouroctl" activate dev.ourokit.contacts
```

The desktop entry and session-bus service share the application ID. The bus
starts the process with `--dbus-activated`, which waits for the real
`org.freedesktop.Application.Activate` call before opening UI. The desktop Exec
fallback launches normally. The sample has no file-opening or desktop-action
hooks; those operations return NotSupported. Tokens are forwarded to Wayland;
the compositor decides focus. Remove the desktop/service files to uninstall
activation. No systemd socket or proprietary activation method is used.

## Optional application tools

To expose the sample's actions, start it explicitly with `--mcp` (after closing
an ordinary running copy). Add `--headless` only if you want a process that
never opens UI. This binds `$XDG_RUNTIME_DIR/ourokit/apps/dev.ourokit.contacts`;
it is separate from desktop activation. Export is optional and starts no app:

```sh
ouroctl run examples/contacts/ouro.json --mcp
ouroctl mcp export examples/contacts/ouro.json \
  --output "${XDG_DATA_HOME:-$HOME/.local/share}/ourokit/mcp/apps/dev.ourokit.contacts.json"
```

Regenerate the installed descriptor when updating the application. Export
evaluates only the declaration, not UI factories or action handlers; declaration
stdout is redirected to stderr and stdin is EOF. Optional consumers can read
descriptors offline; no external bridge is required.

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

The calls return data/change selection without altering desktop lifecycle.
Renaming updates the live UI through
the same shared signal. Missing IDs return an `isError: true` tool result with
`structuredContent.error.code = "ContactNotFound"` and the ID in
`structuredContent.error.parameters.id`. The native runtime validates arguments
and successful output against each action's JSON Schemas. `GetContacts` returns
all 500 records. Runtime status/reload exist only on an explicitly enabled
development endpoint, never in the production catalog. No `initialize`
handshake or legacy endpoint is supported. Closing the last window drains
pending calls/output and exits; Quit explicitly requests exit. A deliberately
headless process runs until application exit or a termination signal.
