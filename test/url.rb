# test/url_test.rb — runs under mruby, parent of test/server.rb.
#
# IO.popen with "r+" gives us a duplex IO: parent's write end is child's
# STDIN, parent's read end is child's STDOUT. We never write — we just
# hold the pipe open. When this process exits, the write end closes,
# the child's STDIN.read returns, and the child exits. No cleanup.

port_file = File.expand_path('server_port', File.dirname(__FILE__))
unless File.exist?(port_file)
  return "#{port_file} missing — run via 'rake test', not mrbtest directly"
end
$server_port = File.read(port_file).strip.to_i
$base        = "http://127.0.0.1:#{$server_port}"

smtp_port_file = File.expand_path('smtp_port', File.dirname(__FILE__))
$smtp_port     = File.exist?(smtp_port_file) ? File.read(smtp_port_file).strip.to_i : nil
$smtp_received = File.expand_path('smtp_received', File.dirname(__FILE__))

imap_port_file = File.expand_path('imap_port', File.dirname(__FILE__))
$imap_port     = File.exist?(imap_port_file) ? File.read(imap_port_file).strip.to_i : nil
$imap_received = File.expand_path('imap_received', File.dirname(__FILE__))

# ---- assertions -----------------------------------------------------------

assert('URL.get echo') do
  r = URL.get("#{$base}/echo", params: { a: '1', b: 'x y' })
  assert_true r.success?
  j = r.json
  assert_equal 'GET',         j['method']
  assert_equal '1',           j['query']['a']
  assert_equal 'x y',         j['query']['b']
end

assert('URL.post json') do
  r = URL.post("#{$base}/echo", json: { name: 'Alice' })
  assert_true r.success?
  j = r.json
  assert_equal 'POST',                    j['method']
  assert_equal 'application/json',        j['headers']['content-type']
  assert_equal '{"name":"Alice"}',        j['body']
end

assert('URL.post form') do
  r = URL.post("#{$base}/echo", form: { name: 'Alice', tags: %w[a b] })
  j = r.json
  assert_equal 'application/x-www-form-urlencoded', j['headers']['content-type']
  assert_include j['body'], 'name=Alice'
  assert_include j['body'], 'tags=a'
  assert_include j['body'], 'tags=b'
end

assert('URL.get bearer + custom headers') do
  r = URL.get("#{$base}/echo",
              bearer:  'secret',
              headers: { 'X-Custom' => 'yes', 'User-Agent' => 'override' })
  j = r.json
  assert_equal 'Bearer secret', j['headers']['authorization']
  assert_equal 'yes',           j['headers']['x-custom']
  assert_equal 'override',      j['headers']['user-agent']
end

assert('redirects followed by default') do
  r = URL.get("#{$base}/redirect/3")
  assert_true r.success?
  assert_include r.effective_url, '/echo'
end

assert('status codes classify correctly') do
  assert_true  URL.get("#{$base}/status/204").success?
  assert_true  URL.get("#{$base}/status/404").client_error?
  assert_true  URL.get("#{$base}/status/503").server_error?
  assert_true  URL.get("#{$base}/status/503").error?
end

assert('raise_for_status!') do
  err = assert_raise(URL::HTTPError) do
    URL.get("#{$base}/status/500").raise_for_status!
  end
  assert_equal 500, err.response.code
end

assert('timeout produces decorated error') do
  r = URL.get("#{$base}/slow/2000", timeout_ms: 100)
  assert_true r.error?
  assert_equal 28, r.error_code           # CURLE_OPERATION_TIMEDOUT
  assert_include r.error_message, 'timed out'
end

assert('gzip route reachable') do
  r = URL.get("#{$base}/gzip")
  assert_equal 'gzip', r['content-encoding']
  assert_true r.body.bytesize > 0
  # First two bytes of any gzip stream are the magic 1f 8b
  assert_equal "\x1f\x8b".b, r.body.byteslice(0, 2).b
end

assert('streaming block bypasses response body') do
  chunks = []
  r = URL.get("#{$base}/big/65536") { |c| chunks << c }
  assert_equal '', r.body
  total = 0
  chunks.each { |c| total += c.bytesize }
  assert_equal 65536, total
end

assert('multi-valued header merges into array') do
  r = URL.get("#{$base}/multi-cookie")
  cookies = r.set_cookies
  assert_kind_of Array, cookies
  assert_equal 2, cookies.length
end

assert('top-level calls reuse the shared session') do
  before = URL.shared
  r = URL.get("#{$base}/echo")
  assert_true r.success?
  assert_true URL.shared.equal?(before)   # same session object, pool reused
end

assert('URL.get inside a callback transparently uses a fresh session') do
  nested = nil
  outer = URL.get("#{$base}/big/1024") do |_chunk|
    # We're inside the shared session's write callback: it can't drive a
    # second transfer. The hybrid dispatch must hand this call a fresh one.
    nested ||= URL.get("#{$base}/echo")
  end
  assert_equal '', outer.body                 # outer body was streamed away
  assert_kind_of URL::Response, nested
  assert_true nested.success?
  assert_equal 'GET', nested.json['method']
end

# ---- SMTPS via URL.send: the upload/read path on an RFC-named verb ---------

assert('URL.send over SMTPS delivers the envelope and body') do
  skip "libcurl built without smtps"  unless URL.supports?("smtps")
  skip "no smtp test server"          unless $smtp_port

  resp = URL.send(
    "smtps://127.0.0.1:#{$smtp_port}",
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
    resp = URL.send(
      "smtps://127.0.0.1:#{$smtp_port}",
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
    URL.send("zzz://127.0.0.1:1", "hi", from: "a@x", to: "b@x")
  end
  assert_include err.message, "not available"
end

# ---- IMAPS: the RFC-verb dispatch (move / store / expunge / fetch) ---------

assert('URL.store + URL.expunge perform the IMAP delete flow') do
  skip "libcurl built without imaps" unless URL.supports?("imaps")
  skip "no imap test server"         unless $imap_port

  base = "imaps://user:pass@127.0.0.1:#{$imap_port}/INBOX"

  sresp = URL.store(base, uid: 7, flags: "\\Deleted",
                    ssl_verify_peer: false, ssl_verify_host: false)
  assert_kind_of URL::Response, sresp
  assert_equal 0, sresp.error_code

  eresp = URL.expunge(base, ssl_verify_peer: false, ssl_verify_host: false)
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
  resp = URL.move(base, uid: 9, to: "Archive",
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
  resp = URL.fetch(base, uid: 2,
                   ssl_verify_peer: false, ssl_verify_host: false)
  assert_kind_of URL::Response, resp
  assert_equal 0, resp.error_code
  assert_include resp.body, "This is the fixture message body."

  # A streaming block receives the bytes instead of buffering them.
  streamed = ""
  bresp = URL.fetch(base, uid: 2,
                    ssl_verify_peer: false, ssl_verify_host: false) { |c| streamed << c }
  assert_equal "", bresp.body
  assert_include streamed, "This is the fixture message body."
end

assert('IMAP verbs gate unavailable / unknown schemes') do
  # An IMAP verb on a non-IMAP scheme raises before any connection attempt.
  err = assert_raise(URL::Error) do
    URL.move("http://127.0.0.1:1/x", uid: 1, to: "y")
  end
  assert_include err.message, "not available"

  err2 = assert_raise(URL::Error) do
    URL.expunge("zzz://127.0.0.1:1/x")
  end
  assert_include err2.message, "not available"
end

assert('netrc options pass through; optional + missing file falls back') do
  # :netrc maps to CURL_NETRC_OPTIONAL; a missing netrc file means no creds are
  # loaded, so the (no-auth) echo request still succeeds.
  r = URL.get("#{$base}/echo", netrc: true, netrc_file: "/nonexistent-netrc-xyz")
  assert_true r.success?
  assert_equal 'GET', r.json['method']
end
