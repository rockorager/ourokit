# Local files

`ouro.files` is a deliberately small asynchronous API:

```lua
local bytes, err = ouro.files.read(path_or_file_uri, { max_bytes = 1024 * 1024 })
local ok, err = ouro.files.write(path_or_file_uri, bytes)
local ok, err = ouro.files.write(path_or_file_uri, bytes, {
    permissions = "preserve", symlinks = "reject", durable = true,
})
local fd, err = ouro.files.open(path_or_file_uri)
local fd, err = ouro.files.open(path_or_file_uri, { writable = true })
local ok, err = ouro.files.mkdir(absolute_directory)
```

Errors are returned as `nil, { name = "Code", message = "Code" }`. Operations are bounded to eight
concurrent requests per source generation. Reads default to 16 MiB and may be
raised to 64 MiB; writes are limited to 64 MiB. Strings are binary-safe.

Paths must be absolute. `file:/path`, `file:///path`, and
`file://localhost/path` are accepted. Other authorities, query strings,
fragments, malformed escapes, encoded `/`, and NUL are rejected. Percent
escapes decode directly to filename bytes; they are not Unicode-normalized.
Network retrieval, directory enumeration, and arbitrary filesystem mutations
are not provided.

`mkdir` recursively creates directories with mode `0700` (subject to umask),
accepts existing directories without changing their permissions, and rejects
symlink components and `.`/`..` traversal. It uses directory-relative syscalls
and runs on the file worker. Failure/cancellation may leave directories already
created; it never removes them. Lookup through [XDG paths](xdg.md) alone does not
create directories.

Writes stage bytes in a same-directory mode `0600` temporary (subject to umask),
apply the permission policy, `fsync` the file, and atomically rename it over the
destination. The optional third argument accepts only these keys and values;
invalid values and unknown keys return `InvalidOptions`:

| Option | Default | Policy |
| --- | --- | --- |
| `permissions` | `"preserve"` | Copy an existing regular file's rwx bits (`0777`), including executable and read-only bits. Do not copy set-ID or sticky bits. `"private"` keeps the temporary's private mode instead. New files use `0600` subject to umask under either policy. |
| `symlinks` | `"reject"` | Return `SymlinkNotAllowed` for a destination symlink, including dangling links. `"replace"` replaces the link itself with a private regular file; it never changes the target or copies its permissions. |
| `durable` | `true` | After rename, `fsync` the opened parent directory before reporting success. `false` skips only directory sync; file sync still occurs. |

**Compatibility:** two-argument calls now preserve rwx permissions, reject
destination symlinks, and request durability. To request the former policies,
pass `{ permissions = "private", symlinks = "replace", durable = false }`.
Existing non-regular destinations (directories, FIFOs, devices, sockets) are
rejected with `NotRegularFile`, even with `symlinks = "replace"`.

Replacement creates a new inode: ownership, ACLs, extended attributes, and
hard-link identity are **not** preserved. Permission preservation is not full
metadata preservation. A writable parent directory permits replacement even
when the destination's mode is read-only. ACL inheritance follows filesystem
rules; callers requiring exact metadata or in-place writes need another API.

There is deliberately no follow-symlink option. An editor can surface a rejected
link to the user and save to an explicitly selected target path. Parent-directory
symlinks still follow normal pathname resolution. The parent directory is opened
once, so retargeting a parent symlink during a write cannot redirect the commit.
Destination type is checked before staging and again before the commit gate;
permissions are sampled at the first check. These checks do not lock the name:
concurrent writers or directory-entry changes can race the checks and rename.
This is neither conflict detection nor a security boundary against a process
that can mutate the directory. In particular, a symlink installed after the last
check can be replaced (never followed).

Before rename, failure or cancellation removes the temporary and leaves the old
destination unchanged. Cancellation after the commit gate cannot undo rename or
skip the requested directory sync, even if the caller is canceled before receiving
its result. A directory-sync failure returns
`nil, { name = "DurabilityUncertain", message = "DurabilityUncertain", committed = true }`:
**the replacement is already visible; persistence across power loss is uncertain**.
Do not treat this as an unchanged destination or blindly retry the save. Other
write errors occur before replacement. Interrupted file and directory syncs are
retried; unsupported directory sync is an error, not silent success. Successful
durability depends on the filesystem/storage honoring `fsync`; it does not sync
ancestors of newly created parent directories or guarantee remote-server behavior.

Workers perform bounded blocking syscalls away from the Lua/UI thread and
publish completion through the application's io_uring. A generation owner must
call `Binding.init(allocator, vm, loop)`, route file CQEs through `dispatch`,
call `collectCanceled` at task safe points, call `stop` on retirement, pump
until `canDeinit()`, then call `deinit`.

On Linux, reads of regular files can still block in the kernel (for example on
a remote filesystem) despite `O_NONBLOCK`. Cancellation drains such outstanding
kernel work; it does not promise immediate syscall interruption.

`open` accepts regular files and directories and returns an owned D-Bus FD
userdata (closed by `:close()`, `<close>`, or garbage collection). It uses
nonblocking open and rejects other file kinds, so FIFOs and devices cannot
stall the UI thread. Opens are read-only by default. `{writable=true}` requests
read/write access to an existing file without creating or truncating it, for
services such as the Trash portal. Linux does not support read/write opens of
directories; use the default for directory descriptors.
