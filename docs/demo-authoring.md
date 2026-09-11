# Authoring the richer demos

The Contacts and permission-dialog examples exercise images, icons, themes,
retained state, and asynchronous application I/O together. Contacts also uses a
variable-height virtual list with 500 synthetic records. Both retain their
application roles: Contacts exposes schema-validated MCP tools, and the
dialog reads one EOF-delimited JSON request and writes one JSON decision.

## More behavior, not necessarily less code

The original baseline is the examples introduced in
[1afec6f](https://github.com/rockorager/ourokit/commit/1afec6f).
The immediate baseline is the image-support revision
[7b3edec](https://github.com/rockorager/ourokit/commit/7b3edec298d4f2e78815f29a952c0699bd2920c3).
Counts include only each example's `app.lua`, not assets, documentation or tests.
“Code lines” excludes blank lines and lines starting with a Lua comment.

| Example / revision | Total lines | Code lines | UTF-8 bytes |
| --- | ---: | ---: | ---: |
| Contacts, original | 103 | 99 | 4,061 |
| Contacts, immediate baseline | 93 | 89 | 3,547 |
| Contacts, richer demo | 132 | 124 | 6,524 |
| Permission dialog, original | 71 | 65 | 2,434 |
| Permission dialog, immediate baseline | 65 | 59 | 2,154 |
| Permission dialog, richer demo | 66 | 57 | 3,454 |

This is not a controlled LOC reduction: the demos gained features, and inline
table formatting changes line counts. Both grew in bytes. The useful result is
which responsibilities remain outside application code:

- The virtual list measures heights, tracks its visible range and mounts rows.
  Selection and editable contact data stay in application signals, outside row
  lifetimes. UI and MCP actions call the same state-changing functions.
- Images load asynchronously; decoding, resource leases, clipping and rendering
  need no application-side worker or cache code.
- A root theme changes colors, typography and control geometry without
  duplicating the application tree or replacing its state.
- A dialog callback can await a backpressured stdout write. A `busy` signal
  prevents duplicate decisions while the event loop continues processing input.

## Friction exposed by writing the demos

- At the time of this pass, the Lua VM lacked standard helpers such as `ipairs`
  and `string.format`. These examples use numeric loops, concatenation and
  seeded initials. This gap is now addressed by the curated computation
  libraries documented in [runtime.md](runtime.md#embedded-lua); the measured
  example source above is unchanged.
- Buttons accept labels rather than arbitrary child content. Icons sit beside
  buttons instead of inside them.
- A virtual list is a scrolling container, not a virtualized listbox. The app
  owns selection; arrow keys scroll rather than select a contact. Row buttons
  remain reachable through Tab and Enter.
- Lua has no image-load-status hook. Initials represent missing avatar metadata,
  not a recovery path for failed image loads.

Real-window checks also exposed two native blockers, fixed alongside the demos:
forced io-wq pipe I/O could prevent cancellation from draining, and ordinary
typing needed an XKB fallback when the compositor lacks text-input-v3. The
fallback stays disabled when that protocol is available, avoiding duplicate
commits from the input method.

## Repeating the checks

Run `zig build test --summary all` and `zig build --summary all` first. For native
demo checks, provide a dedicated Weston X11 display with a 1,500 × 950 or larger
X screen. Do not use a display containing personal applications. The test needs
`xdotool`, ImageMagick and `systemd-socket-activate`; video capture also needs
FFmpeg. Set `DISPLAY` to the X display and `OUROKIT_TEST_WAYLAND_DISPLAY` to the
absolute Weston socket path, then run:

```sh
python3 tests/demo_apps.py
```

Optionally set `OUROKIT_DEMO_ARTIFACTS` to a capture directory. The test checks
headless Contacts calls, native activation and editing, scrolling, distant
MCP updates, theme retention, dialog validation, backpressured single-decision
output, denial, malformed input, and clean exits. It captures representative
windows and a Contacts scrolling/theme-switch video for visual inspection.
These demo checks use the software renderer; they do not verify hardware
compositor presentation.
