# Local files

`ouro.files` is a deliberately small asynchronous API:

```lua
local bytes, err = ouro.files.read(path_or_file_uri, { max_bytes = 1024 * 1024 })
local ok, err = ouro.files.write(path_or_file_uri, bytes)
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

Writes create a same-directory mode `0600` temporary file, write and `fsync`
it, then atomically rename it over the destination. Existing permissions are
therefore **not** preserved. A destination symlink is replaced rather than
followed. Parent-directory symlinks follow normal pathname resolution. Before
rename, failure or cancellation removes the temporary and leaves the old
destination unchanged. The parent directory is opened once before creating the
temporary, so changing a parent symlink during a write cannot redirect the
commit. Cancellation racing after the commit gate cannot undo a completed
rename, even if the caller is canceled before receiving its result. The containing directory is not
`fsync`ed, so replacement is atomic to live processes but is not guaranteed
durable across power loss.

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
