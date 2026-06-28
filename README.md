# mruby-url

A URL client for mruby backed by an embedded libcurl. **Every scheme libcurl
can be built with is reachable** — `http(s)`, `ftp(s)`, `sftp`, `scp`,
`file`, `dict`, `gopher(s)`, `pop3(s)`, `imap(s)`, `smtp(s)`, `ldap(s)`,
`mqtt(s)`, `rtsp`, `telnet`, `tftp`, `ws(s)` — exposed through one small
surface where each scheme has the verbs that fit it. Errors are values, the
connection / TLS-session cache is shared across requests, and dependencies
land where you'd expect them on Linux/macOS/Windows.

```ruby
URL("https://example.com").get.body
URL("https://api.example.com/users").get(params: { limit: 10 }).json
URL("https://api.example.com/users").post(json: { name: "Alice" }).raise_for_status!.json

# multipart/form-data (curl_mime): String = field, Hash = file part (streamed from disk)
URL("https://api.example.com/upload").post(multipart: {
  "title"  => "vacation",
  "avatar" => { file: "pic.png", type: "image/png" },
})

# Streaming a big response
URL("https://huge.example.com/file").get { |chunk| sink << chunk }

# Other protocols use the same shape
URL("ftp://host/pub/").list.lines
URL("sftp://host/path/big.bin").upload(File.open("big.bin", "rb"))
URL("imaps://user:pw@mail/INBOX").fetch(uid: 42).body
URL("wss://echo.websocket.org").connect { |ws| ws.send_text("hi"); puts ws.receive.data }
```

> **Status:** every scheme is implemented and covered by fixture-server
> integration tests. The high-level API is settling toward a tagged release.
> Which protocols are actually available at runtime depends on the libcurl
> this gem was built against — check with `URL.supports?("scheme")`.

## Calling URL

`URL(uri)` dispatches on the scheme and returns the right wrapper:
`URL::HTTP`, `URL::Transfer`, `URL::Gopher`, `URL::Dict`, `URL::IMAP`,
`URL::POP3`, `URL::SMTP`, `URL::LDAP`, `URL::MQTT`, `URL::RTSP`, `URL::WS`.
Each class carries only the verbs that fit the protocol. An *unknown* scheme
— one `URL::PROTOS` doesn't list — raises `URL::Error` from `URL(uri)` itself.
A scheme libcurl recognizes but wasn't compiled with still constructs its
wrapper fine and raises only when you call a verb, so the failure stays where
the work happens.

```ruby
# Build once, call repeatedly:
api = URL("https://api.example.com/users")
api.get(params: { limit: 10 })
api.post(json: payload)

# One-shot class method when you know the scheme up front, no factory:
URL::HTTP.get("https://x", json: {...})
URL::Transfer.upload("sftp://h/path", io)     # ftp(s) / sftp / scp / file / tftp / telnet
URL::IMAP.fetch("imaps://h/INBOX", uid: 7)
URL::WS.connect("wss://h/sock") { |ws| ws.send_text("hi") }
```

## Defaults

Every HTTP call gets these unless you override them:

- `timeout: 30.s` — prevents indefinite hangs (any chrono duration: `500.ms`, `2.min`, …)
- `follow_location: true` — HTTP redirects followed
- `user_agent: "mruby-url"`

Compression is **opt-in**, not a default: pass `accept_encoding: ""` to
advertise gzip/deflate/br/zstd and have libcurl transparently decompress the
response, or a specific token list (e.g. `"gzip"`) to narrow it.

## Convenience kwargs

| kwarg | what it does |
| --- | --- |
| `params: { ... }` | Appended to the URL as a query string (`URI.encode`, WHATWG-strict). Array values expand to repeated keys. |
| `json: <obj>` | Body is `JSON.dump(obj)`; auto `Content-Type` and `Accept` of `application/json`. |
| `form: { ... }` | Body is `application/x-www-form-urlencoded`; `Content-Type` set accordingly. |
| `multipart: { ... }` | `multipart/form-data` via `curl_mime`. A String value is a plain field; a Hash is a file/blob part — `file:` streams from disk (never buffered in Ruby), `data:` is an in-memory blob, `filename:`/`type:` set the part headers. |
| `auth: "user:pass"` or `["user", "pass"]` | Basic auth via `CURLOPT_USERPWD` (libcurl builds the header). |
| `bearer: "<token>"` | Adds `Authorization: Bearer <token>` (user headers override). |
| `netrc: true / :optional / :required` | Read credentials from `~/.netrc`. `true`/`:optional` falls back to the request's own creds; `:required` uses `.netrc` only. |
| `netrc_file: "<path>"` | Use a `.netrc` at a non-default path. |
| `headers: { ... }` | Extra headers. Wins over anything we auto-set. |
| `timeout: 30.s` / `connect_timeout: 5.s` | Durations (mruby-chrono). Any unit — `500.ms`, `2.min` — handed to libcurl as milliseconds losslessly. |
| any `curl_easy` opt | `proxy`, `cookiefile`, `cookiejar`, `verbose`, `ssl_verify_peer`, `userpwd`, … (see [Options reference](#options-reference)). |

## Response

```ruby
r = URL("https://example.com/api").get

r.code              # => 200
r.body              # => "..."
r.headers           # => { "content-type" => ..., "set-cookie" => [...], ... }
r["Content-Type"]   # => "application/json"
r.content_length    # => 1234
r.success? / .client_error? / .server_error? / .redirect? / .error?
r.error_message     # decorated when there was a transport failure
r.raise_for_status! # raises resp.error (e.g. URL::HttpReturnedError) on 4xx/5xx or transport failure

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

URL(".../config").get.into(Config.new)   # fill an instance
URL(".../config").get.into(Config)       # populate class-level @api_key / @region
```

For array responses, drop down to mruby-fast-json directly so you control
how each instance is constructed:

```ruby
URL(".../users").get.json_lazy.array_each do |doc|
  u = User.new
  doc.into(u)
  process(u)
end
```

## Streaming

Pass a block to a one-shot to receive body chunks as they arrive instead of
buffering. Useful for big downloads, video, LLM token streams.

```ruby
URL("https://huge.example/file").get do |chunk|
  File.open("out", "ab") { |f| f.write(chunk) }
end
```

`response.body` is empty in that case — you handled it.

## Calling URL from inside a callback

The high-level verbs reuse one shared session per `mrb_state`
(`URL.shared`), so libcurl's connection pool, TLS sessions and HTTP/2
streams persist across calls. That session can only drive one transfer at
a time, so a call made from *inside* a streaming/callback (where the
shared session is mid-flight) would be re-entrant. mruby-url detects that
and transparently runs the nested call on a throwaway session — and a
process-wide `CURLSH` (`URL::Libcurl::SHARE`) means the throwaway shares
the **same connection cache and TLS-session-ticket cache** as the shared
session, so a nested call to a host you already opened resumes TLS (and
often reuses the live TCP/HTTP-2 connection) instead of doing a full
handshake. Transparent in both directions:

```ruby
URL("https://a.example/stream").get do |chunk|
  enrich(chunk, URL("https://b.example/lookup").get.json)
  log(URL("https://a.example/meta").get.json)   # warm — same host as the outer call
end
```

## Parallel fan-out

`URL.parallel` drives many requests concurrently on one session — the
connection pool, TLS sessions and HTTP/2 multiplexing all carry over —
and collects the responses keyed however you want:

```ruby
results = URL.parallel do |p|
  p.get("https://a.example/feed",  key: :feed)
  p.post("https://b.example/login", key: :login, json: creds)
  p.get("ftp://h/manifest.txt",     key: :manifest)
  p.on_complete { |key, resp| warm[key] = resp }   # live, as they finish
end
results[:feed].json
results[:login].json
```

Runtime failures stay values (`resp.error`); only usage errors (unknown
scheme, missing protocol) raise. A re-entrant call from inside one of the
on-complete handlers falls back to a throwaway session, the same way the
blocking verbs do.

## Other protocols

Every scheme `URL::PROTOS` lists is reachable. Failures are values
(`resp.error`), exactly like the HTTP verbs. Only an *unknown* scheme raises
`URL::Error`, from `URL(uri)` itself; a recognized scheme that libcurl wasn't
built with raises only when you call a verb.

```ruby
URL("ftp://host/pub/file.txt").download.body          # ftp(s), sftp, scp,
URL("file:///etc/hostname").download.body             #   file, dict, gopher,
URL("sftp://user@host/path").download(                #   pop3, tftp, ldap, telnet…
  ssh_private_keyfile: "id_ed25519",
  ssh_knownhosts:      "known_hosts",
).body

URL("ftp://host/incoming/x.txt").upload(data)         # ftp(s), sftp, scp, tftp
URL("ftp://host/pub/").list.lines                     # directory / message list
URL("dict://dict.org").define("ruby").body            # DICT define
URL("ldap://host/dc=ex,dc=com?cn?sub?(cn=*)").search  # LDAP search → LDIF body
URL("mqtt://host/topic").publish("payload")           # MQTT publish
URL("mqtt://host/topic").subscribe(timeout: 5.s)      # MQTT subscribe → #body

URL("rtsp://host/stream").describe                    # RTSP OPTIONS/DESCRIBE/PLAY/…
URL("rtsp://host/stream").options
URL("rtsp://host/stream").play
```

`download`/`upload` and the wrappers take the same `**opts` as the HTTP
verbs plus protocol options as needed: `:quote` (FTP/SFTP commands),
`:dirlistonly`, `:range`, `:use_ssl`, the `:ssh_*` keys. The `s` schemes
(ftps, pop3s, gophers, ldaps, mqtts, …) are the same calls over TLS — pass
`ssl_verify_peer:`/`ssl_verify_host:` as usual. As with everything here,
the dispatch, option mapping and parsing live in Ruby; the C layer only
gained a handful of flat `setopt` pass-throughs and a blocking `easy_perform`.

### Supported schemes

```ruby
URL::PROTOS            # => ["dict","file","ftp","ftps","gopher","gophers",
                       #     "http","https","imap","imaps","ldap","ldaps",
                       #     "mqtt","mqtts","pop3","pop3s","rtsp","scp",
                       #     "sftp","smtp","smtps","telnet","tftp","ws","wss"]
URL.supports?("smtps") # => true / false
```

### SMTP(S)

`URL("smtps://…").deliver(body, from:, to:, **opts)` submits a message.
`body` is the full RFC822 message (or any IO / Enumerable / Fiber / Proc
that yields the bytes — see [Upload sources](#upload-sources)); `to:` is
a String or an Array. Returns a `URL::Response` whose `code` is the final
SMTP reply (e.g. `250`).

```ruby
URL("smtps://mail.example.com:465").deliver(
  "Subject: hi\r\n\r\nhello body\r\n",
  from: "me@example.com",
  to:   ["a@example.com", "b@example.com"],
  netrc: true,                      # or auth: "user:pass"
)
```

> The verb is called `deliver` (not `send`) so we never shadow
> `Object#send`.

### IMAP(S) — `fetch` / `move` / `store` / `expunge`

The mailbox is the URL path (`imaps://user:pw@host/INBOX`); UIDs go into
the command. Each returns a `URL::Response`; a `NO`/`BAD` tagged reply
shows up as `resp.error` (a `URL::TransferError`), not a raise.

```ruby
mbox = URL("imaps://user:pw@imap.example.com/INBOX")

mbox.fetch(uid: 7).body                       # UID FETCH 7 BODY[]
mbox.fetch(uid: 7) { |chunk| sink(chunk) }    # ...or stream

mbox.store(uid: 7, flags: "\\Deleted")        # UID STORE 7 +FLAGS (\Deleted)
mbox.store(uid: 7, flags: "\\Seen", op: "-")  # remove a flag (op: "+"/"-"/"")
mbox.expunge                                  # delete = store(\Deleted) then expunge
mbox.move(uid: 7, to: "Archive")              # UID MOVE 7 Archive
```

### Upload sources

`upload` duck-types whatever you hand it — no need to slurp a file into
memory first:

```ruby
URL("ftp://h/x").upload("the body bytes")                      # String

File.open("big.bin", "rb") do |f|                              # IO/File:
  URL("sftp://h/path/big.bin").upload(f)                       #   streams via #read(max)
end                                                            #   sets CURLOPT_INFILESIZE

URL("ftp://h/feed.csv").upload(rows.lazy.map(&:to_csv))        # any Enumerable

URL("ftp://h/log").upload(->(max) { source.read(max) })        # Proc / Lambda

fib = Fiber.new { Fiber.yield "a"; Fiber.yield "b"; "done\n" } # Fiber yielding chunks
URL("ftp://h/x").upload(fib)
```

We never close a `File`, exhaust a `Socket`, rewind, or clean up after a
`Fiber` — open/close stays your responsibility. The same streaming reader
is used by SMTP `deliver`, so a mail body can be any of those too.

## WebSocket

`URL("ws://…").connect` (or `URL("wss://…").connect`) opens the
connection and returns a `URL::WebSocket` once the upgrade handshake
completes. Messages are sent and received whole — fragmentation and
oversized frames are reassembled for you, and inbound PINGs are answered
automatically.

```ruby
URL("wss://echo.websocket.org").connect do |ws|
  ws.send_text("hello")
  msg = ws.receive            # => URL::WebSocket::Message (text? / binary? / close?)
  puts msg.data
  ws.each { |m| handle(m) }   # iterate until the peer closes
end
```

A failed handshake is a **value, not a raise** — same two-tier model as
the HTTP verbs. `connect` always returns a `URL::WebSocket`; check
`ws.open?` and read `ws.error` (a `URL::TransferError`, e.g.
`URL::WebSocketError` naming the HTTP status when the server answered
with a page instead of a 101 upgrade). The block is only entered for a
live socket:

```ruby
ws = URL("wss://example.com/socket").connect
ws.open?   # => false
ws.error   # => #<URL::WebSocketError: websocket upgrade refused: server
           #    replied HTTP 200 (expected 101 Switching Protocols) ...>
```

Without a block, `connect` returns the socket and you close it yourself
(`ws.close(status: 1000)`). `#receive(timeout: 5.s)` returns `nil` if no
message arrives in time; `#send_*` / `#receive` on a closed socket are
no-ops returning `nil`. The C layer only adds two framing primitives
(`curl_ws_send` / `curl_ws_recv`); all message-level logic lives in
`mrblib/url/websocket.rb`. Only genuine usage errors raise: a non-ws
scheme, or a libcurl built without WebSocket support (needs 7.86+).

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
URL("https://example.com/ping").get   # attaches to the loop, returns nil
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
| `:timeout` | TIMEOUT_MS (chrono duration → ms) |
| `:connect_timeout` | CONNECTTIMEOUT_MS (chrono duration → ms) |
| `:ssl_verify_peer` | SSL_VERIFYPEER |
| `:ssl_verify_host` | SSL_VERIFYHOST |
| `:nobody` | NOBODY |
| `:connect_only` | CONNECT_ONLY |
| `:upload` | UPLOAD |
| `:mail_from` | MAIL_FROM |
| `:mail_rcpt` | MAIL_RCPT (Array) |
| `:post_fields` | COPYPOSTFIELDS (size from POSTFIELDSIZE_LARGE) |
| `:range` | RANGE |
| `:infilesize` | INFILESIZE_LARGE |
| `:dirlistonly` | DIRLISTONLY |
| `:ftp_create_dirs` | FTP_CREATE_MISSING_DIRS |
| `:use_ssl` | USE_SSL (`0`–`3`) |
| `:ssh_knownhosts` / `:ssh_private_keyfile` / `:ssh_public_keyfile` | SSH_KNOWNHOSTS / SSH_PRIVATE_KEYFILE / SSH_PUBLIC_KEYFILE |
| `:rtsp_request` / `:rtsp_stream_uri` / `:rtsp_transport` | RTSP_REQUEST / RTSP_STREAM_URI / RTSP_TRANSPORT |

Client TLS:

| Symbol | `CURLOPT_` |
| --- | --- |
| `:sslcert` / `:sslkey` / `:keypasswd` | SSLCERT / SSLKEY / KEYPASSWD |
| `:capath` | CAPATH |
| `:pinnedpublickey` | PINNEDPUBLICKEY |
| `:ssl_cipher_list` | SSL_CIPHER_LIST |
| `:sslversion` | SSLVERSION (curl integer enum) |

HTTP / proxy / network:

| Symbol | `CURLOPT_` |
| --- | --- |
| `:http_version` | HTTP_VERSION (curl integer enum: `2`=1.1, `3`=2, `30`=3) |
| `:cookie` | COOKIE (inline `"a=1; b=2"`) |
| `:unrestricted_auth` | UNRESTRICTED_AUTH |
| `:postredir` | POSTREDIR |
| `:proxyuserpwd` | PROXYUSERPWD |
| `:proxytype` | PROXYTYPE (curl integer enum) |
| `:httpproxytunnel` | HTTPPROXYTUNNEL |
| `:noproxy` | NOPROXY |
| `:interface` | INTERFACE |
| `:dns_servers` | DNS_SERVERS |
| `:doh_url` | DOH_URL |
| `:max_send_speed` / `:max_recv_speed` | MAX_SEND_SPEED_LARGE / MAX_RECV_SPEED_LARGE (bytes/s) |
| `:tcp_keepalive` / `:tcp_keepidle` / `:tcp_keepintvl` | TCP_KEEPALIVE / TCP_KEEPIDLE / TCP_KEEPINTVL |
| `:unix_socket_path` | UNIX_SOCKET_PATH |

Auth note: `auth:`/`bearer:`/`userpwd:` (Basic, Bearer) and `netrc:` are the
supported auth paths. NTLM and Digest are intentionally **not** exposed —
curl is removing NTLM (Sep 2026) and the local-crypto Digest fallback (Oct
2026); Basic + Bearer + TLS client certs are the durable options.

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
- **Connection / TLS session reuse across sessions** is wired through
  libcurl's `CURLSH`. One `URL::Libcurl::SHARE` is created per VM in
  `gem_init` and every `easy_init` attaches via `CURLOPT_SHARE`, so the
  shared session **and** any throwaway session (created when the shared
  one is busy mid-callback — see below) use one TCP-connection cache and
  one TLS-session-ticket cache. A request fired from inside a callback
  therefore resumes TLS (and often the live TCP/HTTP/2 connection) of
  the original session instead of doing a full handshake. We share
  `CONNECT` + `SSL_SESSION` only — `DNS`/`PSL` are auto-shared at the
  multi level, `COOKIE`/`HSTS` are documented thread-unsafe and we set
  them per-easy. Lock callbacks are deliberately unset; libcurl guards
  every cache use with `if(share->lockfunc)`, so unset is the cheap
  no-op for single-threaded mruby. Cleanup is a three-pass walk in
  `gem_final` — disarm callbacks, clean every easy/multi (each detaches
  itself from the share), then `curl_share_cleanup` — so the share is
  the last thing to go.
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

Every scheme libcurl is built with is exposed; further work is
protocol-specific conveniences as they come up (richer RTSP transport
negotiation, MQTT-over-WebSockets glue, FTP active-mode helpers, …),
plus whatever falls out of CI feedback on the less-exercised TLS variants.
The C surface is intentionally tiny and meant to stay that way — new
behaviour lives in `mrblib/` next to the existing dispatch.
