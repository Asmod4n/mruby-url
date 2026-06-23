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

assert('netrc options pass through; optional + missing file falls back') do
  r = URL.get("#{$base}/echo", netrc: true, netrc_file: "/nonexistent-netrc-xyz")
  assert_true r.success?
  assert_equal 'GET', r.json['method']
end
