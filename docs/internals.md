# Internals

How the gem is put together, and the advanced integration points.

## Design: C is an FFI-thin binding

The C layer (`src/`) does only what a generic FFI layer could do: call libcurl
functions, marshal primitive values across the boundary, register the
callbacks libcurl requires, and copy bytes between libcurl buffers and mruby
values. Everything else — dispatch, option/verb mapping, control flow,
per-transfer state, parsing, protocol behaviour, scheme handling — lives in
Ruby (`mrblib/`).

The reason is memory safety: hand-written C is the only place this gem can
have memory-safety bugs. Keeping C at FFI level keeps that surface near zero;
all the logic an attacker-controlled input could reach sits in memory-safe
Ruby. Concretely:

- C callbacks are store-only where possible (the socket and timer callbacks
  just record into plain C and let Ruby act afterwards) or a single bounded
  `memcpy` (the write callback). No business logic inside a callback.
- `setopt` is a flat symbol→`CURLOPT_*` pass-through; *which* options to set
  is decided in Ruby.
- New behaviour is added in Ruby by default; C changes only when libcurl's API
  can only be reached from C (e.g. a required callback function pointer), and
  then only the minimum glue.

## Sessions and re-entrancy

The high-level verbs reuse one shared session (`URL.shared`), so the
connection pool, TLS sessions and HTTP/2 streams persist across calls — repeat
requests to a host skip the handshake. See the
[options reference](options.md#tuning-the-shared-session) for tuning its pool.

That session drives one transfer at a time, so a call made from *inside* a
streaming block or parallel handler (where the session is mid-flight) would be
re-entrant. mruby-url detects that and transparently runs the nested call on a
throwaway session that **shares the same connection and TLS-session cache** —
a nested call to a host you already opened resumes TLS (and often reuses the
live connection) instead of doing a full handshake. This is transparent in
both directions; no API changes, no flags.

The cache sharing goes further: connections and TLS sessions are reused across
several mruby VMs running on the same OS thread.

## Event-loop integration

By default the verbs block on a built-in driver that rides libcurl's own
event-less multi API (`curl_multi_perform` + `curl_multi_poll`) — libcurl
tracks every fd and timeout internally, so nothing platform-specific runs in
Ruby. To drive transfers on a platform loop (glib, libuv, …) instead, subclass
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

or set it per session via `session.event_loop = my_loop`. Setting
`URL.default_loop = nil` restores the blocking mode (transfers already
attached to the old loop finish on it).

WebSockets ride the same loop: with a default loop installed,
`URL("wss://…").connect` returns a `connecting?` socket immediately, the
handshake is driven as a loop-attached transfer, and messages flow through
`on_message` — see the [usage guide](usage.md#evented-websocket). Internally
the handshake request stays attached to its session's multi for the socket's
whole life (`Request#on_complete(detach: false)`) because removing a
CONNECT_ONLY easy from its multi severs the established connection; the
socket detaches it at teardown.

Completion notification is per-request: `Request#on_complete` fires once with
the transfer's CURLcode when the session's event-loop reap sees it finish —
that's the hook the evented WebSocket (and anything else that needs to know a
loop-driven transfer ended) builds on.

### Driving a session by hand

`URL::IOSelectLoop` is the reference `EventLoop` implementation — the
blocking verbs don't use it (they ride libcurl's `curl_multi_perform`/`poll`
directly), it exists as the example of what an integration must provide:
store the fds and timer the session asks for, and fire the blocks it handed
you when they're ready. Nothing else; `socket_action`, completion reaping and
timeout bookkeeping all live in the session, so every integration gets them
for free.

```ruby
session = URL.open
loop    = URL::IOSelectLoop.new
session.event_loop = loop

req = URL::Request.new(session, "https://example.com")
req.on_data { |chunk| sink(chunk) }
session.add(req)
session.socket_action   # kick off: registers fds/timers with the loop

loop.run                # pumps IO.select, firing the session's blocks,
                        # until nothing is watched and no timer is armed
```

A real platform loop has no `run` of its own to call — its host application's
loop plays that role; it only implements `watch`/`unwatch`/`arm_timer`/
`cancel_timer` exactly as `IOSelectLoop` does. Note that several sessions can
share one loop (every fire-and-forget verb opens its own), so `arm_timer` must
track one timer per call, not a single slot.

Runnable tour of all three shapes — fire-and-forget verbs, evented WebSocket,
hand-driven session: [`examples/event_loop.rb`](../examples/event_loop.rb).

## Threads and processes

Two rules to stay safe:

- **Keep each `mrb_state` and its requests on one OS thread.** Don't drive a VM
  from a different thread than the one it was created on (the same single-owning
  -thread rule mruby itself imposes on an `mrb_state`).
- **Don't `fork()` after a request and then use the gem in the child** — libcurl
  isn't fork-safe; the child inherits the parent's live sockets.

## Dependencies

- `mruby-io` — `IO.select`, `IO.for_fd`
- `mruby-error` — `mrb_protect_error`
- `mruby-uri-parser` — ada-url-based URL handling (WHATWG-compliant)
- `mruby-fast-json` — simdjson-backed JSON, with `native_ext_type` schemas
- `mruby-chrono` — duration literals (`30.s`, `500.ms`), lossless seconds→ms
- `mruby-c-ext-helpers`
- `mruby-socket`
- `mruby-string-ext` — `String#byteslice` for Ruby-side upload chunking
- `mruby-string-is-utf8` — `String#is_utf8?` for WebSocket TEXT/BINARY framing

On Linux/macOS the gem finds libcurl via `pkg-config`. On Windows it builds
the vendored `deps/curl` with CMake and links it statically against Schannel
(no OpenSSL); `mrbgem.rake` handles this.

## Roadmap

Every scheme libcurl is built with is exposed; further work is
protocol-specific conveniences as they come up (richer RTSP transport
negotiation, MQTT-over-WebSockets glue, FTP active-mode helpers, …),
plus whatever falls out of CI feedback on the less-exercised TLS variants.
