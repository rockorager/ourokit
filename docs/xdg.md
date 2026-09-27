# Application directories

`ouro.xdg.paths(application_id)` returns app-scoped paths following the
[XDG Base Directory Specification](https://specifications.freedesktop.org/basedir/latest/):

```lua
local paths = assert(ouro.xdg.paths('org.example.Notes'))
-- paths.config:  $XDG_CONFIG_HOME/org.example.Notes  (default ~/.config/...)
-- paths.data:    $XDG_DATA_HOME/org.example.Notes    (default ~/.local/share/...)
-- paths.state:   $XDG_STATE_HOME/org.example.Notes   (default ~/.local/state/...)
-- paths.cache:   $XDG_CACHE_HOME/org.example.Notes   (default ~/.cache/...)
-- paths.runtime: $XDG_RUNTIME_DIR/org.example.Notes (no invented fallback)
assert(ouro.files.mkdir(paths.config))
assert(ouro.files.write(paths.config..'/preferences.json', ouro.json.encode({version=1})))
```

Use config for preferences; data for app-managed user data; state for session
restoration, history, and logs; cache only for regenerable data; runtime for
session-only sockets and similar files. Secrets belong in [Secret Service](secrets.md),
not these JSON files. A path does not grant filesystem access in a sandbox.

Lookup creates no files. Each call returns fresh tables. IDs are dotted names
with letters/underscore starting each component and letters, digits, underscore,
or hyphen thereafter (at most 255 bytes). Invalid IDs return
`nil, {kind='xdg', name='InvalidApplicationId', message=...}`.

`config_dirs` and `data_dirs` are ordered app-scoped search lists: the user
directory first, followed by `$XDG_CONFIG_DIRS` (default `/etc/xdg`) or
`$XDG_DATA_DIRS` (default `/usr/local/share:/usr/share`). Apps decide whether
to select the first matching file or merge their own formats. Relative entries
are ignored, never interpreted against the working directory. Empty/unset home
variables use defaults; invalid relative home variables also use defaults.
Without an absolute `HOME`, missing user paths remain absent. The runtime path
is absent without an absolute supplied runtime directory; the host/session is
responsible for its ownership, permissions, and lifetime. Existing
`ouro.xdg.runtime_dir` remains the unscoped host value.

## Documents, Downloads, and other user folders

`ouro.xdg.user_dir(kind)` asynchronously reads `user-dirs.dirs` under the user's
config directory. Kinds are `desktop`, `documents`, `download`, `music`,
`pictures`, `publicshare`, `templates`, and `videos`, matching the XDG names.

```lua
local documents, err = ouro.xdg.user_dir('documents')
```

This respects localized, redirected, and disabled directories. It parses the
file as data: quoted absolute paths, a leading `$HOME`, and quoted escapes;
it never sources a shell script or executes substitutions. Missing/invalid
entries fall back to the home directory, not guessed English names. A directory
explicitly set to `$HOME` also returns home. File reads are bounded to 64 KiB;
non-missing read failures propagate. Unknown kinds return
`InvalidUserDirectory`; unavailable config resolution returns
`DirectoryUnavailable`. The API never creates or rewrites `user-dirs.dirs`.

[Notes](documents.md) demonstrates versioned app-owned preferences and saved-file
session state, with atomic writes through `ouro.files`.
