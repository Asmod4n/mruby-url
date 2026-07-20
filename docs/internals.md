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

## The one event loop

There is exactly one event loop model in this gem, always: `URL.default_loop`,
a `URL::EventLoop`. Every blocking-looking call — a verb, a
`URL.parallel_perform`, a `WebSocket#receive`/`#send`, a retry pause —
registers with it and calls its `run_once` repeatedly until its own
registration completes. While any one call waits, every other in-flight
transfer and open websocket registered on the *same* loop keeps progressing
too, since `run_once` services all of them together, not just the caller's
own. Async under the hood, synchronous to the caller — nothing is driven any
other way, and there is no separate internal mechanism hidden behind it.

Unless you set `URL.default_loop=`, that loop is a `URL::IOSelectLoop`
(`mrblib/url/io_select_loop.rb`) — ordinary, public, IO.select-based, ships
with the gem, and is the exact class you'd read to write your own (see
[Event-loop integration](#event-loop-integration) below).

The one exception, forced by libcurl itself: a call made from *inside* a
libcurl C callback (a streaming block) cannot register more work on that
same multi and wait — the C stack frame that invoked the callback is
synchronously blocked on the Ruby call returning, so no event loop, built-in
or yours, can get around it. That case transparently drives a throwaway
session on a private, throwaway loop instead — see
[Sessions and re-entrancy](#sessions-and-re-entrancy).

## Sessions and re-entrancy

The high-level verbs reuse one shared session (`URL.shared`), so the
connection pool, TLS sessions and HTTP/2 streams persist across calls — repeat
requests to a host skip the handshake. See the
[options reference](options.md#tuning-the-shared-session) for tuning its pool.

A call made from *inside* a parallel handler (or any other completion block)
just pumps the same loop — same session, same warm connection pool. The one
place that can't is a call made from inside a **streaming block**: those run
inside a libcurl C callback, and a multi must never be re-entered from its
own callbacks. mruby-url detects that and transparently runs the nested call
on a throwaway session that **shares the same connection and TLS-session
cache** — a nested call to a host you already opened resumes TLS (and often
reuses the live connection) instead of doing a full handshake. This is
transparent in both directions; no API changes, no flags.

The cache sharing goes further: connections and TLS sessions are reused across
several mruby VMs running on the same OS thread.

## Event-loop integration

`URL.default_loop` is what every verb, parallel batch, websocket and retry
pause already drives through — there's no separate "internal" mode to escape
from. To drive transfers on a platform loop (glib, libuv, an io_uring/kqueue
wrapper, a game engine's frame loop, …) instead of the built-in
`URL::IOSelectLoop`, subclass `URL::EventLoop` and implement five primitives:

```ruby
class URL::EventLoop
  def watch(io, readiness, &block)   # readiness: :in / :out / :inout — start watching io
  def unwatch(handle)                # handle is whatever watch returned
  def arm_timer(delay, &block)       # call block.() once, after `delay` (a chrono duration)
  def cancel_timer(handle)
  def run_once(timeout = nil)        # process one round of readiness/timer events,
                                      # waiting up to `timeout` (nil: indefinitely; 0: don't block)
end
```

`watch`/`unwatch`/`arm_timer`/`cancel_timer` are exactly what any event loop
already has: register interest, get told when it's ready. `run_once` is the
same "process one round" step every one of those already exposes too
(`g_main_context_iteration`, `uv_run(UV_RUN_ONCE)`, a game engine's own
per-frame poll) — implement it in terms of whatever your loop already does to
advance itself once. Every wait in this gem is `loop.run_once until condition`
— there is no other driving mechanism to implement, and nothing here is
specific to sockets-via-select: how you actually wait (select, poll, kqueue,
epoll, io_uring, a GUI toolkit's own fd-watching) is entirely yours.

Install one instance process-wide — every verb keeps working exactly the
same way, driven by your `run_once` instead:

```ruby
URL.default_loop = MyGlibLoop.new
URL("https://example.com/ping").get   # a real URL::Response, driven by MyGlibLoop
```

or set it per session via `session.event_loop = my_loop` (a session picks up
`URL.default_loop` lazily, the first time it needs one, and stays pinned to
whatever that was for its own lifetime — set it explicitly to override).

### Driving a session by hand

`URL::IOSelectLoop` is the reference `EventLoop` implementation *and* the
literal default — nothing about it is special-cased anywhere else in the
gem. `add`/`socket_action`, completion reaping, and timeout bookkeeping all
live in the session, so every integration gets them for free; your loop only
ever needs to store the fds/timer it's asked to watch and fire the blocks it
was handed when they're ready.

```ruby
session = URL.open
loop    = URL::IOSelectLoop.new
session.event_loop = loop

req = URL::Request.new(session, "https://example.com")
req.on_data { |chunk| sink(chunk) }
code = nil
session.add(req) { |c| code = c }   # kicks off the first drive pass itself

loop.run_once until code   # the "boring" blocking-helper pattern any async
                           # loop supports: keep processing rounds until
                           # your own condition holds
```

A real platform loop's host application is usually already running its own
loop, in which case nothing above changes — `run_once` composes the same way
whether you're calling it yourself in a tight loop or your GUI toolkit is
calling it as part of its own frame/dispatch cycle.

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

On Linux/macOS the gem finds libcurl via `pkg-config`; if that fails, the
build stops right there with the install command for your platform — this
gem never builds its own curl outside of Windows. Windows has no system
libcurl to look for, so it always builds the vendored `deps/curl` with CMake
and links it statically against Schannel (no OpenSSL); `mrbgem.rake` handles
this.

## Roadmap

Every scheme libcurl is built with is exposed; further work is
protocol-specific conveniences as they come up (richer RTSP transport
negotiation, MQTT-over-WebSockets glue, FTP active-mode helpers, …),
plus whatever falls out of CI feedback on the less-exercised TLS variants.
