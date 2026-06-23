# mruby-url

A URL client for mruby, backed by an embedded libcurl. A high-level,
blocking HTTP(S) client sits on top; the same top-level `URL` class also
exposes non-HTTP protocols (SMTP(S) send, IMAP(S) commands) through
RFC-verb-named methods, and a small integration class for driving transfers
on a real event loop.

```ruby
URL.get("https://example.com").body                                   # quick
URL.get("https://api.example.com/users", params: { limit: 10 }).json
URL.post("https://api.example.com/users", json: { name: "Alice" }).raise_for_status!.json

# Stream a big response instead of buffering it:
URL.get("https://huge.example.com/file") { |chunk| File.open("out", "ab") { |f| f.write(chunk) } }
```

> **Status:** HTTP(S) is complete and covered by the test suite; SMTP(S)
> send and IMAP(S) verbs are implemented and tested against in-tree fixture
> servers. The high-level API is settling toward a tagged release — expect
> only minor changes from here. Which protocols are actually available
> depends on the libcurl this gem was built against; check at runtime with
> `URL.supports?`.

Why `URL`? Because libcurl speaks many protocols and they all have a URL in
common. HTTP is the first thing exposed; SMTP and IMAP are in, and FTP,
POP3, MQTT, WebSocket and friends slot in under the same class over time —
each as a method named after the protocol's own verb, dispatched on the URL
scheme (see [Non-HTTP protocols](#non-http-protocols)).

## Defaults

Every HTTP call gets these unless you override them:

- `timeout_ms: 30_000` — prevents indefinite hangs
- `follow_location: true` — HTTP redirects followed
- `user_agent: "mruby-url"`
- libcurl advertises `Accept-Encoding` for gzip/deflate/br/zstd and
  transparently decompresses (pass `accept_encoding:` to narrow it)

## Convenience kwargs

| kwarg | what it does |
| --- | --- |
| `params: { ... }` | Appended to the URL as a query string (`URI.encode`, WHATWG-strict). Array values expand to repeated keys. |
| `json: <obj>` | Body is `JSON.dump(obj)`; auto `Content-Type` and `Accept` of `application/json`. |
| `form: { ... }` | Body is `application/x-www-form-urlencoded`; `Content-Type` set accordingly. |
| `auth: "user:pass"` or `["user", "pass"]` | Basic auth via `CURLOPT_USERPWD` (libcurl builds the header). |
| `bearer: "<token>"` | Adds `Authorization: Bearer <token>` (user headers override). |
| `netrc: true / :optional / :required` | Read credentials from `~/.netrc`. `true`/`:optional` falls back to the request's own creds; `:required` uses `.netrc` only. |
| `netrc_file: "<path>"` | Use a `.netrc` at a non-default path. |
| `headers: { ... }` | Extra headers. Wins over anything we auto-set. |
| any `curl_easy` opt | `timeout_ms`, `proxy`, `cookiefile`, `cookiejar`, `verbose`, `ssl_verify_peer`, `userpwd`, … (see [Options reference](#options-reference)). |

## Response

```ruby
r = URL.get("https://example.com/api")

r.code              # => 200
r.body              # => "..."
r.headers           # => { "content-type" => ..., "set-cookie" => [...], ... }
r["Content-Type"]   # => "application/json"
r.content_length    # => 1234
r.success? / .client_error? / .server_error? / .redirect? / .error?
r.error_message     # decorated when there was a transport failure
r.raise_for_status! # raise URL::HTTPError if 4xx/5xx or transport-failed

r.json              # JSON.parse(body), cached
r.json_lazy         # JSON.parse_lazy(body) -> JSON::Document, cached
r.into(target)      # mruby-fast-json native_ext_type deserialization
```

`r.into(target)` is shorthand for `r.json_lazy.into(target)`. Because
`mrb_iv_set` doesn't care what shape the receiver has, the target can be an
instance, a class, or a module:

```ruby
class Config
  attr_accessor :api_key, :region
  native_ext_type :@api_key, String
  native_ext_type :@region,  String
end

URL.get(".../config").into(Config.new)   # fill an instance
URL.get(".../config").into(Config)       # populate class-level @api_key / @region
```

For array responses, drop down to mruby-fast-json directly so you control
how each instance is constructed:

```ruby
URL.get(".../users").json_lazy.array_each do |doc|
  u = User.new
  doc.into(u)
  process(u)
end
```

## Streaming

Pass a block to a one-shot to receive body chunks as they arrive instead of
buffering. Useful for big downloads, video, LLM token streams.

```ruby
URL.get("https://huge.example/file") do |chunk|
  File.open("out", "ab") { |f| f.write(chunk) }
end
```

`response.body` is empty in that case — you handled it.

## Calling URL from inside a callback

The high-level verbs reuse one shared session per `mrb_state`
(`URL.shared`), so libcurl's connection pool, TLS sessions and HTTP/2
streams persist across calls. That session can only drive one transfer at a
time, so a call made from *inside* a streaming/callback (where the shared
session is mid-flight) would be re-entrant. mruby-url detects that and
transparently runs the nested call on a throwaway session — so this just
works:

```ruby
URL.get("https://a.example/stream") do |chunk|
  enrich(chunk, URL.get("https://b.example/lookup").json)   # nested call, fresh session
end
```

## Non-HTTP protocols

Non-HTTP protocols are exposed as methods named after the protocol's own RFC
verb. Each dispatches on the URL scheme and is gated behind `URL.supports?`,
so a scheme the embedded libcurl wasn't built with raises `URL::Error`
*before* any connection attempt.

```ruby
URL::PROTOS            # => ["http", "https", "smtp", "smtps", "imap", "imaps", ...]
URL.supports?("smtps") # => true / false
```

### SMTP(S) — `URL.send`

`URL.send(server_url, body, from:, to:, **opts)` submits a message. `body`
is the full RFC822 message (positional); `to:` is a String or an Array of
recipients. The body is streamed to libcurl's read callback, chunked in
Ruby. Returns a `URL::Response` whose `code` is the final SMTP reply (e.g.
`250`).

```ruby
URL.send(
  "smtps://mail.example.com:465",
  "Subject: hi\r\n\r\nhello body\r\n",
  from: "me@example.com",
  to:   ["a@example.com", "b@example.com"],
  netrc: true,                      # or auth: "user:pass"
)
```

> `URL.send` deliberately overrides `Object#send`. Use `URL.__send__` for
> reflection.

### IMAP(S) — `move` / `store` / `expunge` / `fetch`

The mailbox is the URL path (`imaps://user:pass@host/INBOX`); UIDs go into
the command. Each returns a `URL::Response`; a `NO`/`BAD` tagged reply is
raised as `URL::Error`.

```ruby
base = "imaps://user:pass@imap.example.com/INBOX"

URL.fetch(base, uid: 7)                          # UID FETCH 7 BODY[] -> Response#body
URL.fetch(base, uid: 7) { |chunk| sink(chunk) }  # ...or stream it

URL.store(base, uid: 7, flags: "\\Deleted")      # UID STORE 7 +FLAGS (\Deleted)
URL.store(base, uid: 7, flags: "\\Seen", op: "-")# remove a flag (op: "+"/"-"/"")
URL.expunge(base)                                # delete = store(\Deleted) then expunge
URL.move(base, uid: 7, to: "Archive")            # UID MOVE 7 Archive
```

## Tuning the shared session

`URL.shared` is the process-wide session (per `mrb_state`). Tune its pool
once at startup:

```ruby
URL.shared.setopt(:pipelining,             2)    # CURLPIPE_MULTIPLEX (HTTP/2)
URL.shared.setopt(:max_concurrent_streams, 100)
URL.shared.setopt(:max_total_connections,  256)
```

## Integrating a real event loop

By default the verbs block on a built-in `IO.select` loop. To drive
transfers on a platform loop (glib, libuv, …) instead, subclass
`URL::EventLoop` and implement four primitives:

```ruby
class URL::EventLoop
  def watch(io, readiness, &block)   # readiness: :in / :out / :inout — start watching io
  def unwatch(handle)                # handle is whatever watch returned
  def arm_timer(ms, &block)          # call block.() once, ms from now
  def cancel_timer(handle)
end
```

Your loop's only job is to invoke the block at the right moment: call the
`watch` block when the fd becomes ready, and the `arm_timer` block when the
timer fires. Each block drives `socket_action` + completion reaping + removal
internally — you never touch the session from your loop directly.

Install one instance process-wide and the verbs become fire-and-forget
(returning `nil` instead of a `URL::Response`):

```ruby
URL.default_loop = MyGlibLoop.new
URL.get("https://example.com/ping")   # attaches to the loop, returns nil
```

or set it per session via `session.event_loop = my_loop`.

### Driving a session by hand

`URL::IOSelectLoop` is the built-in `EventLoop` subclass. You can wire a
session, requests and a loop together yourself when you want IO.select but
custom orchestration:

```ruby
session = URL.open
loop    = URL::IOSelectLoop.new(session)
session.event_loop = loop

req = URL::Request._open(session, "https://example.com")
req.on_data { |chunk| sink(chunk) }
session.add(req)

loop.run do |completed_req, code|       # one call per completion
  # code == 0 => CURLE_OK
end
```

`loop.run_until(target) { |req, code| ... }` drives only until `target`
completes — needed for the shared session, whose kept-alive sockets outlive
any single request.

## Options reference

### `URL#setopt` (1:1 with `curl_multi_setopt`)

| Symbol | `CURLMOPT_` | Notes |
| --- | --- | --- |
| `:pipelining` | PIPELINING | bitmask; `2` (CURLPIPE_MULTIPLEX) for HTTP/2 |
| `:maxconnects` | MAXCONNECTS | connection-cache size |
| `:max_host_connections` | MAX_HOST_CONNECTIONS | per-origin cap (HTTP/1.1) |
| `:max_total_connections` | MAX_TOTAL_CONNECTIONS | global cap |
| `:max_concurrent_streams` | MAX_CONCURRENT_STREAMS | HTTP/2 client-side |

### `URL::Request#setopt` (1:1 with `curl_easy_setopt`)

| Symbol | `CURLOPT_` |
| --- | --- |
| `:url` | URL |
| `:custom_request` | CUSTOMREQUEST |
| `:user_agent` | USERAGENT |
| `:cainfo` | CAINFO |
| `:accept_encoding` | ACCEPT_ENCODING |
| `:userpwd` | USERPWD |
| `:netrc` | NETRC (`0`/`1`/`2`) |
| `:netrc_file` | NETRC_FILE |
| `:proxy` | PROXY |
| `:cookiefile` | COOKIEFILE |
| `:cookiejar` | COOKIEJAR |
| `:follow_location` | FOLLOWLOCATION |
| `:max_redirs` | MAXREDIRS |
| `:verbose` | VERBOSE |
| `:timeout_ms` | TIMEOUT_MS |
| `:connect_timeout_ms` | CONNECTTIMEOUT_MS |
| `:ssl_verify_peer` | SSL_VERIFYPEER |
| `:ssl_verify_host` | SSL_VERIFYHOST |
| `:nobody` | NOBODY |
| `:connect_only` | CONNECT_ONLY |
| `:upload` | UPLOAD |
| `:mail_from` | MAIL_FROM |
| `:mail_rcpt` | MAIL_RCPT (Array) |
| `:post_fields` | COPYPOSTFIELDS (size from POSTFIELDSIZE_LARGE) |

Headers: pass `headers: { ... }` to a one-shot, or `Request#headers=`.

## Dependencies

- `mruby-io` — `IO.select`, `IO.for_fd`
- `mruby-error` — `mrb_protect_error`
- `mruby-uri-parser` — ada-url-based URL handling (WHATWG-compliant)
- `mruby-fast-json` — simdjson-backed JSON, with `native_ext_type` schemas
- `mruby-c-ext-helpers`
- `mruby-socket`
- `mruby-string-ext` — `String#byteslice` for Ruby-side upload chunking

On Linux/macOS the gem finds libcurl via `pkg-config`. On Windows it builds
the vendored `deps/curl` with CMake and links it statically against Schannel
(no OpenSSL); `mrbgem.rake` handles this.

## Design notes

- **C is an FFI-thin binding only.** `src/mrb_url.c` does only what a generic
  FFI layer could: call libcurl, marshal primitives across the boundary,
  register the callbacks libcurl requires, and copy bytes. Everything else —
  dispatch, option/verb mapping, control flow, per-transfer state, parsing,
  scheme handling — lives in memory-safe Ruby under `mrblib/`. Hand-written
  C is the only place a memory-safety bug can hide, so keeping C at FFI level
  keeps the fuzzable surface near zero. See `CLAUDE.md`.
- The C layer exposes flat `URL::Libcurl` primitives over an `Easy`
  (`curl_easy_*`) and a `Multi` (`curl_multi_*`) CDATA handle.
  `URL::Request` and the session (`URL`) are thin Ruby wrappers over them.
- C callbacks stay minimal: write/header copy bytes in and yield under
  `mrb_protect_error`; read copies one bounded chunk out; the socket and
  timer callbacks are store-only (they record into plain C, and Ruby acts on
  it afterwards). The C side never `longjmp`s through libcurl — the first
  exception is stashed on `mrb->exc`, the callback returns libcurl's abort
  code, and it's re-raised on the way back to Ruby.
- `curl_global_init` runs exactly once per process via C11 `call_once`, and
  `curl_global_cleanup` is deferred to `atexit` — not tied to `mrb_state`
  lifecycle, so spinning VMs up and down never races or tears down the
  TLS/Winsock layer under a live transfer.
- `URL::Request` is private (`#initialize` undef'd; `_open` factory). The
  verbs use it internally. If you get one back from `info_read` you can call
  `#response_code`, `#effective_url`, `#total_time`, `#content_type`,
  `#setopt`, `#headers=`, `#on_data`, `#on_header`, `#on_read` on it.
- Per-transfer state lives in `URL::TransferState`, not on the Request.
- `IO.for_fd` runs with `autoclose = false` everywhere we touch
  libcurl-owned fds — libcurl owns those lifecycles; we must not close them.
- Redirect chains: parsed `Response#headers` keeps only the final response;
  the full sequence stays in `#raw_headers`.

## Roadmap

Everything libcurl can do is in scope. Not yet implemented: parallel
fan-out (running many transfers on one session and collecting results by
key), and more protocol verbs (FTP, POP3, MQTT, WebSocket, …) as they're
needed.
