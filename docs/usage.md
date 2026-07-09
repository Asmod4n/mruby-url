# Usage guide

- [Calling URL](#calling-url)
- [Defaults](#defaults)
- [Convenience kwargs](#convenience-kwargs)
- [Response](#response)
- [Error handling](#error-handling)
- [Streaming](#streaming)
- [Parallel fan-out](#parallel-fan-out)
- [Retrying failed responses](#retrying-failed-responses)
- [Other protocols](#other-protocols)
- [SMTP(S)](#smtps)
- [IMAP(S)](#imaps--fetch--move--store--expunge)
- [Upload sources](#upload-sources)
- [WebSocket](#websocket)

## Calling URL

`URL(uri)` dispatches on the scheme and returns a **per-protocol class** — one
per scheme: `URL::HTTP`/`URL::HTTPS`, `URL::FTP`/`URL::FTPS`, `URL::SFTP`,
`URL::SCP`, `URL::FILE`, `URL::TFTP`, `URL::TELNET`, `URL::GOPHER`/`URL::GOPHERS`,
`URL::DICT`, `URL::IMAP`/`URL::IMAPS`, `URL::POP3`/`URL::POP3S`,
`URL::SMTP`/`URL::SMTPS`, `URL::LDAP`/`URL::LDAPS`, `URL::MQTT`/`URL::MQTTS`,
`URL::RTSP`, `URL::WS`/`URL::WSS`. Protocols that share an operation shape share
a parent they subclass: the whole ftp/ssh/file family subclasses
`URL::Transfer` (`download`/`upload`/`list`), and each TLS variant subclasses
its plaintext base (`URL::HTTPS < URL::HTTP`, `URL::FTPS < URL::Transfer`, …).
Each class carries only the verbs that fit the protocol.

A per-protocol class exists **only when this libcurl was built with that
protocol** — mirroring libcurl, where an unbuilt scheme has no handler at all.
So on a build without an SSH backend `URL::SFTP` simply doesn't exist
(referencing it is a `NameError`), and `URL("sftp://…")` raises
`URL::ProtocolNotAvailable` from `URL(uri)` itself — no wrapper is constructed
for a protocol the build can't use, so the failure surfaces immediately, not
later at a verb. A scheme the gem doesn't know at all raises
`URL::UnsupportedScheme`. Both descend from `URL::SchemeError` (itself a
`URL::Error`) and carry the offending `.scheme` plus the `.supported` protocol
list, so a handler can branch on data instead of scraping the message. Check
ahead of time with `URL.supports?("scheme")` or against `URL::PROTOS`.

```ruby
# Build once, call repeatedly:
api = URL("https://api.example.com/users")
api.get(params: { limit: 10 })
api.post(json: payload)

# One-shot class method when you know the scheme up front, no factory:
URL::HTTPS.get("https://x", json: {...})
URL::SFTP.upload("sftp://h/path", io)         # ftp(s) / sftp / scp / file / tftp / telnet share URL::Transfer's verbs
URL::IMAPS.fetch("imaps://h/INBOX", uid: 7)
URL::WSS.connect("wss://h/sock") { |ws| ws.send("hi") }
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

These high-level kwargs are **owned per scheme** — each wrapper defines its own
set, nothing is shared. The table below is the **HTTP** set. Other schemes own a
subset: the `Transfer`/`GOPHER`/`DICT`/`POP3`/`LDAP`/`MQTT`/`RTSP`/`WS` wrappers
take `params`/`headers`; `IMAP` and `SMTP` take none (their inputs are explicit
verb arguments). Passing a high-level kwarg a scheme doesn't own raises
`ArgumentError` up front — no silent no-op, no cryptic libcurl error. Raw
`curl_easy` options are *not* high-level kwargs: they always pass through to
`setopt`, which validates them against libcurl regardless of scheme — either as
top-level keys or, explicitly, via the `setopt:` escape hatch (see below).

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
| any `curl_easy` opt | `proxy`, `cookiefile`, `cookiejar`, `verbose`, `ssl_verify_peer`, `userpwd`, … (see the [options reference](options.md)). |
| `setopt: { ... }` | Explicit escape hatch for the long tail of `curl_easy` options not surfaced by name. Each pair goes straight to `URL::Request#setopt`, merged **last** so an explicit `setopt:` value wins over the same option set as a top-level key. |

```ruby
# multipart/form-data (curl_mime): String = field, Hash = file part (streamed from disk)
URL("https://api.example.com/upload").post(multipart: {
  "title"  => "vacation",
  "avatar" => { file: "pic.png", type: "image/png" },
})
```

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

## Error handling

There are two kinds of failure, and they behave differently:

- **Usage mistakes** — an unbuilt/unknown scheme, a kwarg the scheme doesn't
  own — **raise** immediately (a `URL::Error` subclass). They're bugs in your
  calling code.
- **Transfer failures** — anything that goes wrong once libcurl is running:
  timeout, DNS, refused connection, TLS rejection, *and* an HTTP status `>= 400`
  — are returned as **values**. Nothing is raised for you.

So every response you get back must be checked: `resp.error` is `nil` on a clean
success, or an exception object describing what failed. Check it (or `resp.error?`,
or a status predicate) before trusting the body.

```ruby
resp = URL("https://api.example.com/data").get

if resp.error
  warn "request failed: #{resp.error.class} — #{resp.error.message}"
else
  use(resp.json)
end
```

`resp.error` is a real exception object you can inspect or raise yourself — it
just isn't raised *for* you:

- Transport failures map to one class per libcurl error, all under
  `URL::TransferError` (e.g. `URL::OperationTimedout`, `URL::CouldntConnect`,
  `URL::PeerFailedVerification`); each carries `#curl_code`, `#curl_message` and
  `#response`. Where mruby already ships the right class it's reused — a DNS
  failure comes back as `SocketError`, so `rescue SocketError` just works.
- An HTTP status `>= 400` is a value too: `resp.error` is a
  `URL::HttpReturnedError` (with `#response`), and `resp.client_error?` /
  `resp.server_error?` tell you which band.

Dispatch on it with `case`/`when`:

```ruby
case resp.error
when nil                    then use(resp.json)
when URL::HttpReturnedError then retry_or_log(resp.code)
when URL::OperationTimedout then back_off
when SocketError            then mark_host_down
when URL::TransferError     then warn "curl #{resp.error.curl_code}"
end
```

Prefer exceptions? `raise_for_status!` opts in — it raises whatever `resp.error`
holds (HTTP *or* transport) and otherwise returns `self`, so it chains:

```ruby
data = URL("https://api.example.com/data").get.raise_for_status!.json
```

This is uniform across the whole gem: the same `resp.error` value model applies
to every verb, every protocol, and each `URL::Response` a parallel handler receives
— one failing request never derails the others. (Runnable tour:
`examples/error_handling.rb`.)

## Streaming

Pass a block to a one-shot to receive body chunks as they arrive instead of
buffering. Useful for big downloads, video, LLM token streams.

```ruby
URL("https://huge.example/file").get do |chunk|
  File.open("out", "ab") { |f| f.write(chunk) }
end
```

`response.body` is empty in that case — you handled it.

Calling a verb from *inside* a streaming block (or any handler) just works —
the nested call transparently runs on a session that shares the outer one's
connection and TLS caches, so it stays warm. Details in
[internals](internals.md#sessions-and-re-entrancy).

```ruby
URL("https://a.example/stream").get do |chunk|
  enrich(chunk, URL("https://b.example/lookup").get.json)
  log(URL("https://a.example/meta").get.json)   # warm — same host as the outer call
end
```

## Parallel fan-out

Register transfers with `parallel(:verb, ...)` — any scheme, any verb the
scheme's wrapper has, with the verb's normal arguments — then drive them all
concurrently on one session with `URL.parallel_perform` (connection pool, TLS
sessions and HTTP/2 multiplexing all carry over). Registration runs no I/O;
each transfer's resolved `URL::Response` is passed to the block it was
registered with, as it completes:

```ruby
URL("https://a.example/feed").parallel(:get)                 { |r| feed  = r.json }
URL("https://b.example/login").parallel(:post, json: creds)  { |r| token = r }
URL("ftp://h/manifest.txt").parallel(:download)              { |r| manifest = r.body }
URL("imaps://h/INBOX").parallel(:fetch, uid: 1)              { |r| mail  = r.body }

URL.parallel_perform   # pure driver, returns nothing — the handler blocks are
                       # where the Responses arrive, as each transfer lands
```

The class-level form mirrors it: `URL::HTTPS.parallel("https://x", :get) { |r| ... }`.

Usage errors raise at registration, before any I/O — a verb the scheme
doesn't have, an unknown scheme, a protocol this libcurl wasn't built with.
WebSocket `connect` can't be registered (it returns a live socket, not a
`Response`) and raises `ArgumentError`. Runtime failures stay values
(`resp.error` on the delivered Response), exactly like the blocking verbs; a
verb called from inside a handler runs immediately on a throwaway session,
the same re-entrancy rule as everywhere else.

## Retrying failed responses

Every **failed** `URL::Response` can redo its request with `retry` — same
URL, verb and arguments. A blocking verb's Response re-runs right there and
returns the fresh Response; a parallel Response resubmits its transfer (with
the same handler) for the *next* perform — and can do so **only inside its
handler block**, the one place a parallel Response exists:

```ruby
r = URL("https://x").get
r = r.retry(3) if r.error                 # blocking: up to 3 immediate re-runs,
                                          # stops on success, returns the last Response

URL("https://x").parallel(:get) do |r|
  r.retry(3) if r.error                   # parallel: budget rides with the transfer
end
URL.parallel_perform                      # one call — retries run as extra rounds;
                                          # after 3 resubmissions retry returns false
                                          # and the perform drains
```

`times` defaults to 1. `wait:` sets the pause before each re-run (any chrono
duration or seconds — `500.ms`, `2.s`). When omitted, the server decides:
429/503 responses often carry a `Retry-After` header, libcurl parses it
(exposed as `resp.retry_after`, in seconds, `nil` when absent), and the retry
waits exactly that long — no header, no wait. `retry` is for failures only —
on a Response whose `error` is nil it raises `URL::Error`, and so does
retrying a parallel Response after its handler has returned.

## Other protocols

Every scheme `URL::PROTOS` lists is reachable, and transfer failures are values
(`resp.error`), exactly like the HTTP verbs. A scheme this libcurl wasn't built
with raises `URL::ProtocolNotAvailable`, and one the gem doesn't know raises
`URL::UnsupportedScheme` (both `URL::SchemeError`/`URL::Error`), straight from
`URL(uri)` before any wrapper exists; only failures *during* a transfer come
back as values.

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
`ssl_verify_peer:`/`ssl_verify_host:` as usual.

### Supported schemes

```ruby
URL::PROTOS            # => ["dict","file","ftp","ftps","gopher","gophers",
                       #     "http","https","imap","imaps","ldap","ldaps",
                       #     "mqtt","mqtts","pop3","pop3s","rtsp","scp",
                       #     "sftp","smtp","smtps","telnet","tftp","ws","wss"]
URL.supports?("smtps") # => true / false
```

## SMTP(S)

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

## IMAP(S) — `fetch` / `move` / `store` / `expunge`

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

## Upload sources

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
automatically. `send` picks the frame type from the payload itself:
valid UTF-8 goes out as a TEXT frame, anything else as BINARY — which is
exactly the distinction the wire format draws (RFC 6455 §5.6), so there
is nothing to choose.

```ruby
URL("wss://echo.websocket.org").connect do |ws|
  ws.send("hello")
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
no-ops returning `nil`. Only genuine usage errors raise: a non-ws scheme, or a
libcurl built without WebSocket support (needs 7.86+).
