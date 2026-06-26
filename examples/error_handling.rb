# examples/error_handling.rb
#
# How mruby-url surfaces errors, demonstrated against public test servers:
#   * httpbin.org   - returns whatever HTTP status / delay you ask for
#   * badssl.com    - serves deliberately broken TLS certificates
#   * *.invalid     - a name that is guaranteed never to resolve (RFC 6761)
#
# Run with an mruby that has mruby-url built in:
#
#     mruby examples/error_handling.rb
#
# The one rule to remember:
#
#   * USAGE mistakes (an unsupported scheme, bad arguments) raise immediately —
#     they are bugs in your code.
#   * Everything that can go wrong once a transfer is running is a VALUE on
#     resp.error: nil on success, or an exception object you can inspect (or
#     raise yourself). Nothing is raised FOR you unless you ask via
#     raise_for_status!.

puts "1. the basic shape — make the request, then look at resp.error"
resp = URL.get("https://httpbin.org/get")
if resp.error
  puts "   failed: #{resp.error.class} - #{resp.error.message}"
else
  puts "   ok: HTTP #{resp.code}, #{resp.body.bytesize} bytes"
end

puts
puts "2. an HTTP error status is a value, not a raise"
# httpbin.org/status/<n> replies with exactly status <n>.
resp = URL.get("https://httpbin.org/status/503")
err  = resp.error
puts "   #{err.class}  curl_code=#{err.curl_code}"
puts "   code=#{resp.code}  server_error?=#{resp.server_error?}"
# resp.error.response is the Response itself, so the body/headers are still there:
puts "   err.response.equal?(resp) -> #{err.response.equal?(resp)}"

puts
puts "3. transport failures map to one class per libcurl error —"
puts "   and where mruby already ships the right class, we reuse it."
# A DNS failure is a plain SocketError, exactly what mruby-socket itself raises.
resp = URL.get("https://no-such-host.invalid/")
puts "   #{resp.error.class}  (is_a? SocketError -> #{resp.error.is_a?(SocketError)})"
puts "   #{resp.error.message}"

puts
puts "4. a timeout is URL::OperationTimedout (libcurl CURLE_OPERATION_TIMEDOUT)"
# httpbin.org/delay/<n> waits n seconds before replying; we allow only 0.8s.
resp = URL.get("https://httpbin.org/delay/10", timeout_ms: 800)
puts "   #{resp.error.class}  curl_code=#{resp.error.curl_code}"
puts "   #{resp.error.message}"

puts
puts "5. a TLS verification failure is URL::PeerFailedVerification"
resp = URL.get("https://expired.badssl.com/")
puts "   #{resp.error.class}  curl_code=#{resp.error.curl_code}"
puts "   #{resp.error.message}"

puts
puts "6. dispatch on the error with case/when"
# The family shares a base (URL::TransferError) and reuses built-ins, so you can
# match a specific curl error, a reused built-in, the HTTP case, or the base.
def classify(url, **opts)
  resp = URL.get(url, **opts)
  case resp.error
  when nil                    then "ok (#{resp.code})"
  when URL::HttpReturnedError then "http #{resp.code}"
  when URL::OperationTimedout then "too slow, gave up"
  when SocketError            then "name resolution / socket problem"
  when URL::TransferError     then "other transport error (curl #{resp.error.curl_code})"
  end
end
puts "   /status/204        -> #{classify("https://httpbin.org/status/204")}"
puts "   /status/404        -> #{classify("https://httpbin.org/status/404")}"
puts "   /delay/10 @500ms   -> #{classify("https://httpbin.org/delay/10", timeout_ms: 500)}"
puts "   bad host           -> #{classify("https://no-such-host.invalid/")}"

puts
puts "7. opt INTO exceptions with raise_for_status!"
# It raises whatever resp.error holds (HTTP *or* transport) and otherwise returns
# self, so it chains: raise_for_status!.json
begin
  data = URL.get("https://httpbin.org/status/500").raise_for_status!.json
  puts "   got #{data.size} keys"
rescue URL::HttpReturnedError => e
  puts "   HTTP error: #{e.response.code}"
rescue URL::TransferError => e
  puts "   transport error: #{e.message} (curl #{e.curl_code})"
end

puts
puts "8. parallel fan-out — each Response carries its own error value,"
puts "   so one failure never derails the others"
results = URL.parallel do |p|
  p.get("https://httpbin.org/status/200", key: :ok,   timeout_ms: 15000)
  p.get("https://httpbin.org/status/500", key: :http, timeout_ms: 15000)
  p.get("https://no-such-host.invalid/",  key: :dns)
  p.get("https://httpbin.org/delay/10",   key: :slow, timeout_ms: 800)
end
results.each do |key, r|
  outcome = r.error ? "#{r.error.class}" : "ok #{r.code}"
  puts "   #{key.to_s.ljust(5)} -> #{outcome}"
end
