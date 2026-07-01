# examples/api_tour.rb
#
# A guided tour of the ENTIRE public mruby-url API — every class, verb, kwarg
# and Response accessor a user is meant to touch, in one place. Nothing here
# reaches into internals (no URL::Libcurl, no event-loop plumbing, no _helpers);
# if it is shown below, it is public and supported.
#
# Most snippets are illustrative rather than executed — they document shape and
# intent. The few live calls target an httpbin-style server; pass its base URL
# as the first argument (defaults to a local one):
#
#     mruby examples/api_tour.rb http://localhost:8080
#
# A local httpbin (offline, deterministic):
#
#     podman run --rm -p 8080:8080 docker.io/mccutchen/go-httpbin:latest
#
# The golden rule, restated everywhere below:
#   * USAGE mistakes (unsupported/unbuilt scheme, wrong kwarg) RAISE at the call.
#   * TRANSFER failures (timeout, DNS, TLS, refused, HTTP >= 400) are VALUES —
#     resp.error holds the exception; nothing is raised unless you ask.

BASE = ARGV[0] || "http://localhost:8080"

def section(title)
  puts "\n== #{title} =="
end

# ---------------------------------------------------------------------------
section "1. Constructing — URL(uri) and the per-protocol classes"
# ---------------------------------------------------------------------------
# URL(uri) dispatches on the scheme and returns the class for that protocol.
# Each scheme has its own class; classes that share an operation shape share a
# parent (URL::HTTPS < URL::HTTP, every ftp/ssh/file scheme < URL::Transfer).
api = URL("#{BASE}/get")          # => a URL::HTTP (or URL::HTTPS for https)
puts "wrapper class: #{api.class}"

# A class exists ONLY when this libcurl was built with its protocol. Probe
# before you leap — URL.supports? and the full list in URL::PROTOS.
puts "https built? #{URL.supports?('https')}"
puts "protocols:   #{URL::PROTOS.join(' ')}"

# An unbuilt protocol raises from URL(uri) itself (no wrapper is made); an
# unknown scheme raises too. These are specific URL::SchemeError subclasses —
# URL::UnsupportedScheme (unknown) and URL::ProtocolNotAvailable (real protocol,
# not compiled in) — each carrying the offending .scheme and the .supported list,
# so you can branch on data, not scrape the message. Both are still URL::Error.
begin
  URL("zzz://nowhere")
rescue URL::SchemeError => e
  puts "#{e.class}: scheme=#{e.scheme.inspect}"
  puts "  #{e.message}"
end

# ---------------------------------------------------------------------------
section "2. HTTP verbs — instance form and one-shot class form"
# ---------------------------------------------------------------------------
# Build once, call repeatedly (the @uri rides on the instance):
ep = URL("#{BASE}/anything")
ep.get
ep.head
ep.options
ep.post(json: { a: 1 })
ep.put("raw body")
ep.patch(json: { b: 2 })
ep.delete

# One-shot class methods when you know the scheme up front — no factory:
URL::HTTP.get("#{BASE}/get")
URL::HTTP.post("#{BASE}/post", json: { hi: true })
# (URL::HTTPS.get(...) is the same thing for TLS.)
r = URL("#{BASE}/get").get
puts "GET ok? #{r.success?} code=#{r.code}"

# ---------------------------------------------------------------------------
section "3. Request kwargs — the high-level conveniences"
# ---------------------------------------------------------------------------
# params:  appended as a query string (WHATWG-strict; Array -> repeated keys)
URL("#{BASE}/get").get(params: { q: "ruby", tags: %w[a b] })

# json:    body is JSON.dump(obj); sets Content-Type + Accept application/json
URL("#{BASE}/post").post(json: { name: "Alice", roles: [1, 2] })

# form:    application/x-www-form-urlencoded
URL("#{BASE}/post").post(form: { user: "alice", remember: true })

# multipart: multipart/form-data via curl_mime. String => plain field; Hash =>
# a file/blob part (file: streams from disk, never buffered in Ruby; data: is an
# in-memory blob; filename:/type: set the part headers).
URL("#{BASE}/post").post(multipart: {
  "field"  => "plain value",
  "upload" => { data: "bytes\n", filename: "n.txt", type: "text/plain" },
  # "avatar" => { file: "/path/pic.png", type: "image/png" },
})

# auth/bearer:  Basic auth (string "user:pass" or [user, pass]) or a Bearer token
URL("#{BASE}/basic-auth/u/p").get(auth: "u:p")
URL("#{BASE}/bearer").get(bearer: "secret-token")

# headers:  extra request headers; win over anything auto-set
URL("#{BASE}/headers").get(headers: { "X-Trace" => "abc", "Accept" => "text/plain" })

# timeouts:  one duration-based API (mruby-chrono). Any unit, lossless to ms.
URL("#{BASE}/delay/0").get(timeout: 5.s, connect_timeout: 2.s)   # 500.ms, 2.min, …

# redirects followed by default; turn off per call:
URL("#{BASE}/redirect/2").get(follow_location: false)

# ---------------------------------------------------------------------------
section "4. Request kwargs — raw curl options and the setopt: escape hatch"
# ---------------------------------------------------------------------------
# Any curl_easy option that applies to the scheme is a kwarg too — passed as a
# top-level key, validated by libcurl:
URL("#{BASE}/get").get(accept_encoding: "", verbose: false, user_agent: "tour/1")

# setopt: { ... } is the explicit escape hatch for the long tail of options not
# surfaced by name; its pairs go straight to setopt, merged LAST so an explicit
# setopt: wins over the same option set by name.
URL("#{BASE}/get").get(setopt: { user_agent: "raw-wins" })

# ---------------------------------------------------------------------------
section "5. The Response object"
# ---------------------------------------------------------------------------
resp = URL("#{BASE}/get").get
# Status:
resp.code            # numeric, e.g. 200    (alias: resp.status)
resp.success?        # 2xx
resp.informational?  # 1xx
resp.redirect?       # 3xx
resp.client_error?   # 4xx
resp.server_error?   # 5xx
resp.error?          # transport failure or status >= 400
# Body + headers:
resp.body                         # raw String
resp.headers                      # { "content-type" => ..., "set-cookie" => [...] }
resp["Content-Type"]              # case-insensitive single header
resp.content_length               # Integer or nil
resp.content_type                 # from the transfer
resp.lines                        # body split into lines (handy for list/dir output)
# Named header shortcuts:
resp.location; resp.server; resp.date; resp.etag
resp.last_modified; resp.cache_control; resp.transfer_encoding; resp.content_encoding
# JSON (only meaningful on a real JSON body — guard so the tour runs offline):
if resp.success?
  resp.json                       # JSON.parse(body), cached
  resp.json_lazy                  # JSON::Document (zero-copy), cached
  # resp.into(SomeClass)          # mruby-fast-json native deserialization into a target
end
# Transfer metadata:
resp.effective_url                # final URL after redirects
resp.total_time                   # seconds
puts "url=#{resp.effective_url} time=#{resp.total_time}s type=#{resp.content_type}"

# ---------------------------------------------------------------------------
section "6. Errors — values by default, raise on demand"
# ---------------------------------------------------------------------------
# A transport failure is a value: resp.error holds the matching exception.
timed = URL("#{BASE}/delay/5").get(timeout: 100.ms)
if timed.error
  puts "error value: #{timed.error.class} (curl #{timed.error.curl_code})"
  # It is a URL::TransferError subclass (here URL::OperationTimedout); a DNS
  # failure comes back as the built-in SocketError so `rescue SocketError` works.
end

# An HTTP error status is also a value — resp.error is a URL::HttpReturnedError:
bad = URL("#{BASE}/status/500").get
puts "500 error? #{bad.error?}  error=#{bad.error.class}"

# Opt in to raising with raise_for_status! (raises whatever resp.error holds —
# a URL::HttpReturnedError for a bad status, or the transport error otherwise):
begin
  URL("#{BASE}/status/404").get.raise_for_status!
rescue URL::Error => e
  puts "raised: #{e.class}"
end

# rescue the whole family with URL::TransferError; rescue URL::Error to also
# catch usage mistakes. You can always raise a value yourself: `raise resp.error`.

# ---------------------------------------------------------------------------
section "7. Streaming — download by block, upload from any source"
# ---------------------------------------------------------------------------
# Pass a block to a GET/download verb to stream the body chunk-by-chunk instead
# of buffering it (the Response body is then empty):
total = 0
URL("#{BASE}/stream/3").get { |chunk| total += chunk.bytesize }
puts "streamed #{total} bytes"

# Uploads accept any of: a String, an IO (File/StringIO — streamed, never fully
# buffered), a Proc/Method (call(max) -> chunk), a Fiber (resume(max) -> chunk),
# or any Enumerable. Shown via the Transfer family below; for HTTP, post a body:
URL("#{BASE}/post").post("a literal string body")
# URL("ftp://h/f").upload(File.open("big.bin"))   # IO, streamed off disk

# ---------------------------------------------------------------------------
section "8. Non-HTTP protocols (each gated by URL.supports?)"
# ---------------------------------------------------------------------------
# These run against their own servers; shown for shape. Each verb returns a
# URL::Response, and failures are values (resp.error) exactly like HTTP.

# file / ftp(s) / sftp / scp / tftp / telnet — the URL::Transfer family:
#   download / upload / list
URL("file:///etc/hostname").download           if URL.supports?("file")
# URL("ftp://h/path/").list                     # directory listing -> resp.lines
# URL("sftp://user@h/path").upload("data", ...) # streamed read callback

# gopher(s): get/download
# URL("gopher://h/1/menu").get

# dict: define(word, database: "!")
# URL("dict://dict.org/").define("ruby")

# imap(s): fetch(uid:) / move(uid:, to:) / store(uid:, flags:, op: "+") / expunge
# URL("imaps://user:pass@h/INBOX").fetch(uid: 7)
# URL("imaps://user:pass@h/INBOX").store(uid: 7, flags: "\\Deleted")

# pop3(s): list / fetch(n = nil) (alias download)
# URL("pop3://user:pass@h/").fetch(1)

# smtp(s): deliver(body, from:, to:)   (to: may be an Array)
# URL("smtp://h").deliver("Subject: hi\r\n\r\nbody\r\n",
#                         from: "me@x", to: ["a@y", "b@y"])

# ldap(s): search
# URL("ldap://h/dc=example,dc=com?mail?sub?(cn=Alice)").search

# mqtt(s): publish(payload) / subscribe(timeout:)
# URL("mqtt://h/topic").publish("hello")
# URL("mqtt://h/topic").subscribe(timeout: 2.s).body

# rtsp: options/describe/setup/play/pause/teardown/get_parameter/
#       set_parameter/announce/record  (transport:, stream_uri:)
# URL("rtsp://h/stream").describe
# URL("rtsp://h/stream").setup(transport: "RTP/AVP;unicast;client_port=4588-4589")

# ---------------------------------------------------------------------------
section "9. WebSocket (ws / wss)"
# ---------------------------------------------------------------------------
# connect returns a live URL::WebSocket; the block form auto-closes on exit.
if URL.supports?("ws")
  # URL("wss://echo.websocket.org").connect do |ws|
  #   ws.send("hello")                 # frame type from payload: valid UTF-8 → text, else binary (RFC 6455)
  #   msg = ws.receive(timeout: 2.s)   # a URL::WebSocket::Message, or nil on timeout
  #   msg.text? / msg.binary? / msg.close?
  #   ws.each { |m| break if m.close?; puts m.data }   # iterate frames
  #   ws.open?      # connection still live?
  #   ws.error      # value on a failed handshake (never a raise), nil otherwise
  #   # ws.close(status: 1000, reason: "bye")   # block form closes for you
  # end
  puts "ws supported — see commented snippet"
else
  puts "ws not built in this libcurl"
end

# ---------------------------------------------------------------------------
section "10. Parallel fan-out — URL.parallel"
# ---------------------------------------------------------------------------
# Queue requests on the yielded batch (same verbs as URL, each with an optional
# key:); they run concurrently on one session and come back as { key => Response }.
# on_complete fires per response the moment its transfer lands.
results = URL.parallel do |p|
  p.get("#{BASE}/get",            key: :a)
  p.post("#{BASE}/post", json: {}, key: :b)
  p.on_complete { |key, resp| puts "  landed #{key}: #{resp.code}" }
end
puts "parallel keys: #{results.keys.inspect}"

# ---------------------------------------------------------------------------
section "11. Sessions & the connection pool"
# ---------------------------------------------------------------------------
# URL.shared is the per-VM session every blocking verb reuses, so the connection
# pool, TLS sessions and HTTP/2 multiplexing persist across calls. Tune it:
URL.shared.setopt(:max_total_connections, 64)
URL.shared.setopt(:max_concurrent_streams, 100)

# URL.open makes an independent throwaway session if you want isolation; it still
# shares the global connection/TLS cache. (You rarely need this — the verbs pick
# the right session for you, including a fresh one when called re-entrantly.)
sess = URL.open
sess.setopt(:pipelining, 2)

puts "\n== end of tour =="
