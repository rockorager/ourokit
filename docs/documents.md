# Multi-document notes example

`examples/documents` is a deliberately small desktop-completeness example. Each
window owns a stable document id, path, title, text, dirty state, and inline
save/discard/cancel close confirmation. Both fields are single-line because
`text_input` is single-line. Files use strict JSON and the custom
`application/vnd.ourokit.note+json` MIME type; malformed, oversized, or unknown
data opens an error window without replacing any current edits.

Run it from the checkout with `zig-out/bin/ouroctl run
examples/documents/ouro.json -- [file:///path/note.ournote ...]`. Portal Open
accepts several notes, Save As uses the portal, and local I/O uses `ouro.files`.
The external buttons demonstrate URI activation and opening a closeable file
fd. Saves lazily connect to the freedesktop notification service. Text and raw
`text/uri-list` drops are accepted on the window.

The drag buttons call `ouro.start_drag` directly from their genuine pointer
activation callback, offering either the note text or its saved file URI.
Keyboard or synthetic button activation intentionally cannot supply the pointer
serial required to begin a compositor drag.

## User-local packaging

Review and adapt `/usr/bin/ouroctl` and `/usr/share/ourokit` in the supplied
desktop/service files, then install (no root required):

```sh
install -Dm644 examples/documents/dev.ourokit.documents.desktop ~/.local/share/applications/dev.ourokit.documents.desktop
install -Dm644 examples/documents/dev.ourokit.documents.service ~/.local/share/dbus-1/services/dev.ourokit.documents.service
install -Dm644 examples/documents/dev.ourokit.documents.xml ~/.local/share/mime/packages/dev.ourokit.documents.xml
install -Dm644 -t ~/.local/share/ourokit/documents examples/documents/{app.lua,model.lua,ouro.json}
update-mime-database ~/.local/share/mime
update-desktop-database ~/.local/share/applications
```

Uninstall those six copied files, remove the now-empty documents directory,
then rerun both update commands. The service's `--dbus-activated` path and the
desktop entry's `-- %U` path both reach `declaration.open`; activation may occur
before the UI factory and is queued.

Portal cancellation and failed writes retain dirty state. Each document allows
one save at a time, including its chooser phase, and snapshots carry a revision
so edits made while saving remain dirty. Save-and-close only closes after the
saved snapshot still matches the document. Closing
the final clean window exits naturally; dirty windows require an explicit
choice. Development source reload reconstructs Lua state and therefore loses
all unsaved application data—reload is not persistence.
