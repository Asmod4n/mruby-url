# test/url.rb — runs under mrbtest, launched (like mrbtest itself) by the
# project Rakefile's `rake test` task, which also spawns test/server.ruby as
# a sibling process before invoking us. We never talk to the fixture process
# directly — we only read the port/state files it writes to $state_dir; the
# Rakefile owns starting and killing it (see Rakefile's `ensure` block).

# mrbtest's environ reads empty (ENV is dead here) and we don't spawn it, so it
# can't be handed the run-state path via ENV or ARGV. Instead the gem's
# mrbgem.rake — which runs under MRI rake, where ENV works — copies the path the
# project Rakefile exported into spec.test_args, and mrbtest bakes that into the
# TEST_ARGS constant for us. No marker file, nothing written outside the build.
$state_dir = (TEST_ARGS['state_dir'] rescue nil)
unless $state_dir && File.directory?($state_dir)
  return "run-state dir unavailable — run via 'rake test', not mrbtest directly"
end

port_file = File.join($state_dir, 'server_port')
unless File.exist?(port_file)
  return "#{port_file} missing — run via 'rake test', not mrbtest directly"
end
$server_port = File.read(port_file).strip.to_i
$base        = "http://127.0.0.1:#{$server_port}"

smtp_port_file = File.join($state_dir, 'smtp_port')
$smtp_port     = File.exist?(smtp_port_file) ? File.read(smtp_port_file).strip.to_i : nil
$smtp_received = File.join($state_dir, 'smtp_received')

imap_port_file = File.join($state_dir, 'imap_port')
$imap_port     = File.exist?(imap_port_file) ? File.read(imap_port_file).strip.to_i : nil
$imap_received = File.join($state_dir, 'imap_received')

ws_port_file = File.join($state_dir, 'ws_port')
$ws_port     = File.exist?(ws_port_file) ? File.read(ws_port_file).strip.to_i : nil

def _port(name)
  f = File.join($state_dir, name)
  File.exist?(f) ? File.read(f).strip.to_i : nil
end

# Run `name` unless `scheme` is unsupported by the embedded libcurl or `port`
# (the readiness token) is nil, in which case it is recorded as a Skip with a
# reason in the test report — instead of silently vanishing.
def proto_assert(name, scheme, port)
  assert(name) do
    skip("libcurl built without #{scheme}") unless URL.supports?(scheme)
    skip("no #{scheme} test server")        if port.nil?
    yield
  end
end
$ftp_port    = _port('ftp_port')
$dict_port   = _port('dict_port')
$gopher_port = _port('gopher_port')
$pop3_port   = _port('pop3_port')
$telnet_port = _port('telnet_port')
$rtsp_port   = _port('rtsp_port')
$tftp_port   = _port('tftp_port')
$sftp_port   = _port('sftp_port')
$ldap_port   = _port('ldap_port')
$mqtt_port   = _port('mqtt_port')
$ftps_port    = _port('ftps_port')
$pop3s_port   = _port('pop3s_port')
$gophers_port = _port('gophers_port')
$ldaps_port   = _port('ldaps_port')
$mqtts_port   = _port('mqtts_port')
sftp_meta_f  = File.join($state_dir, 'sftp_meta')
$sftp_meta   = File.exist?(sftp_meta_f) ? File.read(sftp_meta_f).split("\n") : nil

# ---- assertions -----------------------------------------------------------

assert('URL("uri") returns the scheme-typed wrapper for every supported scheme') do
  # Each scheme maps to its own per-protocol class (URL::HTTP, URL::FTP, …),
  # named by upcasing the scheme. Those classes exist ONLY when this libcurl
  # was built with the protocol, so the constant is referenced via const_get
  # and only when supported — an unbuilt scheme has no class at all.
  schemes = %w[
    http https ftp ftps sftp scp file tftp telnet gopher gophers dict
    imap imaps pop3 pop3s smtp smtps ldap ldaps mqtt mqtts rtsp ws wss
  ]
  schemes.each do |scheme|
    sample = case scheme
             when "file" then "file:///etc/hostname"
             else             "#{scheme}://h"
             end
    if URL.supports?(scheme)
      klass = URL.const_get(scheme.upcase)
      assert_equal klass, URL(sample).class, "URL(#{sample.inspect}) should be #{klass}"
    else
      # A scheme libcurl wasn't built with raises immediately from URL(uri) —
      # no wrapper is constructed for a protocol the build can't speak, and the
      # per-protocol class constant doesn't exist either.
      assert_raise(URL::Error) { URL(sample) }
      assert_false URL.const_defined?(scheme.upcase),
                   "URL::#{scheme.upcase} must not exist for unbuilt #{scheme}"
    end
  end
end

assert('URL(uri) raises immediately for a recognized-but-unbuilt scheme') do
  unbuilt = %w[ws wss sftp scp mqtt mqtts rtsp gopher dict ldap].find { |s| !URL.supports?(s) }
  skip("every candidate scheme is built in this libcurl") unless unbuilt
  err = assert_raise(URL::ProtocolNotAvailable) { URL("#{unbuilt}://h/x") }
  assert_kind_of URL::SchemeError, err          # branchable family
  assert_kind_of URL::Error,       err          # ...and still a usage error
  assert_include err.message, "protocol not available"
  assert_equal unbuilt, err.scheme              # carries the offending scheme
  assert_equal URL::PROTOS, err.supported       # ...and what the build DOES have
end

assert('URL("uri").get and URL::HTTP.get("uri") both work') do
  url = "#{$base}/echo"
  a = URL(url).get
  b = URL::HTTP.get(url)
  assert_true a.success?
  assert_true b.success?
  assert_equal 'GET', a.json['method']
  assert_equal 'GET', b.json['method']
end

assert('URL("uri") raises URL::UnsupportedScheme for an unknown scheme') do
  err = assert_raise(URL::UnsupportedScheme) { URL("zzz://x") }
  assert_kind_of URL::SchemeError, err
  assert_kind_of URL::Error,       err
  assert_include err.message, 'unsupported scheme'
  assert_equal "zzz", err.scheme
  assert_equal URL::PROTOS, err.supported
end

assert('the connection share is per-thread, not exposed to Ruby') do
  # The CURLSH now lives in OS-thread-local storage in C, created lazily on the
  # first easy on each thread and freed by its tss destructor at thread exit.
  # It is deliberately invisible to Ruby — no URL::Libcurl::SHARE constant, no
  # URL::Libcurl::Share class — so it can't be tampered with or GC'd out from
  # under libcurl.
  assert_false URL::Libcurl.const_defined?(:SHARE)
  assert_false URL::Libcurl.const_defined?(:Share)
end

assert('Throwaway session against the same host still succeeds (share-attached)') do
  # First request warms this thread's connection / TLS cache. A second request
  # on a fresh URL.open against the same origin succeeds — and (not asserted
  # because timing is CI-flaky) reuses the kept-alive connection through the
  # per-thread share, which every easy on the thread attaches to.
  assert_true URL("#{$base}/echo").get.success?
  fresh = URL.open
  req, state = URL.__send__(:_build_request, fresh, :GET, "#{$base}/echo", nil, { timeout: 5.s }, nil)
  resp = URL.__send__(:_drive_sync, fresh, "#{$base}/echo", req, state)
  assert_true resp.success?
end

assert('URL::Libcurl::Easy dup/clone duplicates the handle into an independent, usable one') do
  # Ruby dup/clone of a CDATA used to leave the copy with no handle. Now it runs
  # curl_easy_duphandle, so the copy is an independent working handle that keeps
  # the source's options (here the URL) and performs on its own.
  e1 = URL::Libcurl.easy_init
  URL::Libcurl.easy_setopt(e1, :url, "#{$base}/echo")
  e2 = e1.dup
  assert_not_equal e1.object_id, e2.object_id
  assert_kind_of URL::Libcurl::Easy, e2
  assert_equal 0,   URL::Libcurl.easy_perform(e2)
  assert_equal 200, URL::Libcurl.easy_getinfo(e2, :response_code)
  # The original is untouched and still works (no shared/freed state).
  assert_equal 0,   URL::Libcurl.easy_perform(e1)
  assert_equal 200, URL::Libcurl.easy_getinfo(e1, :response_code)
end

assert('a duped handle gets its OWN copy of the source header slist') do
  e1 = URL::Libcurl.easy_init
  URL::Libcurl.easy_setopt(e1, :url, "#{$base}/echo")
  URL::Libcurl.easy_setopt(e1, :httpheader, ["X-Dup: carried"])
  e2 = e1.dup
  body = String.new
  e2.on_data = ->(c) { body << c }   # callbacks rewired to the copy's struct
  assert_equal 0, URL::Libcurl.easy_perform(e2)
  assert_include JSON.parse(body)["headers"]["x-dup"].to_s, "carried"
end

assert('URL::Request#dup gives an independent easy handle') do
  a = URL::Request.new(URL.shared, "#{$base}/echo")
  b = a.dup
  assert_not_equal a.handle.object_id, b.handle.object_id
  assert_kind_of URL::Libcurl::Easy, b.handle
end

assert('handles with no duplicable libcurl resource refuse dup/clone') do
  # The multi handle has no curl_multi_duphandle, and the mime tree/parts are
  # tied to the easy that built them — dup/clone would share or orphan the C
  # handle, so they raise instead of handing back a broken copy.
  assert_raise(NotImplementedError) { URL.open.dup }                 # session (multi handle)
  assert_raise(NotImplementedError) { URL.open.clone }
  assert_raise(NotImplementedError) { URL::Libcurl.multi_init.dup }  # Multi CDATA

  e = URL::Libcurl.easy_init
  m = URL::Libcurl.mime_new(e)
  assert_raise(NotImplementedError) { m.dup }                        # Mime CDATA
  assert_raise(NotImplementedError) { URL::Libcurl.mime_addpart(m).dup }  # Part CDATA
end

# ---- URL::EventLoop — the one thing everything drives through -------------

assert('URL::IOSelectLoop#run_once services more than one concurrent timer') do
  # A single @timer slot (the pre-fix bug) would make the second arm_timer
  # silently replace the first, so :a would never fire.
  loop  = URL::IOSelectLoop.new
  fired = []
  loop.arm_timer(30.ms)  { fired << :a }
  loop.arm_timer(120.ms) { fired << :b }
  loop.run_once until fired.size >= 2
  assert_equal [:a, :b], fired
end

assert('URL::IOSelectLoop#cancel_timer only cancels its own handle') do
  loop  = URL::IOSelectLoop.new
  fired = []
  a = loop.arm_timer(20.ms) { fired << :a }
  loop.arm_timer(60.ms) { fired << :b }
  loop.cancel_timer(a)
  loop.run_once until fired.include?(:b)
  assert_equal [:b], fired
end

assert('URL::IOSelectLoop#watch supports two independent registrations on the same fd') do
  # A websocket watches :in for the connection's whole life and, only while a
  # send is draining, briefly adds a second :out registration on that same
  # fd — the second registration must not clobber the first, and unwatching
  # one must leave the other alone. A connected TCP loopback pair gives one
  # fd that's both readable and writable, unlike a pipe's two separate ends
  # (and mruby-socket, unlike IO.pipe, is a hard dependency of this gem, so
  # it's available on every platform the gem itself runs on).
  srv    = TCPServer.new('127.0.0.1', 0)
  client = TCPSocket.new('127.0.0.1', srv.addr[1])
  peer   = srv.accept
  begin
    loop = URL::IOSelectLoop.new
    in_fired  = 0
    out_fired = 0
    in_handle  = loop.watch(client, :in)  { in_fired  += 1 }
    out_handle = loop.watch(client, :out) { out_fired += 1 }

    loop.run_once until out_fired > 0   # a fresh socket is immediately writable
    assert_equal 0, in_fired            # nothing sent to client yet

    loop.unwatch(out_handle)
    peer.write("x")
    loop.run_once until in_fired > 0
    assert_equal 1, in_fired

    loop.unwatch(in_handle)
  ensure
    client.close
    peer.close
    srv.close
  end
end

assert('a minimal URL::EventLoop subclass, as default_loop, still drives a blocking verb') do
  # The whole "one loop, swappable, five primitives" architecture rests on
  # run_once being sufficient on its own — a loop offering nothing more
  # must still drive a plain blocking verb exactly like the built-in
  # IOSelectLoop does. This wraps IOSelectLoop's own run_once (proving nothing
  # is special-cased for the built-in class) but counts how often it's asked.
  probe = Class.new(URL::EventLoop) do
    def initialize
      @inner  = URL::IOSelectLoop.new
      @rounds = 0
    end
    attr_reader :rounds
    def watch(io, readiness, &block); @inner.watch(io, readiness, &block); end
    def unwatch(handle);              @inner.unwatch(handle);             end
    def arm_timer(delay, &block);     @inner.arm_timer(delay, &block);    end
    def cancel_timer(handle);         @inner.cancel_timer(handle);        end
    def run_once(timeout = nil)
      @rounds += 1
      @inner.run_once(timeout)
    end
  end.new

  prior = URL.default_loop
  begin
    URL.default_loop = probe
    fresh = URL.open   # never touched — resolves default_loop right now
    req, state = URL.__send__(:_build_request, fresh, :GET, "#{$base}/echo", nil, {}, nil)
    resp = URL.__send__(:_drive_sync, fresh, "#{$base}/echo", req, state)
    assert_true resp.success?
    assert_equal probe, fresh.event_loop
    assert_true probe.rounds > 0
  ensure
    URL.default_loop = prior
  end
end

assert('URL.get echo') do
  r = URL("#{$base}/echo").get(params: { a: '1', b: 'x y' })
  assert_true r.success?
  j = r.json
  assert_equal 'GET',         j['method']
  assert_equal '1',           j['query']['a']
  assert_equal 'x y',         j['query']['b']
end

assert('URL.post json') do
  r = URL("#{$base}/echo").post(json: { name: 'Alice' })
  assert_true r.success?
  j = r.json
  assert_equal 'POST',                    j['method']
  assert_equal 'application/json',        j['headers']['content-type']
  assert_equal '{"name":"Alice"}',        j['body']
end

assert('URL.post form') do
  r = URL("#{$base}/echo").post(form: { name: 'Alice', tags: %w[a b] })
  j = r.json
  assert_equal 'application/x-www-form-urlencoded', j['headers']['content-type']
  assert_include j['body'], 'name=Alice'
  assert_include j['body'], 'tags=a'
  assert_include j['body'], 'tags=b'
end

assert('URL.get bearer + custom headers') do
  r = URL("#{$base}/echo").get(
              bearer:  'secret',
              headers: { 'X-Custom' => 'yes', 'User-Agent' => 'override' })
  j = r.json
  assert_equal 'Bearer secret', j['headers']['authorization']
  assert_equal 'yes',           j['headers']['x-custom']
  assert_equal 'override',      j['headers']['user-agent']
end

assert('redirects followed by default') do
  r = URL("#{$base}/redirect/3").get
  assert_true r.success?
  assert_include r.effective_url, '/echo'
end

assert('status codes classify correctly') do
  assert_true  URL("#{$base}/status/204").get.success?
  assert_true  URL("#{$base}/status/404").get.client_error?
  assert_true  URL("#{$base}/status/503").get.server_error?
  assert_true  URL("#{$base}/status/503").get.error?
end

assert('raise_for_status!') do
  err = assert_raise(URL::HttpReturnedError) do
    URL("#{$base}/status/500").get.raise_for_status!
  end
  assert_equal 500, err.response.code
  assert_equal 22,  err.curl_code          # CURLE_HTTP_RETURNED_ERROR
end

assert('timeout produces decorated error') do
  # Duration API: 100.ms (a chrono Float-seconds value) is handed to libcurl
  # losslessly as 100 CURLOPT_TIMEOUT_MS by the C converter.
  r = URL("#{$base}/slow/2000").get(timeout: 100.ms)
  assert_true r.error?
  assert_equal 28, r.error_code           # CURLE_OPERATION_TIMEDOUT
  assert_include r.error_message, 'timed out'
end

assert('timeout accepts any chrono duration unit') do
  # Different units, same effect — all are Float seconds under the hood, handed
  # to libcurl as milliseconds without precision loss.
  assert_true URL("#{$base}/slow/2000").get(timeout: 0.1.s).error?
  assert_true URL("#{$base}/slow/2000").get(timeout: 100_000.us).error?
  assert_true URL("#{$base}/slow/2000").get(timeout: 100.ms).error?
end

assert('time-valued options only accept chrono durations') do
  # Every time value crosses into C through mruby-chrono's converter, which
  # type-checks: anything non-numeric raises TypeError at the call, before any
  # I/O. This covers the _MS options (timeout) and the seconds options
  # (tcp_keepidle) alike.
  assert_raise(TypeError) { URL("#{$base}/echo").get(timeout: "5") }
  assert_raise(TypeError) { URL("#{$base}/echo").get(connect_timeout: :soon) }
  assert_raise(TypeError) { URL("#{$base}/echo").get(tcp_keepidle: "30") }
end

assert('newly wired curl options are accepted (not an unsupported option)') do
  # A representative spread across the new flat setopt pass-throughs (HTTP
  # version, inline cookie, proxy, rate limiting, keepalive). The values are
  # inert for a plain localhost GET; the point is that setopt wires each one
  # instead of raising ArgumentError "unsupported option". Backend-specific TLS
  # options (capath, pinnedpublickey, …) are deliberately left out — they
  # legitimately raise CURLE_NOT_BUILT_IN on TLS backends that lack them (e.g.
  # Schannel on Windows), which is correct behaviour, not a wiring failure.
  r = URL("#{$base}/echo").get(
    accept_encoding: "",          # opt-in transparent compression
    cookie:          "a=1; b=2",
    http_version:    2,           # CURL_HTTP_VERSION_1_1 (always built)
    sslversion:      0,           # CURL_SSLVERSION_DEFAULT
    proxytype:       0,           # CURLPROXY_HTTP
    noproxy:         "*",
    max_recv_speed:  10_000_000,
    max_send_speed:  10_000_000,
    tcp_keepalive:   true,
    tcp_keepidle:    30,
    tcp_keepintvl:   15,
  )
  assert_true r.success?
  # The inline cookie really went out (echoed back by the server).
  assert_include r.json["headers"]["cookie"].to_s, "a=1"
end

assert('each scheme owns its high-level kwargs; foreign ones are rejected up front') do
  # file:// is always built. Transfer owns only params/headers, so HTTP-only
  # convenience kwargs are rejected with ArgumentError before any I/O — not a
  # silent no-op, not a cryptic libcurl error.
  assert_raise(ArgumentError) { URL("file:///x").download(json: { a: 1 }) }
  assert_raise(ArgumentError) { URL("file:///x").download(form: { a: 1 }) }
  assert_raise(ArgumentError) { URL("file:///x").download(bearer: "t") }
  assert_raise(ArgumentError) { URL("file:///x").download(multipart: {}) }
  # Raw curl options are NOT high-level kwargs, so the wrapper lets them through
  # to setopt (here they just produce an error-as-value, never an ArgumentError).
  r = URL("file:///nonexistent-#{Process.pid rescue 0}").download(verbose: false)
  assert_false r.error.nil?
  # HTTP owns all of them, so the same kwargs are accepted there.
  assert_true URL("#{$base}/echo").post(json: { ok: 1 }).success?
end

assert('setopt: forwards raw libcurl options verbatim (escape hatch)') do
  # The long tail of curl options we don't surface by name can still be set,
  # explicitly, via setopt: { ... } — the pairs flow straight to URL::Request#setopt.
  r = URL("#{$base}/echo").get(setopt: { user_agent: "via-setopt" })
  assert_true r.success?
  assert_equal "via-setopt", r.json["headers"]["user-agent"]
  # An explicit setopt is merged last, so it wins over the same option by name.
  r2 = URL("#{$base}/echo").get(user_agent: "named", setopt: { user_agent: "raw-wins" })
  assert_equal "raw-wins", r2.json["headers"]["user-agent"]
end

assert('multipart/form-data upload (curl_mime) with a plain field and a file part') do
  r = URL("#{$base}/multipart").post(multipart: {
    "field"  => "value-123",
    "upload" => { filename: "a.txt", type: "text/plain", data: "file-body-xyz\n" },
  })
  assert_true r.success?
  j = r.json
  assert_include j["content_type"], "multipart/form-data"
  assert_include j["content_type"], "boundary="
  body = j["body"]
  assert_include body, 'name="field"'
  assert_include body, "value-123"
  assert_include body, 'name="upload"'
  assert_include body, 'filename="a.txt"'
  assert_include body, "Content-Type: text/plain"
  assert_include body, "file-body-xyz"
end

assert('multipart streams a file part from disk via file:') do
  path = File.join($state_dir, "mime-part.txt")
  File.open(path, "wb") { |f| f.write("from-disk-streamed\n") }
  r = URL("#{$base}/multipart").post(multipart: {
    "doc" => { file: path, filename: "doc.txt" },
  })
  assert_true r.success?
  assert_include r.json["body"], "from-disk-streamed"
  assert_include r.json["body"], 'filename="doc.txt"'
end

assert('resp.error is set on failure (transport or HTTP) as a value, nil on success') do
  ok = URL("#{$base}/echo").get
  assert_nil ok.error                                  # success -> no error value

  # An HTTP error status is surfaced as a value too: resp.error holds an
  # HttpReturnedError. Nothing is raised — it is a value like everything else.
  http = URL("#{$base}/status/500").get
  assert_kind_of URL::HttpReturnedError, http.error
  assert_kind_of URL::TransferError, http.error        # ...and the family base
  assert_equal 500,  http.error.response.code
  assert_equal 22,   http.error.curl_code              # CURLE_HTTP_RETURNED_ERROR
  assert_true  http.server_error?

  # A genuine below-the-response failure shows up as the matching URL:: value.
  trans = URL("#{$base}/slow/2000").get(timeout: 100.ms)
  assert_kind_of URL::OperationTimedout, trans.error   # CURLE_OPERATION_TIMEDOUT
  assert_kind_of URL::TransferError, trans.error       # ...and the family base
  assert_equal 28,    trans.error.curl_code
  assert_equal trans, trans.error.response
  # ...and it is a *value*, not raised — but you can still raise it yourself.
  raised = assert_raise(URL::OperationTimedout) { raise trans.error }
  assert_equal trans.error, raised
end

assert('gzip route reachable') do
  r = URL("#{$base}/gzip").get
  assert_equal 'gzip', r['content-encoding']
  assert_true r.body.bytesize > 0
  # First two bytes of any gzip stream are the magic 1f 8b
  assert_equal "\x1f\x8b".b, r.body.byteslice(0, 2).b
end

assert('streaming block bypasses response body') do
  chunks = []
  r = URL("#{$base}/big/65536").get { |c| chunks << c }
  assert_equal '', r.body
  total = 0
  chunks.each { |c| total += c.bytesize }
  assert_equal 65536, total
end

assert('an exception raised inside a streaming block propagates as itself') do
  # A raise inside on_data aborts the transfer (libcurl sees a short write and
  # fails it with CURLE_WRITE_ERROR), but the ORIGINAL exception must reach
  # the caller — not get silently swallowed and reported as a WriteError
  # value instead. A big-enough body forces several write-callback
  # invocations per transfer, so this also exercises libcurl's connection
  # teardown (which fires the socket callback) happening *after* the
  # exception is already stashed, in the same drive pass.
  class URLTestStreamRaise < StandardError
    def initialize(tag); super("stream:#{tag}"); @tag = tag; end
    attr_reader :tag
  end

  calls = 0
  raised = assert_raise(URLTestStreamRaise) do
    URL("#{$base}/big/65536").get do |_c|
      calls += 1
      raise URLTestStreamRaise, 'boom' if calls == 1
    end
  end
  assert_equal 'stream:boom', raised.message
  assert_equal 'boom', raised.tag

  # The gem must still be fully usable afterward -- no leaked loop/session
  # state from the aborted transfer.
  r = URL("#{$base}/echo").get
  assert_true r.success?
end

assert('a raising parallel handler does not corrupt the batch driver') do
  # A DIFFERENT failure point than the streaming-block test above: the raise
  # comes from the completion handler itself (pure Ruby, called once the
  # transfer has already finished), not from a libcurl callback. It must
  # still surface from parallel_perform, and the loop/session must be
  # left clean enough that a fresh call afterward works normally.
  seen = []
  assert_raise(RuntimeError) do
    URL("#{$base}/echo").parallel(:get) { |r| seen << r; raise 'boom-parallel-handler' }
    URL.parallel_perform
  end
  r = URL("#{$base}/echo").get
  assert_true r.success?
end

assert('multi-valued header merges into array') do
  r = URL("#{$base}/multi-cookie").get
  cookies = r.set_cookies
  assert_kind_of Array, cookies
  assert_equal 2, cookies.length
end

assert('top-level calls reuse the shared session') do
  before = URL.shared
  r = URL("#{$base}/echo").get
  assert_true r.success?
  assert_true URL.shared.equal?(before)   # same session object, pool reused
end

assert('URL.get inside a callback transparently uses a fresh session') do
  nested = nil
  outer = URL("#{$base}/big/1024").get do |_chunk|
    # We're inside the shared session's write callback: it can't drive a
    # second transfer. The hybrid dispatch must hand this call a fresh one.
    nested ||= URL("#{$base}/echo").get
  end
  assert_equal '', outer.body                 # outer body was streamed away
  assert_kind_of URL::Response, nested
  assert_true nested.success?
  assert_equal 'GET', nested.json['method']
end

# ---- Parallel fan-out -------------------------------------------------------

assert('URL(uri).parallel registers; URL.parallel_perform drives, returning nothing') do
  seen = {}
  URL("#{$base}/echo").parallel(:get, params: { n: '1' }) { |r| seen[:a] = r }
  URL("#{$base}/echo").parallel(:post, json: { x: 2 })    { |r| seen[:b] = r }
  URL("#{$base}/status/404").parallel(:get)               { |r| seen[:c] = r }
  assert_equal 0, seen.size            # nothing ran at registration

  assert_nil URL.parallel_perform      # pure driver: handlers are the only output

  assert_equal 3, seen.size
  assert_kind_of URL::Response, seen[:a]
  assert_true  seen[:a].success?
  assert_equal '1',    seen[:a].json['query']['n']
  assert_equal 'POST', seen[:b].json['method']
  assert_true  seen[:c].client_error?
  assert_equal 404, seen[:c].code
  assert_kind_of URL::HttpReturnedError, seen[:c].error  # HTTP error as a value, in the batch too
end

assert('URL.parallel_perform resolves answers as they arrive (fast lands before slow)') do
  order = []
  URL("#{$base}/slow/300").parallel(:get) { |_r| order << :slow }
  URL("#{$base}/echo").parallel(:get)     { |_r| order << :fast }
  URL.parallel_perform
  # Ran concurrently on one session: the instant echo completes before the
  # 300ms one, so its handler fires first — serial dispatch would give :slow.
  assert_equal [:fast, :slow], order
end

assert('URL(uri).parallel fans out non-HTTP verbs the same way') do
  skip "libcurl built without file" unless URL.supports?("file")

  path = File.join($state_dir, 'parallel-perform.txt')
  File.open(path, 'wb') { |f| f.write("parallel-perform-body\n") }
  furl = "file://#{path}"

  from_file = nil
  from_http = nil
  URL(furl).parallel(:download)       { |r| from_file = r }
  URL("#{$base}/echo").parallel(:get) { |r| from_http = r }
  URL.parallel_perform

  assert_nil from_file.error                       # file:// has no HTTP status
  assert_equal "parallel-perform-body\n", from_file.body
  assert_true from_http.success?
end

assert('URL::SCHEME.parallel mirrors the instance form') do
  got = nil
  URL::HTTP.parallel("#{$base}/echo", :get, params: { k: 'v' }) { |r| got = r }
  URL.parallel_perform
  assert_true got.success?
  assert_equal 'v', got.json['query']['k']
end

assert('URL.parallel_perform with nothing registered is a no-op') do
  assert_nil URL.parallel_perform
end

assert('a blocking verb inside a parallel handler rides the same loop') do
  # Handlers run in pure-Ruby loop frames, so a nested blocking call pumps
  # the same internal loop (and reuses the same session/connection pool)
  # instead of needing a throwaway session.
  inner = nil
  outer = nil
  URL("#{$base}/echo").parallel(:get, params: { outer: '1' }) do |r|
    outer = r
    inner = URL("#{$base}/echo").get(params: { nested: '1' })
  end
  URL.parallel_perform
  assert_equal 200, outer.code
  assert_equal 200, inner.code
  assert_include inner.effective_url, 'nested=1'
end

assert('parallel registration keeps usage errors as raises, before any I/O') do
  # Unknown scheme raises from URL(uri) itself, as always.
  assert_raise(URL::SchemeError) { URL("nosuchscheme://x").parallel(:get) }

  # A verb the scheme doesn't have raises at registration.
  assert_raise(ArgumentError) { URL("#{$base}/echo").parallel(:download) }

  # WebSocket connect yields a live socket, not a Response — can't batch.
  if URL.supports?("ws")
    assert_raise(ArgumentError) { URL("ws://127.0.0.1:1/sock").parallel(:connect) }
  end

  # Failed registrations above must not leave stragglers behind.
  assert_nil URL.parallel_perform
end

assert('Response#retry(times) inside a parallel handler retries within the SAME perform') do
  codes    = []
  outcomes = []
  URL("#{$base}/status/500").parallel(:get) do |r|
    codes << r.code
    outcomes << r.retry(2) if r.error     # budget rides with the registration —
  end                                     # no hand-rolled attempt counter needed
  URL.parallel_perform                    # one call drives all three rounds
  assert_equal [500, 500, 500], codes     # initial + 2 retries, same handler each time
  assert_equal false, outcomes.last       # exhausted budget: retry refused, perform drained
  assert_nil URL.parallel_perform         # nothing left pending
end

assert('Response#retry defaults to a single retry') do
  codes = []
  URL("#{$base}/status/500").parallel(:get) do |r|
    codes << r.code
    r.retry if r.error                    # times defaults to 1
  end
  URL.parallel_perform
  assert_equal [500, 500], codes
end

assert('Response#retry preserves the verb arguments across retry rounds') do
  urls = []
  first = true
  URL("#{$base}/status/404").parallel(:get, params: { n: '1' }) do |r|
    urls << r.effective_url
    if first
      first = false
      r.retry                             # opts must survive the rebuild
    end
  end
  URL.parallel_perform
  assert_equal 2, urls.size
  assert_include urls[0], 'n=1'
  assert_include urls[1], 'n=1'
end

assert('a parallel Response cannot be retried once its handler returned') do
  escaped = nil
  URL("#{$base}/status/500").parallel(:get) { |r| escaped = r }
  URL.parallel_perform
  assert_kind_of URL::HttpReturnedError, escaped.error
  err = assert_raise(URL::Error) { escaped.retry }
  assert_include err.message, 'handler'
  assert_nil URL.parallel_perform         # nothing was registered by the refusal
end

assert('Response#retry re-runs a failed blocking request and returns the new Response') do
  r = URL("#{$base}/status/500").get
  assert_kind_of URL::HttpReturnedError, r.error
  r2 = r.retry                            # blocking origin: redo now
  assert_kind_of URL::Response, r2
  assert_false r.equal?(r2)
  assert_equal 500, r2.code
  r3 = r2.retry(3)                        # up to 3 re-runs, returns the last Response
  assert_kind_of URL::Response, r3
  assert_equal 500, r3.code
  assert_raise(ArgumentError) { r.retry(0) }     # the budget must be an Integer >= 1
  assert_raise(ArgumentError) { r.retry("2") }
end

assert('Response#retry on a blocking request preserves the verb arguments') do
  r = URL("#{$base}/status/404").get(params: { n: '1' })
  assert_include r.effective_url, 'n=1'
  r2 = r.retry
  assert_include r2.effective_url, 'n=1'  # opts were not consumed by round one
end

assert('Response#retry_after surfaces the server\'s Retry-After header') do
  r = URL("#{$base}/retry-after/2").get
  assert_equal 503, r.code
  assert_equal 2.s, r.retry_after          # libcurl parsed the header; a chrono duration
  assert_true r.retry_after.is_a?(Float)   # Float seconds, like every other duration
  assert_nil URL("#{$base}/echo").get.retry_after   # absent header -> nil
end

assert('Response#retry honors wait: and the server\'s Retry-After') do
  # Explicit wait: short pause, blocking retry still works end to end.
  r = URL("#{$base}/status/500").get
  r2 = r.retry(wait: 100.ms)
  assert_equal 500, r2.code

  # No wait: given -> the server-sent Retry-After (here 1s) is used between
  # rounds. One retry of the 503 must therefore take >= 1s wall time; the
  # transfers themselves are instant, so total_time is a lower-bound proxy
  # only for the request, not the wait — assert behaviour, not the clock:
  # the retry completes and still reports the 503 + its Retry-After.
  r3 = URL("#{$base}/retry-after/1").get.retry
  assert_equal 503, r3.code
  assert_equal 1, r3.retry_after

  # Parallel: wait riding on the resubmission; drains within one perform.
  codes = []
  URL("#{$base}/retry-after/1").parallel(:get) do |resp|
    codes << resp.code
    resp.retry(1, wait: 50.ms) if resp.error   # explicit wait overrides the 1s ask
  end
  URL.parallel_perform
  assert_equal [503, 503], codes

  # Validation: wait must be a non-negative duration/seconds.
  assert_raise(ArgumentError) { r.retry(wait: -1) }
  assert_raise(ArgumentError) { r.retry(wait: :soon) }
end

assert('Response#retry is for failures only — a success raises') do
  r = URL("#{$base}/echo").get
  err = assert_raise(URL::Error) { r.retry }
  assert_include err.message, 'nothing to retry'
end

# ---- SMTPS via URL.send: the upload/read path on an RFC-named verb ---------

assert('URL.send over SMTPS delivers the envelope and body') do
  skip "libcurl built without smtps"  unless URL.supports?("smtps")
  skip "no smtp test server"          unless $smtp_port

  resp = URL("smtps://127.0.0.1:#{$smtp_port}").deliver(
    "Subject: hi\r\n\r\nhello body\r\n",   # body is positional (RFC822 message)
    from:            "a@example.com",
    to:              "b@example.com",
    ssl_verify_peer: false,
    ssl_verify_host: false,
  )

  assert_kind_of URL::Response, resp
  assert_equal 0,   resp.error_code        # transport succeeded
  assert_equal 250, resp.code              # final SMTP reply code

  # The fixture appends the envelope + DATA body it received.
  assert_true File.exist?($smtp_received)
  got = File.read($smtp_received)
  assert_include got, "FROM a@example.com"
  assert_include got, "RCPT b@example.com"
  assert_include got, "hello body"
end

assert('URL.send accepts an Array of recipients and gates unknown schemes') do
  # Array recipients become the :mail_rcpt list.
  if URL.supports?("smtps") && $smtp_port
    resp = URL("smtps://127.0.0.1:#{$smtp_port}").deliver(
      "Subject: multi\r\n\r\nbody two\r\n",
      from:            "sender@example.com",
      to:              ["x@example.com", "y@example.com"],
      ssl_verify_peer: false,
      ssl_verify_host: false,
    )
    assert_equal 250, resp.code
    got = File.read($smtp_received)
    assert_include got, "RCPT x@example.com"
    assert_include got, "RCPT y@example.com"
  end

  # A scheme libcurl wasn't built with raises before any connection attempt.
  err = assert_raise(URL::Error) do
    URL("zzz://127.0.0.1:1").deliver("hi", from: "a@x", to: "b@x")
  end
  assert_include err.message, "unsupported scheme"
end

# ---- IMAPS: the RFC-verb dispatch (move / store / expunge / fetch) ---------

assert('URL.store + URL.expunge perform the IMAP delete flow') do
  skip "libcurl built without imaps" unless URL.supports?("imaps")
  skip "no imap test server"         unless $imap_port

  base = "imaps://user:pass@127.0.0.1:#{$imap_port}/INBOX"

  sresp = URL(base).store(uid: 7, flags: "\\Deleted",
                    ssl_verify_peer: false, ssl_verify_host: false)
  assert_kind_of URL::Response, sresp
  assert_equal 0, sresp.error_code

  eresp = URL(base).expunge(ssl_verify_peer: false, ssl_verify_host: false)
  assert_kind_of URL::Response, eresp
  assert_equal 0, eresp.error_code

  # The fixture recorded the exact command lines curl issued.
  got = File.read($imap_received)
  assert_include got, "UID STORE 7 +FLAGS (\\Deleted)"
  assert_include got, "EXPUNGE"
end

assert('URL.move issues UID MOVE to the destination mailbox') do
  skip "libcurl built without imaps" unless URL.supports?("imaps")
  skip "no imap test server"         unless $imap_port

  base = "imaps://user:pass@127.0.0.1:#{$imap_port}/INBOX"
  resp = URL(base).move(uid: 9, to: "Archive",
                  ssl_verify_peer: false, ssl_verify_host: false)
  assert_kind_of URL::Response, resp
  assert_equal 0, resp.error_code

  got = File.read($imap_received)
  assert_include got, "UID MOVE 9 Archive"
end

assert('URL.fetch returns the message body') do
  skip "libcurl built without imaps" unless URL.supports?("imaps")
  skip "no imap test server"         unless $imap_port

  base = "imaps://user:pass@127.0.0.1:#{$imap_port}/INBOX"
  resp = URL(base).fetch(uid: 2,
                   ssl_verify_peer: false, ssl_verify_host: false)
  assert_kind_of URL::Response, resp
  assert_equal 0, resp.error_code
  assert_include resp.body, "This is the fixture message body."

  # A streaming block receives the bytes instead of buffering them.
  streamed = ""
  bresp = URL(base).fetch(uid: 2,
                    ssl_verify_peer: false, ssl_verify_host: false) { |c| streamed << c }
  assert_equal "", bresp.body
  assert_include streamed, "This is the fixture message body."
end

assert('IMAP verbs gate unavailable / unknown schemes') do
  # An IMAP verb on a non-IMAP wrapper class doesn't exist (URL::HTTP has no
  # #move), so the wrong-shape call raises NoMethodError up front — before any
  # connection attempt — the same kind of static rejection the old
  # URL.move(scheme://...) did with a custom URL::Error message.
  assert_raise(NoMethodError) do
    URL("http://127.0.0.1:1/x").move(uid: 1, to: "y")
  end

  # An unknown / unbuilt scheme is rejected by URL() itself before a wrapper
  # is even built — that's URL::Error.
  err = assert_raise(URL::Error) do
    URL("zzz://127.0.0.1:1/x").expunge
  end
  assert_include err.message, "unsupported scheme"
end

assert('netrc options pass through; optional + missing file falls back') do
  # :netrc maps to CURL_NETRC_OPTIONAL; a missing netrc file means no creds are
  # loaded, so the (no-auth) echo request still succeeds.
  r = URL("#{$base}/echo").get(netrc: true, netrc_file: "/nonexistent-netrc-xyz")
  assert_true r.success?
  assert_equal 'GET', r.json['method']
end

# ---- WebSocket ------------------------------------------------------------
# Gated on a ws-capable libcurl (some distro builds omit the protocol) and the
# local echo fixture. Drives the same paths as examples/websocket.rb.

proto_assert('URL.websocket text echo round-trip', 'ws', $ws_port) do
  ws = URL("ws://127.0.0.1:#{$ws_port}/").connect
  assert_true ws.open?
  assert_nil  ws.error
  ws.send('hello ws')
  msg = ws.receive(timeout: 5)
  assert_false msg.nil?
  assert_true  msg.text?
  assert_equal 'hello ws', msg.data
  ws.close
  assert_true ws.closed?
end

proto_assert('URL.websocket binary echo round-trip', 'ws', $ws_port) do
  ws = URL("ws://127.0.0.1:#{$ws_port}/").connect
  payload = "\x00\x01\x02\x03\xfe\xff"
  ws.send(payload)
  msg = ws.receive(timeout: 5)
  assert_true  msg.binary?
  assert_equal payload, msg.data
  ws.close
end

proto_assert('URL.websocket #send auto-detects text vs binary frames', 'ws', $ws_port) do
  # The payload decides the frame type — valid UTF-8 goes out as a TEXT frame,
  # anything else as BINARY (String#is_utf8? from mruby-string-is-utf8).
  ws = URL("ws://127.0.0.1:#{$ws_port}/").connect
  ws.send('héllo utf8')
  msg = ws.receive(timeout: 5)
  assert_true  msg.text?
  assert_equal 'héllo utf8', msg.data

  raw = "\xfe\xff\x00\x01"
  ws.send(raw)
  msg = ws.receive(timeout: 5)
  assert_true  msg.binary?
  assert_equal raw, msg.data
  ws.close
end

proto_assert('URL.websocket block form yields a live socket then closes it', 'ws', $ws_port) do
  got = nil
  ws = URL("ws://127.0.0.1:#{$ws_port}/").connect do |w|
    assert_true w.open?
    w.send('blocky')
    got = w.receive(timeout: 5)
  end
  assert_equal 'blocky', got.data
  assert_true ws.closed?
end

proto_assert('URL.websocket coexists with a parallel batch on the one loop', 'ws', $ws_port) do
  # An open socket no longer starves — or is starved by — the parallel driver:
  # both ride the same internal loop. The echo sent before the batch is
  # serviced (and buffered) while parallel_perform drives its transfers, so
  # the receive afterwards finds it waiting.
  ws = URL("ws://127.0.0.1:#{$ws_port}/").connect
  ws.send('during-batch')
  codes = []
  URL("#{$base}/echo").parallel(:get)     { |r| codes << r.code }
  URL("#{$base}/slow/300").parallel(:get) { |r| codes << r.code }
  URL.parallel_perform
  msg = ws.receive(timeout: 5.s)
  assert_equal 2, codes.size
  assert_equal 'during-batch', msg.data
  ws.close
end

proto_assert('ws.receive inside a parallel handler keeps the batch moving', 'ws', $ws_port) do
  # Waiting on a websocket from within a handler pumps the same loop that
  # drives the remaining transfers — nothing deadlocks, nothing stalls.
  ws = URL("ws://127.0.0.1:#{$ws_port}/").connect
  order = []
  URL("#{$base}/slow/300").parallel(:get) { |_r| order << :slow }
  URL("#{$base}/echo").parallel(:get) do |_r|
    order << :fast
    ws.send('from-handler')
    msg = ws.receive(timeout: 5.s)
    order << ((msg && msg.data == 'from-handler') ? :ws : :ws_failed)
  end
  URL.parallel_perform
  assert_equal :fast, order.first        # completion order still holds
  assert_true  order.include?(:ws)       # the in-handler receive got its echo
  assert_true  order.include?(:slow)     # and the slow transfer still landed
  assert_false order.include?(:ws_failed)
  ws.close
end

proto_assert('URL.websocket failed upgrade is a value, not a raise', 'ws', $ws_port) do
  # Point ws:// at the plain HTTP server: it answers with a normal response,
  # never a 101, so the handshake fails. That is a value on #error.
  ws = URL("ws://127.0.0.1:#{$server_port}/echo").connect
  assert_false ws.open?
  assert_true  ws.error.is_a?(URL::TransferError)
  assert_nil   ws.send('x')             # no-op on a closed socket, never raises
  assert_nil   ws.receive(timeout: 0)
end

# ---- non-HTTP protocols ---------------------------------------------------
# Each test announces itself as Skipped (with the reason) in the report when the
# embedded libcurl lacks the scheme or the fixture's server for it didn't come
# up — instead of silently vanishing. Same idea as curl's own suite.

file_url_f = File.join($state_dir, 'file_url')
$file_url  = File.exist?(file_url_f) ? File.read(file_url_f).strip : nil

proto_assert('URL.download file://', 'file', $file_url) do
  assert_equal "file-protocol-body\n", URL($file_url).download.body
end
proto_assert('URL.download file:// missing is a value', 'file', $file_url) do
  assert_false URL("#{$file_url}.nope").download.error.nil?
end

proto_assert('URL.download ftp', 'ftp', $ftp_port) do
  assert_equal "ftp-hello\nline2\n", URL("ftp://user:pass@127.0.0.1:#{$ftp_port}/hello.txt").download.body
end
proto_assert('URL.list ftp directory', 'ftp', $ftp_port) do
  assert_equal %w[hello.txt second.txt], URL("ftp://user:pass@127.0.0.1:#{$ftp_port}/").list.lines.sort
end
proto_assert('URL.upload ftp round-trip', 'ftp', $ftp_port) do
  base = "ftp://user:pass@127.0.0.1:#{$ftp_port}"
  URL("#{base}/uploaded.txt").upload("payload-123\n")
  assert_equal "payload-123\n", URL("#{base}/uploaded.txt").download.body
end

proto_assert('URL.upload accepts an IO (File)', 'ftp', $ftp_port) do
  base = "ftp://user:pass@127.0.0.1:#{$ftp_port}"
  # Write the fixture into the run-state dir, not a hardcoded /tmp (absent on
  # Windows). $state_dir is the platform-correct throwaway dir resolved up top.
  path = File.join($state_dir, "upload-fixture.txt")
  body = "from-file-io\nline2\n"
  File.open(path, "wb") { |f| f.write(body) }
  File.open(path, "rb") { |f| URL("#{base}/io.txt").upload(f) }
  (File.unlink(path) rescue nil)
  assert_equal body, URL("#{base}/io.txt").download.body
end

proto_assert('URL.upload accepts a Proc (chunked source)', 'ftp', $ftp_port) do
  base   = "ftp://user:pass@127.0.0.1:#{$ftp_port}"
  chunks = ["from-proc-", "second-", "third-end\n"]
  expect = chunks.join
  proc   = lambda { |_max| chunks.shift || "" }
  URL("#{base}/proc.txt").upload(proc)
  assert_equal expect, URL("#{base}/proc.txt").download.body
end

proto_assert('URL.upload accepts an Enumerable (Array of chunks)', 'ftp', $ftp_port) do
  base   = "ftp://user:pass@127.0.0.1:#{$ftp_port}"
  parts  = ["enum-a-", "enum-b-", "enum-c-end\n"]
  URL("#{base}/enum.txt").upload(parts)
  assert_equal parts.join, URL("#{base}/enum.txt").download.body
end

proto_assert('URL.upload accepts a Fiber yielding chunks', 'ftp', $ftp_port) do
  base = "ftp://user:pass@127.0.0.1:#{$ftp_port}"
  expect = "fib-A-fib-B-fib-C-end\n"
  fib = Fiber.new do
    Fiber.yield "fib-A-"
    Fiber.yield "fib-B-"
    Fiber.yield "fib-C-end\n"
    nil
  end
  URL("#{base}/fib.txt").upload(fib)
  assert_equal expect, URL("#{base}/fib.txt").download.body
end

proto_assert('URL.download ftp missing file is a value', 'ftp', $ftp_port) do
  r = URL("ftp://user:pass@127.0.0.1:#{$ftp_port}/nope.txt").download
  assert_false r.error.nil?
  assert_true  r.error.is_a?(URL::TransferError)
end

proto_assert('URL.lookup dict', 'dict', $dict_port) do
  r = URL("dict://127.0.0.1:#{$dict_port}").define('mruby')
  assert_true r.error.nil?
  assert_include r.body, 'mruby: a test definition.'
end

proto_assert('URL.download gopher', 'gopher', $gopher_port) do
  assert_include URL("gopher://127.0.0.1:#{$gopher_port}/1/welcome").download.body, 'selector=/welcome'
end

proto_assert('URL.list pop3 messages', 'pop3', $pop3_port) do
  assert_equal ['1 26', '2 26'], URL("pop3://u:p@127.0.0.1:#{$pop3_port}/").list.lines
end
proto_assert('URL.download pop3 message', 'pop3', $pop3_port) do
  assert_equal "Subject: one\r\n\r\nbody one\r\n", URL("pop3://u:p@127.0.0.1:#{$pop3_port}/1").download.body
end

proto_assert('URL.download telnet banner', 'telnet', $telnet_port) do
  r = URL("telnet://127.0.0.1:#{$telnet_port}").download(timeout: 3.s)
  assert_include r.body, 'telnet-banner-hello'
end

proto_assert('URL.rtsp OPTIONS', 'rtsp', $rtsp_port) do
  r = URL("rtsp://127.0.0.1:#{$rtsp_port}/stream").options
  assert_equal 200, r.code
  assert_include r.headers['public'], 'DESCRIBE'
end
proto_assert('URL.rtsp DESCRIBE returns SDP', 'rtsp', $rtsp_port) do
  r = URL("rtsp://127.0.0.1:#{$rtsp_port}/stream").describe
  assert_include r.body, 's=test-stream'
end

proto_assert('URL.download tftp', 'tftp', $tftp_port) do
  assert_equal "tftp-hello-content\n", URL("tftp://127.0.0.1:#{$tftp_port}/hello.txt").download.body
end
proto_assert('URL.upload tftp round-trip', 'tftp', $tftp_port) do
  base = "tftp://127.0.0.1:#{$tftp_port}"
  URL("#{base}/up.txt").upload("tftp-up-data\n")
  assert_equal "tftp-up-data\n", URL("#{base}/up.txt").download.body
end

$sftp_ready = ($sftp_port && $sftp_meta) ? $sftp_port : nil
proto_assert('URL.download sftp', 'sftp', $sftp_ready) do
  user, key, kh, = $sftp_meta
  sopts = { ssh_private_keyfile: key, ssh_knownhosts: kh, userpwd: "#{user}:" }
  assert_equal "sftp-hello\nrow2\n",
    URL("sftp://127.0.0.1:#{$sftp_port}#{File.dirname(key)}/test.txt").download(**sopts).body
end
proto_assert('URL.upload sftp round-trip', 'sftp', $sftp_ready) do
  user, key, kh, = $sftp_meta
  sopts = { ssh_private_keyfile: key, ssh_knownhosts: kh, userpwd: "#{user}:" }
  base = "sftp://127.0.0.1:#{$sftp_port}#{File.dirname(key)}"
  URL("#{base}/up.txt").upload("sftp-up\n", **sopts)
  assert_equal "sftp-up\n", URL("#{base}/up.txt").download(**sopts).body
end
proto_assert('URL.download scp', 'scp', $sftp_ready) do
  user, key, kh, = $sftp_meta
  sopts = { ssh_private_keyfile: key, ssh_knownhosts: kh, userpwd: "#{user}:" }
  assert_equal "sftp-hello\nrow2\n",
    URL("scp://127.0.0.1:#{$sftp_port}#{File.dirname(key)}/test.txt").download(**sopts).body
end

proto_assert('URL.search ldap', 'ldap', $ldap_port) do
  r = URL("ldap://127.0.0.1:#{$ldap_port}/dc=example,dc=com?cn,mail?sub?(objectClass=inetOrgPerson)").search
  assert_true r.error.nil?
  assert_include r.body, 'alice@example.com'
end

proto_assert('URL.publish + URL.subscribe mqtt', 'mqtt', $mqtt_port) do
  r = URL("mqtt://127.0.0.1:#{$mqtt_port}/test/topic").subscribe(timeout: 2500.ms)
  assert_equal 'mqtt-retained', r.body
  assert_true URL("mqtt://127.0.0.1:#{$mqtt_port}/test/pub").publish('hello').error.nil?
end

# ---- TLS variants (self-signed cert; verification disabled) ----------------
NOVERIFY = { ssl_verify_peer: false, ssl_verify_host: false }.freeze

proto_assert('URL.download ftps (TLS control + data)', 'ftps', $ftps_port) do
  assert_equal "ftp-hello\nline2\n",
    URL("ftps://user:pass@127.0.0.1:#{$ftps_port}/hello.txt").download(**NOVERIFY).body
end
proto_assert('URL.list ftps', 'ftps', $ftps_port) do
  assert_include URL("ftps://user:pass@127.0.0.1:#{$ftps_port}/").list(**NOVERIFY).lines, 'hello.txt'
end

proto_assert('URL.download pop3s message', 'pop3s', $pop3s_port) do
  r = URL("pop3s://u:p@127.0.0.1:#{$pop3s_port}/1").download(**NOVERIFY)
  assert_equal "Subject: one\r\n\r\nbody one\r\n", r.body
end

proto_assert('URL.download gophers', 'gophers', $gophers_port) do
  r = URL("gophers://127.0.0.1:#{$gophers_port}/1/sec").download(**NOVERIFY)
  assert_include r.body, 'selector=/sec'
end

proto_assert('URL.search ldaps', 'ldaps', $ldaps_port) do
  r = URL("ldaps://127.0.0.1:#{$ldaps_port}/dc=example,dc=com?mail?sub?(cn=Alice)").search(**NOVERIFY)
  assert_include r.body, 'alice@example.com'
end

proto_assert('URL.subscribe mqtts', 'mqtts', $mqtts_port) do
  r = URL("mqtts://127.0.0.1:#{$mqtts_port}/test/topic").subscribe(timeout: 2500.ms, **NOVERIFY)
  assert_equal 'mqtt-retained', r.body
end
