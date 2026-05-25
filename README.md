STATUS
======

This gem is still in the design phase and isn't ready to be used yet.

# mruby-url

URL session for mruby. Backed by libcurl, with a high-level HTTP client on
top and a small integration class for real event loops.

```ruby
URL.get("https://example.com").body                # quick
URL.get("https://api.example.com/users", params: { limit: 10 }).json
URL.post("https://api.example.com/users", json: { name: "Alice" }).raise_for_status!.json
URL.parallel(["https://a.example", "https://b.example"])

URL.get("https://huge.example.com/file") { |chunk| File.open("out", "ab") { |f| f.write(chunk) } }
```

Why "URL"? Because libcurl works on URLs across protocols. HTTP is the first
thing we expose; SMTP, FTP, SFTP, IMAP, MQTT, WebSocket and friends will
slot in under the same top-level class as `URL.send_mail`, `URL.upload`,
etc.

## Defaults

Every one-shot call gets these unless you override them:

- `timeout_ms: 30_000` — prevents indefinite hangs
- `follow_location: true` — HTTP redirects followed
- `user_agent: "mruby-url"`
- `accept_encoding: ""` — libcurl advertises gzip/deflate/br/zstd and decompresses

## Convenience kwargs

| kwarg | what it does |
| --- | --- |
| `params: { ... }` | Appended to the URL as a query string (URI.encode, WHATWG-strict). Array values expand to repeated keys. |
| `json: <obj>` | Body is `JSON.dump(obj)`; auto Content-Type and Accept of `application/json`. |
| `form: { ... }` | Body is `application/x-www-form-urlencoded`; Content-Type set accordingly. |
| `auth: "user:pass"` or `["user", "pass"]` | Basic auth via `CURLOPT_USERPWD` (libcurl builds the header). |
| `bearer: "<token>"` | Adds `Authorization: Bearer <token>` (user headers override). |
| `headers: { ... }` | Extra headers. Wins over anything we auto-set. |
| any curl_easy opt | `timeout_ms`, `proxy`, `cookiefile`, `cookiejar`, `verbose`, `ssl_verify_peer`, `userpwd`, etc. |

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
`mrb_iv_set` doesn't care what shape the receiver has, the target can be:

```ruby
class Config
  attr_accessor :api_key, :region
  native_ext_type :@api_key, String
  native_ext_type :@region,  String
end

# Instance — fill an existing object
config = Config.new
URL.get(".../config").into(config)

# Class — populate class-level @api_key / @region
URL.get(".../config").into(Config)

# Module — same idea, on a module
URL.get(".../flags").into(FeatureFlags)
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

## Parallel

```ruby
results = URL.parallel(["https://a.example", "https://b.example"])
results["https://a.example"].code   # => 200
```

Result hash is keyed by the exact value you passed (String, URI, anything).
All transfers share libcurl's connection pool on the shared session.

## Tuning the shared session

`URL.shared` is the process-wide session (per mrb_state). Tune it once at
startup:

```ruby
URL.shared.setopt(:pipelining,             2)        # HTTP/2 multiplexing
URL.shared.setopt(:max_concurrent_streams, 100)
URL.shared.setopt(:max_total_connections,  256)
```

You can replace its event loop:

```ruby
URL.shared.event_loop = MyGlibLoop.new(URL.shared, ctx)
```

The shorthand is not re-entrant on the shared session: don't call
`URL.get` from inside an `on_data` callback that fired from the same
session.

## Integrating a real event loop

`URL::EventLoop` defines exactly the two methods libcurl needs:

```ruby
class URL::EventLoop
  def on_socket(fd, what)   # :in / :out / :inout / :remove
  def on_timer(ms)          # ms < 0 means cancel
end
```

Subclass, implement those two methods on top of your loop, hand an instance
to `URL#event_loop=`. Your loop's job, when an fd it's watching becomes
ready, is to call back into the session:

```ruby
session.socket_action(fd, :in)            # or :out / :inout / :err
session.info_read { |req, code| ... }     # drain completions

# When your scheduled timer fires:
session.socket_action                     # no args = timeout case
session.info_read { |req, code| ... }
```

`example/glib_event_loop.rb` is a complete sketch.

`URL::IOSelectLoop` is the built-in `EventLoop` subclass used by the
shorthand. You can use it directly if you want IO.select but custom
orchestration:

```ruby
session = URL.open
loop    = URL::IOSelectLoop.new(session)
session.event_loop = loop

req = URL::Request._open("https://example.com")
session.add(req)
loop.run do |r, code|
  # one call per completion
end
```

## Options reference

### `URL#setopt` (1:1 with `curl_multi_setopt`)

| Symbol | CURLMOPT_ | Notes |
| --- | --- | --- |
| `:pipelining` | PIPELINING | bitmask; `2` (CURLPIPE_MULTIPLEX) for HTTP/2 |
| `:maxconnects` | MAXCONNECTS | connection-cache size |
| `:max_host_connections` | MAX_HOST_CONNECTIONS | per-origin cap (HTTP/1.1) |
| `:max_total_connections` | MAX_TOTAL_CONNECTIONS | global cap |
| `:max_concurrent_streams` | MAX_CONCURRENT_STREAMS | HTTP/2 client-side |

### `URL::Request#setopt` (1:1 with `curl_easy_setopt`)

| Symbol | CURLOPT_ |
| --- | --- |
| `:url` | URL |
| `:custom_request` | CUSTOMREQUEST |
| `:user_agent` | USERAGENT |
| `:cainfo` | CAINFO |
| `:accept_encoding` | ACCEPT_ENCODING |
| `:userpwd` | USERPWD |
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
| `:post_fields` | COPYPOSTFIELDS (size from POSTFIELDSIZE_LARGE) |

Headers: pass `:headers => { ... }` to either a one-shot or `Request#headers=`.

## Dependencies

- `mruby-io` — `IO.select`, `IO.for_fd`
- `mruby-error` — `mrb_protect_error`
- `mruby-uri-parser` — ada-url-based URL handling (WHATWG-compliant)
- `mruby-fast-json` — simdjson-backed JSON, with `native_ext_type` schemas

## Design notes

- `URL::Request` is private (`#initialize` undef'd; `_open` factory). The
  shorthand uses it internally without surfacing the class. If you get a
  Request back from `info_read` during real-event-loop work you can call
  `#response_code`, `#effective_url`, `#total_time`, `#content_type`,
  `#setopt`, `#headers=`, `#on_data`, `#on_header` on it.
- Per-transfer state lives in `URL::TransferState`, not on the Request.
- Users never touch ivars. Every interaction is a real method call.
  `URL#event_loop=` and `Request#on_data` / `#on_header` are the only
  surface for "plug a callback in".
- The C side never `longjmp`s through libcurl: every Ruby callback runs
  under `mrb_protect_error`, the first exception is stashed on
  `mrb->exc`, the callback returns the libcurl abort code, and
  `murl_session_check` re-raises that exception on the way back to Ruby.
- `IO.for_fd` runs with `autoclose = false` everywhere we touch
  libcurl-owned fds. libcurl owns those fd lifecycles; we must not close.
- The shorthand methods reuse one shared session per mrb_state
  (`URL.shared`) so libcurl's connection pool, TLS sessions, and HTTP/2
  stream reuse persist across calls.
- Redirect chains: parsed `Response#headers` keeps only the final response.
  The full sequence stays in `#raw_headers`.

## Future

Everything libcurl can do is in scope here. HTTP is the first protocol;
SMTP, FTP, SFTP, IMAP, MQTT, WebSocket, TFTP, dict, telnet, Gopher all
slot in over time. The class is `URL` because URLs are what they all have
in common.
