# HTTP requests

`ouro.http` provides yielding HTTP(S) requests in application tasks, including
headless hosts. It is unavailable outside a running task. Requests inherit that
task's scope; window/widget disposal, source reload, and application shutdown
cancel their requests. Cancellation cannot be caught to resume retired code.

```lua
local ouro = require('ouro')
local response = ouro.http.get('https://example.com/data', {
    timeout_ms = 5000,
    max_bytes = 1024 * 1024,
})
if response.status == 200 then
    local data = ouro.json.decode(response.body)
end

local created = ouro.http.post('https://example.com/items', {
    headers = { ['Content-Type'] = 'application/json' },
    body = ouro.json.encode({ name = 'example' }),
})

local updated = ouro.http.request {
    method = 'PATCH',
    url = 'https://example.com/items/1',
    body = 'replacement',
}
```

`request(options)` requires `url` and defaults `method` to `GET`.
`get(url[, options])` and `post(url[, options])` select their respective methods;
POST defaults to an empty body. Options are plain tables, read without invoking
metamethods:

| Option | Meaning |
| --- | --- |
| `headers` | Map of header names to string values; CR, LF, and NUL are rejected |
| `body` | Optional binary string, at most 64 MiB |
| `timeout_ms` | Positive integer total transfer deadline, including DNS; default 30,000, maximum 2,147,483,647 |
| `max_bytes` | Maximum decoded response body size; default 16 MiB, maximum 64 MiB |

There are at most 16 outstanding requests per source generation. Request and
response headers are each limited to 64 KiB. The response-header budget includes
informational and proxy response blocks, even though only the final response
headers and trailers are returned. URLs are limited to 8192 bytes.

Responses contain:

- `status`: integer HTTP status. 4xx/5xx are normal responses, not transport errors.
- `body`: binary string. Supported content encodings are decoded by curl before
  applying the size limit. HEAD responses have an empty body.
- `headers`: lowercase names mapped to arrays of values, preserving repeated
  headers without comma-joining them. For example, `response.headers['content-type'][1]`.

Redirects are **not followed automatically**. A 3xx response includes its
`location` header. Only HTTP and HTTPS URLs are accepted. TLS certificate and
hostname verification are always enabled, using the system curl trust store.
Curl's standard proxy environment variables apply; `.curlrc` is not loaded.

Invalid arguments and transport failures raise Lua errors and can be handled
with `pcall`. Named failures include `HttpTimeout`, `NameResolutionFailed`,
`ConnectionFailed`, `CertificateVerificationFailed`, `ResponseTooLarge`,
and `HeadersTooLarge`. The number of concurrent requests is not limited. Other transfer failures use
`HttpTransferFailed`. Failed transfers do not return partial bodies.

This first API buffers responses. Streaming, explicit redirect policies,
WebSockets, and raw TCP/TLS are not exposed yet.

## Native integration and resolver lifetime

`src/http` owns curl multi handles, request state, and protocol callbacks.
`src/loop` supplies one-shot io_uring readiness watches and the shared logical
timer heap. Curl performs nonblocking socket I/O and TLS; it does not submit
send/receive operations through io_uring. Only task-phase Lua continuations
construct response tables. Socket and timer callbacks never resume Lua.

The system libcurl must be at least 7.85.0, with TLS, asynchronous DNS, and
thread-safe global initialization. Builds lacking these features fail with
`UnsupportedCurlBuild`; they do not silently perform synchronous DNS.
The standalone `ourokit_ui` module does not link curl.

Each generation initializes curl on its first HTTP request, retaining its
connection and DNS caches for subsequent requests. Threaded resolvers use
system `getaddrinfo` behavior. Through curl 8.19, workers are per lookup and exit
after it finishes. Since 8.20, curl uses a lazy per-multi pool whose idle workers
exit after two seconds; builds with the new option cap this pool at four workers.
The DNS cache TTL is independent of worker lifetime. A system curl built with
c-ares instead uses its asynchronous resolver without these worker threads.

Canceling a request cannot interrupt a system resolver call already executing.
It may finish later, and pathological NSS/resolver behavior can delay final
cleanup. Generation teardown runs curl cleanup on a worker, notifying the
shared ring through a pipe, so it cannot block other UI/tasks. Shutdown drains
that cleanup before destroying its state; it does not forcibly terminate workers
or use curl's potentially leaking quick-exit mode.

`zig build test-http` exercises the real host with disposable loopback HTTP and
HTTPS peers, including binary uploads, repeated headers, decoded body limits,
timeouts, certificate rejection, concurrency, reload cancellation, and shutdown.
It requires Python 3 and the OpenSSL CLI; it does not contact public services or
change the system trust store. It is included in `zig build verify`.
