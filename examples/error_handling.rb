# examples/error_handling.rb
#
# How mruby-url surfaces errors, demonstrated against test servers:
#   * an httpbin-style server - returns whatever HTTP status / delay you ask for
#     (/status/N, /delay/N, /get). Defaults to the public httpbingo.org mirror,
#     but pass your own base URL as the first argument to point it at a local
#     server instead — httpbin.org itself is a famously overloaded shared
#     instance and will stall for minutes, so a local one is far more reliable.
#   * badssl.com - serves deliberately broken TLS certificates.
#   * *.invalid  - a name that is guaranteed never to resolve (RFC 6761).
#
# Run with an mruby that has mruby-url built in:
#
#     mruby examples/error_handling.rb                    # public mirror
#     mruby examples/error_handling.rb http://localhost:8080   # your own server
#
# For a deterministic, offline-friendly run, serve httpbin locally (same image
# httpbingo.org runs) and point the examples at it:
#
#     podman run --rm -p 8080:8080 docker.io/mccutchen/go-httpbin:latest
#     mruby examples/error_handling.rb http://localhost:8080
#
# (examples/run-with-httpbin.sh does both for you.) Note: the TLS case (#5) and
# DNS case (#3) still reach the network / resolver — only the httpbin routes are
# served by the base-URL server.
#
# The one rule to remember:
#
#   * USAGE mistakes (an unsupported scheme, bad arguments) raise immediately —
#     they are bugs in your code.
#   * Everything that can go wrong once a transfer is running is a VALUE on
#     resp.error: nil on success, or an exception object you can inspect (or
#     raise yourself). Nothing is raised FOR you unless you ask via
#     raise_for_status!.

# Base URL of the httpbin-style server: first CLI argument, else the public
# httpbingo.org mirror. Point it at a local container for a reliable run.
BASE = (ARGV[0] && !ARGV[0].empty?) ? ARGV[0] : "https://httpbingo.org"

# Warm the connection once. The very first TLS handshake to a cold public test
# server can lag; doing it up front (and on URL.shared, which pools the
# connection) keeps the timed examples below honest. The result is ignored.
URL("#{BASE}/get").get(timeout: 20.s)

puts "1. the basic shape — make the request, then look at resp.error"
resp = URL("#{BASE}/get").get(timeout: 15.s)
if resp.error
  puts "   failed: #{resp.error.class} - #{resp.error.message}"
else
  puts "   ok: HTTP #{resp.code}, #{resp.body.bytesize} bytes"
end

puts
puts "2. an HTTP error status is a value, not a raise"
# /status/<n> replies with exactly status <n>.
resp = URL("#{BASE}/status/503").get(timeout: 15.s)
err  = resp.error
puts "   #{err.class}  curl_code=#{err.curl_code}"
puts "   code=#{resp.code}  server_error?=#{resp.server_error?}"
# resp.error.response is the Response itself, so the body/headers are still there:
puts "   err.response.equal?(resp) -> #{err.response.equal?(resp)}"

puts
puts "3. transport failures map to one class per libcurl error —"
puts "   and where mruby already ships the right class, we reuse it."
# A DNS failure is a plain SocketError, exactly what mruby-socket itself raises.
resp = URL("https://no-such-host.invalid/").get
puts "   #{resp.error.class}  (is_a? SocketError -> #{resp.error.is_a?(SocketError)})"
puts "   #{resp.error.message}"

puts
puts "4. a timeout is URL::OperationTimedout (libcurl CURLE_OPERATION_TIMEDOUT)"
# /delay/<n> waits n seconds before replying; we allow only 0.8s.
resp = URL("#{BASE}/delay/10").get(timeout: 800.ms)
puts "   #{resp.error.class}  curl_code=#{resp.error.curl_code}"
puts "   #{resp.error.message}"

puts
puts "5. a TLS failure surfaces as one of the URL::Ssl* classes"
# Which one — PeerFailedVerification (curl 60) vs SslConnectError (curl 35) —
# depends on your libcurl's TLS backend (OpenSSL tends to report 60 for an
# expired cert; others report 35). Both mean "the TLS handshake was rejected".
resp = URL("https://expired.badssl.com/").get(timeout: 15.s)
puts "   #{resp.error.class}  curl_code=#{resp.error.curl_code}"
puts "   #{resp.error.message}"

puts
puts "6. dispatch on the error with case/when"
# The family shares a base (URL::TransferError) and reuses built-ins, so you can
# match a specific curl error, a reused built-in, the HTTP case, or the base.
def classify(url, **opts)
  resp = URL(url).get(**opts)
  case resp.error
  when nil                    then "ok (#{resp.code})"
  when URL::HttpReturnedError then "http #{resp.code}"
  when URL::OperationTimedout then "too slow, gave up"
  when SocketError            then "name resolution / socket problem"
  when URL::TransferError     then "other transport error (curl #{resp.error.curl_code})"
  end
end
puts "   /status/204        -> #{classify("#{BASE}/status/204", timeout: 15.s)}"
puts "   /status/404        -> #{classify("#{BASE}/status/404", timeout: 15.s)}"
puts "   /delay/10 @500ms   -> #{classify("#{BASE}/delay/10", timeout: 500.ms)}"
puts "   bad host           -> #{classify("https://no-such-host.invalid/")}"

puts
puts "7. opt INTO exceptions with raise_for_status!"
# It raises whatever resp.error holds (HTTP *or* transport) and otherwise returns
# self, so it chains: raise_for_status!.json
begin
  data = URL("#{BASE}/status/500").get(timeout: 15.s).raise_for_status!.json
  puts "   got #{data.size} keys"
rescue URL::HttpReturnedError => e
  puts "   HTTP error: #{e.response.code}"
rescue URL::TransferError => e
  puts "   transport error: #{e.message} (curl #{e.curl_code})"
end

puts
puts "8. parallel fan-out — each Response carries its own error value,"
puts "   so one failure never derails the others"
report = lambda do |key, r|
  outcome = r.error ? "#{r.error.class}" : "ok #{r.code}"
  puts "   #{key.to_s.ljust(5)} -> #{outcome}"
end
URL("#{BASE}/status/200").parallel(:get, timeout: 15.s)  { |r| report.call(:ok,   r) }
URL("#{BASE}/status/500").parallel(:get, timeout: 15.s)  { |r| report.call(:http, r) }
URL("https://no-such-host.invalid/").parallel(:get)      { |r| report.call(:dns,  r) }
URL("#{BASE}/delay/10").parallel(:get, timeout: 800.ms)  { |r| report.call(:slow, r) }
URL.parallel_perform
