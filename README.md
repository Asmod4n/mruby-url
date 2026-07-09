# mruby-url

A URL client for mruby, backed by an embedded libcurl.

One small API covers every protocol your libcurl was built with — `http(s)`,
`ftp(s)`, `sftp`, `scp`, `file`, `dict`, `gopher(s)`, `pop3(s)`, `imap(s)`,
`smtp(s)`, `ldap(s)`, `mqtt(s)`, `rtsp`, `telnet`, `tftp`, `ws(s)` — with each
scheme exposing just the verbs that fit it.

```ruby
URL("https://example.com").get.body
URL("https://api.example.com/users").get(params: { limit: 10 }).json
URL("https://api.example.com/users").post(json: { name: "Alice" }).raise_for_status!.json

# Streaming a big response
URL("https://huge.example.com/file").get { |chunk| sink << chunk }

# Other protocols use the same shape
URL("ftp://host/pub/").list.lines
URL("sftp://host/path/big.bin").upload(File.open("big.bin", "rb"))
URL("imaps://user:pw@mail/INBOX").fetch(uid: 42).body
URL("wss://echo.websocket.org").connect { |ws| ws.send("hi"); puts ws.receive.data }
```

## What you get

- **Sensible defaults** — 30 s timeout, redirects followed, everything
  overridable per call.
- **Errors are values** — timeouts, DNS failures, TLS rejections and HTTP
  4xx/5xx land on the response (`resp.error`), never raised behind your back.
  Prefer exceptions? Chain `.raise_for_status!`.
- **JSON in and out** — `json:` request bodies; `resp.json`, lazy parsing, and
  typed deserialization straight into your own classes.
- **Uploads and downloads that stream** — pass a block to receive a response
  chunk by chunk; hand `upload` a String, IO, Enumerable, Proc or Fiber and it
  streams without buffering.
- **Multipart form posts** — `multipart:` builds `multipart/form-data`, with
  file parts streamed from disk.
- **Parallel fan-out** — register any number of transfers (any scheme, any
  verb) and drive them concurrently on one session, with per-response `retry`.
- **WebSockets** — `connect`, `send`, `receive`; fragmentation, PING/PONG and
  TEXT-vs-BINARY framing handled for you.
- **Fast repeat requests** — one shared session reuses connections, TLS
  sessions and HTTP/2 streams across calls.
- **Event-loop friendly** — verbs block by default, or plug the transfers into
  your own loop (glib, libuv, …) with a four-method adapter.

## Installation

Add the gem to your mruby `build_config.rb`:

```ruby
MRuby::Build.new do |conf|
  # ...
  conf.gem github: 'Asmod4n/mruby-url'
end
```

- **Linux / macOS** — needs the libcurl development files, found via
  `pkg-config` (`apt install libcurl4-openssl-dev`, `dnf install
  libcurl-devel`, or `brew install curl`). Everything else is an mrbgem and
  resolves automatically.
- **Windows** — no system libcurl required: the gem builds its vendored curl
  (the `deps/curl` submodule) with CMake and links it statically against
  Schannel, so clone with `--recursive` and have CMake on the PATH.

Which protocols are actually available at runtime depends on the libcurl the
gem was built against — check with `URL.supports?("sftp")` or `URL::PROTOS`.

## Status

Every scheme is implemented and covered by fixture-server integration tests.
The high-level API is settling toward a first tagged release.

> Cloned this repo before 2026-07-05? `main` was force-pushed around then —
> see [docs/history-rewrite.md](docs/history-rewrite.md) for how to re-sync.

## Documentation

- **[Usage guide](docs/usage.md)** — requests, responses, error handling,
  streaming, parallel transfers, the non-HTTP protocols, WebSockets.
- **[Options reference](docs/options.md)** — every `setopt` symbol and the
  `CURLOPT_`/`CURLMOPT_` it maps to, plus session tuning.
- **[Internals](docs/internals.md)** — design philosophy, connection/TLS
  sharing, event-loop integration, thread and fork rules.

Runnable examples live in [`examples/`](examples/) — an API tour, an
error-handling walkthrough, and a WebSocket demo.

## License

MIT
