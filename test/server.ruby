#!/usr/bin/env ruby
# test/server.ruby — runs under MRI, spawned by the project Rakefile as the
# process-group leader for the whole test fixture (sshd/slapd/mosquitto join
# this group). We inherit the Rakefile's own STDIN/STDOUT (no pipe, no
# IO.popen) — the Rakefile's `rake test` task spawns us with `pgroup: true`
# and, in its `ensure` block, sends the group TERM then (after a grace
# period) KILL, which is what actually reaps us and every daemon we spawned.

# All run-state (port files, captured payloads, logs) lives in the throwaway
# directory the Rakefile created and passed to us as ARGV[0]. Failing loudly
# here is fine — the only supported entrypoint is `rake test`.
STATE_DIR = ARGV[0]
if STATE_DIR.nil? || STATE_DIR.empty?
  abort "usage: server.ruby STATE_DIR — run via 'rake test', not this script directly"
end

# Redirect stderr to a log file *first*, so any failure during require or
# server setup is captured. Without this we have no idea why the child died.
$stderr.reopen(File.join(STATE_DIR, 'server.log'), 'w')
$stderr.sync = true

require 'webrick'
require 'json'
require 'zlib'
require 'stringio'
require 'socket'
require 'openssl'
require 'digest'
require 'base64'
require 'fileutils'
require 'tmpdir'

# Defined early so the protocol/daemon fixtures below can announce their ports.
def write_port_atomic(path, value)
  tmp = "#{path}.tmp"
  File.write(tmp, value.to_s)
  File.rename(tmp, path)
end

server = WEBrick::HTTPServer.new(
  BindAddress: '127.0.0.1',
  Port:        18080,
  AccessLog:   [],
  Logger:      WEBrick::Log.new(File::NULL),
)

# ---- routes ---------------------------------------------------------------

# Echo back what we got. Covers params / json / form / auth / bearer / headers.
server.mount_proc('/echo') do |req, res|
  res['Content-Type'] = 'application/json'
  res.body = JSON.dump(
    method:  req.request_method,
    path:    req.path,
    query:   req.query,
    headers: req.header.transform_values { |v| v.length == 1 ? v.first : v },
    body:    req.body,
  )
end

# Multipart upload sink: echoes the Content-Type and the raw multipart body so
# the mruby test can assert the boundary, part names, filenames and payloads
# that curl_mime produced. Covers the `multipart:` (curl_mime) path.
server.mount_proc('/multipart') do |req, res|
  res['Content-Type'] = 'application/json'
  res.body = JSON.dump(
    content_type: req['content-type'],
    body:         req.body.to_s,
  )
end

# /status/418 -> 418, etc. Covers success?/client_error?/server_error?.
# /retry-after/2 -> 503 with "Retry-After: 2", the way overloaded servers ask
# clients to back off. Exercises CURLINFO_RETRY_AFTER -> Response#retry_after.
server.mount_proc('/retry-after') do |req, res|
  res.status = 503
  res['Retry-After'] = req.path.split('/').last
  res.body = 'busy'
end

server.mount_proc('/status') do |req, res|
  res.status = req.path.split('/').last.to_i
  res.body   = ''
end

# /redirect/3 -> /redirect/2 -> ... -> /echo. Covers follow_location.
server.mount_proc('/redirect') do |req, res|
  n = req.path.split('/').last.to_i
  if n <= 0
    res.status = 302
    res['Location'] = '/echo'
  else
    res.status = 302
    res['Location'] = "/redirect/#{n - 1}"
  end
end

# /slow/2000 -> wait 2s then respond. Covers timeout + error_message.
server.mount_proc('/slow') do |req, res|
  ms = req.path.split('/').last.to_i
  sleep(ms / 1000.0)
  res.body = 'ok'
end

# /big/1048576 -> N bytes. Covers streaming-block path.
server.mount_proc('/big') do |req, res|
  n = req.path.split('/').last.to_i
  res['Content-Type'] = 'application/octet-stream'
  res.body = 'x' * n
end

# Gzip-encoded body. Covers libcurl's accept_encoding auto-decompress.
server.mount_proc('/gzip') do |req, res|
  io = StringIO.new
  gz = Zlib::GzipWriter.new(io)
  gz.write('hello gzip')
  gz.close
  res['Content-Type']     = 'text/plain'
  res['Content-Encoding'] = 'gzip'
  res.body = io.string
end

# Two Set-Cookie headers. Covers Response#_parse_headers array-merging.
server.mount_proc('/multi-cookie') do |req, res|
  res.cookies << WEBrick::Cookie.new('a', '1')
  res.cookies << WEBrick::Cookie.new('b', '2')
  res.body = 'ok'
end

# ---- implicit-TLS SMTP server (SMTPS) -------------------------------------
#
# Minimal SMTPS endpoint for the URL.data test. Implicit TLS: the socket
# is wrapped in SSL immediately on accept (no STARTTLS). We speak just enough
# SMTP for libcurl: greet, EHLO, MAIL FROM, RCPT TO, DATA, the dot-terminated
# body, QUIT. The captured envelope + body are appended to test/smtp_received
# so the mruby test can verify what arrived.
#
# Self-signed cert is generated at runtime; the client (curl) is told not to
# verify it (ssl_verify_peer:/ssl_verify_host: false in the test).

received_file = File.join(STATE_DIR, 'smtp_received')
File.unlink(received_file) if File.exist?(received_file)

# Self-signed RSA cert, valid now.
key  = OpenSSL::PKey::RSA.new(2048)
cert = OpenSSL::X509::Certificate.new
cert.version    = 2
cert.serial     = 1
cert.subject    = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
cert.issuer     = cert.subject
cert.public_key = key.public_key
cert.not_before = Time.now - 3600
cert.not_after  = Time.now + 3600
cert.sign(key, OpenSSL::Digest::SHA256.new)

ssl_ctx      = OpenSSL::SSL::SSLContext.new
ssl_ctx.cert = cert
ssl_ctx.key  = key

# Persist the cert/key as PEM files so the daemon-backed TLS variants (ldaps via
# slapd, mqtts via mosquitto) can load them, and keep the dir for fixture state.
tls_dir = File.join(Dir.tmpdir, "mruby-url-tls-#{$$}")
FileUtils.mkdir_p(tls_dir)
CERT_PEM = File.join(tls_dir, 'cert.pem')
KEY_PEM  = File.join(tls_dir, 'key.pem')
File.write(CERT_PEM, cert.to_pem)
File.write(KEY_PEM, key.to_pem)

# Accept loop that wraps each connection in implicit TLS before handing it to a
# protocol handler — the pure-Ruby basis for ftps:// / pop3s:// / gophers://.
def proto_accept_loop_tls(srv, ssl_ctx)
  Thread.new do
    loop do
      begin
        raw = srv.accept
        Thread.new(raw) do |r|
          ssl = nil
          begin
            ssl = OpenSSL::SSL::SSLSocket.new(r, ssl_ctx)
            ssl.sync_close = true
            ssl.accept
            yield ssl
          rescue => e
            $stderr.puts("tls proto error: #{e.class}: #{e.message}")
          ensure
            ssl.close rescue nil
          end
        end
      rescue => e
        $stderr.puts("tls accept error: #{e.class}: #{e.message}")
      end
    end
  end
end

# Ephemeral port; bind now so the port is known before we announce.
smtp_tcp        = TCPServer.new('127.0.0.1', 0)
smtp_port_value = smtp_tcp.addr[1]

# Handle exactly one client per accept; serve in a loop so a flaky connect or
# a second test run doesn't wedge us. Each handled message is appended atomically.
def handle_smtp_session(ssl_sock, received_file)
  line = lambda { |s| ssl_sock.write(s); ssl_sock.write("\r\n") }

  mail_from = nil
  rcpts     = []

  line.call('220 test-smtp ESMTP ready')
  loop do
    req = ssl_sock.gets
    break if req.nil?
    cmd = req.strip

    case cmd
    when /\AEHLO\b/i, /\AHELO\b/i
      ssl_sock.write("250-test-smtp\r\n")
      ssl_sock.write("250 SIZE 10485760\r\n")
    when /\AMAIL FROM:\s*<([^>]*)>/i
      mail_from = $1
      line.call('250 OK')
    when /\ARCPT TO:\s*<([^>]*)>/i
      rcpts << $1
      line.call('250 OK')
    when /\ADATA\b/i
      line.call('354 End data with <CR><LF>.<CR><LF>')
      body = +''
      loop do
        dl = ssl_sock.gets
        break if dl.nil?
        break if dl == ".\r\n" || dl == ".\n"
        # De-stuff a leading dot per RFC 5321 4.5.2.
        dl = dl[1..-1] if dl.start_with?('..')
        body << dl
      end
      File.open(received_file, 'a') do |f|
        f.write("FROM #{mail_from}\n")
        rcpts.each { |r| f.write("RCPT #{r}\n") }
        f.write("BODY-BEGIN\n")
        f.write(body)
        f.write("\nBODY-END\n")
      end
      line.call('250 OK: queued')
    when /\AQUIT\b/i
      line.call('221 Bye')
      break
    when /\ARSET\b/i
      mail_from = nil
      rcpts     = []
      line.call('250 OK')
    when /\ANOOP\b/i
      line.call('250 OK')
    else
      line.call('250 OK')
    end
  end
end

Thread.new do
  loop do
    begin
      raw = smtp_tcp.accept
      ssl = OpenSSL::SSL::SSLSocket.new(raw, ssl_ctx)
      ssl.sync_close = true
      begin
        ssl.accept
        handle_smtp_session(ssl, received_file)
      ensure
        ssl.close rescue nil
      end
    rescue => e
      $stderr.puts("smtp session error: #{e.class}: #{e.message}")
    end
  end
end

# ---- implicit-TLS IMAP server (IMAPS) -------------------------------------
#
# Minimal IMAPS endpoint for the URL IMAP verbs (move/store/expunge/fetch/search).
# Implicit TLS, like the SMTP fixture: the socket is wrapped in SSL on accept
# (no STARTTLS) and the same self-signed cert is reused.
#
# We speak just enough of curl's IMAP client flow: an untagged "* OK" greeting,
# then tagged CAPABILITY / LOGIN (accept any creds) / SELECT (untagged EXISTS +
# OK), then the command under test. curl drives a SELECTed mailbox then either
# issues our -X custom request (UID STORE / EXPUNGE / UID MOVE / UID SEARCH) or,
# for a message fetch, translates the URL's ";UID=<n>" into "UID FETCH <n>
# BODY[]" itself. Each tagged command gets the right untagged response and a
# tagged "OK"; FETCH returns a small literal-counted message body, SEARCH a
# fixed "1 2 3" UID list. Every received command line is appended to
# test/imap_received so the mruby tests can assert.
#
# Self-signed cert generated above; the client (curl/mruby) is told not to
# verify it (ssl_verify_peer:/ssl_verify_host: false in the test).

imap_received_file = File.join(STATE_DIR, 'imap_received')
File.unlink(imap_received_file) if File.exist?(imap_received_file)

IMAP_MESSAGE = "Subject: fixture mail\r\n\r\nThis is the fixture message body.\r\n".freeze

imap_tcp        = TCPServer.new('127.0.0.1', 0)
imap_port_value = imap_tcp.addr[1]

def handle_imap_session(ssl_sock, received_file)
  write = lambda { |s| ssl_sock.write(s); ssl_sock.write("\r\n") }

  write.call('* OK [CAPABILITY IMAP4rev1] test-imap ready')

  loop do
    req = ssl_sock.gets
    break if req.nil?
    cmd_line = req.chomp

    # Record every command line so the tests can assert what arrived.
    File.open(received_file, 'a') { |f| f.write(cmd_line + "\n") }

    # Tagged command: "<tag> <COMMAND> <args...>".
    tag, _, rest = cmd_line.partition(' ')
    verb, _, args = rest.partition(' ')

    case verb.upcase
    when 'CAPABILITY'
      write.call('* CAPABILITY IMAP4rev1')
      write.call("#{tag} OK CAPABILITY completed")
    when 'LOGIN', 'AUTHENTICATE'
      write.call("#{tag} OK #{verb.upcase} completed")
    when 'SELECT', 'EXAMINE'
      write.call('* 3 EXISTS')
      write.call('* 0 RECENT')
      write.call('* OK [UIDVALIDITY 1] UIDs valid')
      write.call('* OK [UIDNEXT 4] Predicted next UID')
      write.call("#{tag} OK [READ-WRITE] #{verb.upcase} completed")
    when 'UID'
      sub, _, sub_args = args.partition(' ')
      uid = sub_args.split(' ').first
      case sub.upcase
      when 'MOVE'
        write.call("#{tag} OK [COPYUID 2 #{uid} #{uid}] UID MOVE completed")
      when 'STORE'
        write.call("* 1 FETCH (UID #{uid} FLAGS (\\Deleted))")
        write.call("#{tag} OK UID STORE completed")
      when 'FETCH'
        write.call("* 1 FETCH (UID #{uid} BODY[] {#{IMAP_MESSAGE.bytesize}}")
        ssl_sock.write(IMAP_MESSAGE)
        ssl_sock.write(")\r\n")
        write.call("#{tag} OK UID FETCH completed")
      when 'SEARCH'
        write.call('* SEARCH 1 2 3')
        write.call("#{tag} OK UID SEARCH completed")
      else
        write.call("#{tag} OK completed")
      end
    when 'EXPUNGE'
      write.call('* 1 EXPUNGE')
      write.call("#{tag} OK EXPUNGE completed")
    when 'LOGOUT'
      write.call('* BYE logging out')
      write.call("#{tag} OK LOGOUT completed")
      break
    when 'NOOP', 'CHECK', 'CLOSE'
      write.call("#{tag} OK #{verb.upcase} completed")
    else
      write.call("#{tag} OK completed")
    end
  end
end

Thread.new do
  loop do
    begin
      raw = imap_tcp.accept
      ssl = OpenSSL::SSL::SSLSocket.new(raw, ssl_ctx)
      ssl.sync_close = true
      begin
        ssl.accept
        handle_imap_session(ssl, imap_received_file)
      ensure
        ssl.close rescue nil
      end
    rescue => e
      $stderr.puts("imap session error: #{e.class}: #{e.message}")
    end
  end
end

# ---- WebSocket echo server (ws://) ----------------------------------------
#
# Minimal RFC 6455 endpoint for the URL.websocket tests: do the upgrade
# handshake (compute Sec-WebSocket-Accept), then echo every data frame back
# with the same opcode, answer PING with PONG, and mirror CLOSE. Client->server
# frames are masked (per spec); server->client frames are not. Just enough to
# exercise send / receive / close end to end — no TLS, plain
# ws:// is enough for the framing path.

WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'.freeze

def ws_handshake(io)
  req = +''
  while (line = io.gets)
    req << line
    break if line == "\r\n" || line == "\n"
  end
  key = req[/Sec-WebSocket-Key:\s*(.+?)\r?\n/i, 1]
  return false unless key
  accept = Base64.strict_encode64(Digest::SHA1.digest(key.strip + WS_GUID))
  io.write("HTTP/1.1 101 Switching Protocols\r\n" \
           "Upgrade: websocket\r\n" \
           "Connection: Upgrade\r\n" \
           "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
  true
end

def ws_read_frame(io)
  hdr = io.read(2)
  return nil if hdr.nil? || hdr.bytesize < 2
  b0, b1 = hdr.bytes
  opcode = b0 & 0x0f
  masked = (b1 & 0x80) != 0
  len    = b1 & 0x7f
  len = io.read(2).unpack1('n')  if len == 126
  len = io.read(8).unpack1('Q>') if len == 127
  mask = masked ? io.read(4).bytes : nil
  payload = len > 0 ? io.read(len) : ''
  return nil if payload.nil? || payload.bytesize < len
  if mask
    pb = payload.bytes
    pb.each_index { |i| pb[i] ^= mask[i % 4] }
    payload = pb.pack('C*')
  end
  [opcode, payload]
end

def ws_write_frame(io, opcode, payload)
  n   = payload.bytesize
  out = [0x80 | opcode]
  if    n < 126   then out << n
  elsif n < 65536 then out << 126; out.concat([n].pack('n').bytes)
  else                 out << 127; out.concat([n].pack('Q>').bytes)
  end
  io.write(out.pack('C*'))
  io.write(payload) if n > 0
end

def handle_ws_session(io)
  return unless ws_handshake(io)
  loop do
    frame = ws_read_frame(io)
    break if frame.nil?
    opcode, payload = frame
    case opcode
    when 0x1, 0x2 then ws_write_frame(io, opcode, payload)  # text/binary -> echo
    when 0x8      then ws_write_frame(io, 0x8, payload); break  # close -> mirror
    when 0x9      then ws_write_frame(io, 0xA, payload)     # ping -> pong
    when 0xA      then nil                                  # pong -> ignore
    end
  end
end

ws_tcp        = TCPServer.new('127.0.0.1', 0)
ws_port_value = ws_tcp.addr[1]

Thread.new do
  loop do
    begin
      conn = ws_tcp.accept
      begin
        handle_ws_session(conn)
      ensure
        conn.close rescue nil
      end
    rescue => e
      $stderr.puts("ws session error: #{e.class}: #{e.message}")
    end
  end
end

# ---- non-HTTP protocol fixtures (pure Ruby) -------------------------------
#
# Small servers for the protocols URL.download/upload/list/lookup/search/rtsp
# drive: FTP, DICT, GOPHER, POP3, TELNET, RTSP (all TCP) and TFTP (UDP). Each
# binds an ephemeral port and its number is written to a test/<proto>_port file
# the mruby tests read; a test is skipped when its port file is absent or the
# embedded libcurl lacks the scheme. Mirrors the SMTP/IMAP fixtures above.

require 'timeout'

def proto_accept_loop(srv)
  Thread.new do
    loop do
      begin
        conn = srv.accept
        Thread.new(conn) { |s| yield s; s.close rescue nil }
      rescue => e
        $stderr.puts("proto session error: #{e.class}: #{e.message}")
      end
    end
  end
end

# --- FTP ---
ftp_root = File.join(Dir.tmpdir, "mruby-url-ftp-#{$$}")
FileUtils.mkdir_p(ftp_root)
# binwrite so newlines stay LF on Windows (text-mode File.write would turn the
# fixture content into CRLF and the byte-exact download assertions would fail).
File.binwrite(File.join(ftp_root, 'hello.txt'), "ftp-hello\nline2\n")
File.binwrite(File.join(ftp_root, 'second.txt'), "second\n")

# A plain file for file:// (outside ftp_root so it doesn't show up in FTP
# listings) — record the platform-correct URL for the test to read (curl wants
# file:///abs/path, file:///C:/... on Windows).
file_fixture = File.join(Dir.tmpdir, "mruby-url-file-#{$$}.txt")
File.binwrite(file_fixture, "file-protocol-body\n")
abs = file_fixture.tr('\\', '/')
abs = "/#{abs}" unless abs.start_with?('/')
File.write(File.join(STATE_DIR, 'file_url'), "file://#{abs}")

# `data_ssl`, when given, wraps each passive data connection in TLS (PROT P) —
# the only extra needed to serve implicit ftps:// alongside plain ftp://.
def handle_ftp(sock, root, data_ssl = nil)
  sock.write("220 test-ftp ready\r\n")
  dsrv = nil
  data_accept = lambda do
    ds = dsrv.accept
    if data_ssl
      ds = OpenSSL::SSL::SSLSocket.new(ds, data_ssl); ds.sync_close = true; ds.accept
    end
    ds
  end
  loop do
    line = sock.gets or break
    cmd, arg = line.strip.split(' ', 2)
    case (cmd || '').upcase
    when 'USER' then sock.write("331 need pass\r\n")
    when 'PASS' then sock.write("230 ok\r\n")
    when 'SYST' then sock.write("215 UNIX Type: L8\r\n")
    when 'FEAT' then sock.write("211-Features\r\n EPSV\r\n PBSZ\r\n PROT\r\n211 End\r\n")
    when 'AUTH' then sock.write("234 proceed\r\n")    # explicit-TLS path (unused by implicit)
    when 'PBSZ' then sock.write("200 ok\r\n")
    when 'PROT' then sock.write("200 ok\r\n")
    when 'PWD'  then sock.write("257 \"/\"\r\n")
    when 'TYPE' then sock.write("200 ok\r\n")
    when 'CWD'  then sock.write("250 ok\r\n")
    when 'SIZE'
      p = File.join(root, File.basename(arg.to_s))
      sock.write(File.file?(p) ? "213 #{File.size(p)}\r\n" : "550 no\r\n")
    when 'EPSV'
      dsrv = TCPServer.new('127.0.0.1', 0)
      sock.write("229 Entering Extended Passive Mode (|||#{dsrv.addr[1]}|)\r\n")
    when 'PASV'
      dsrv = TCPServer.new('127.0.0.1', 0); dp = dsrv.addr[1]
      sock.write("227 Entering Passive Mode (127,0,0,1,#{dp / 256},#{dp % 256})\r\n")
    when 'NLST', 'LIST'
      sock.write("150 listing\r\n"); ds = data_accept.call
      names = Dir.children(root).sort
      body = (cmd.upcase == 'NLST') ? names.map { |e| "#{e}\r\n" }.join :
        names.map { |e| "-rw-r--r-- 1 u u #{File.size(File.join(root, e))} Jan 01 00:00 #{e}\r\n" }.join
      ds.write(body); ds.close; dsrv.close; dsrv = nil
      sock.write("226 done\r\n")
    when 'RETR'
      p = File.join(root, File.basename(arg.to_s))
      if File.file?(p)
        sock.write("150 opening\r\n"); ds = data_accept.call
        ds.write(File.binread(p)); ds.close; dsrv.close; dsrv = nil
        sock.write("226 complete\r\n")
      else
        sock.write("550 not found\r\n")
      end
    when 'STOR'
      sock.write("150 ready\r\n"); ds = data_accept.call
      File.binwrite(File.join(root, File.basename(arg.to_s)), ds.read)
      ds.close; dsrv.close; dsrv = nil
      sock.write("226 stored\r\n")
    when 'QUIT' then sock.write("221 bye\r\n"); break
    else sock.write("200 ok\r\n")
    end
  end
end

# --- DICT ---
def handle_dict(sock)
  sock.write("220 test-dict <mime> <1@test>\r\n")
  loop do
    line = sock.gets or break
    s = line.strip; up = s.upcase
    if up.start_with?('CLIENT') then sock.write("250 ok\r\n")
    elsif up.start_with?('DEFINE')
      word = s.split(' ', 3)[2].to_s
      sock.write("150 1 definitions retrieved\r\n")
      sock.write("151 \"#{word}\" testdb \"Test\"\r\n#{word}: a test definition.\r\n.\r\n250 ok\r\n")
    elsif up.start_with?('QUIT') then sock.write("221 bye\r\n"); break
    else sock.write("500 unknown\r\n")
    end
  end
end

# --- GOPHER ---
def handle_gopher(sock)
  sel = (sock.gets || '').strip
  sock.write("gopher-doc for selector=#{sel}\r\n.\r\n")
end

# --- POP3 ---
POP3_MSGS = { '1' => "Subject: one\r\n\r\nbody one\r\n", '2' => "Subject: two\r\n\r\nbody two\r\n" }.freeze
def handle_pop3(sock)
  sock.write("+OK test-pop3 ready\r\n")
  loop do
    line = sock.gets or break
    s = line.strip; up = s.upcase
    if up == 'CAPA' then sock.write("+OK\r\nUSER\r\nUIDL\r\nTOP\r\n.\r\n")
    elsif up.start_with?('USER', 'PASS') then sock.write("+OK\r\n")
    elsif up.start_with?('STAT') then sock.write("+OK 2 100\r\n")
    elsif up.start_with?('LIST')
      sock.write("+OK 2 messages\r\n1 #{POP3_MSGS['1'].bytesize}\r\n2 #{POP3_MSGS['2'].bytesize}\r\n.\r\n")
    elsif up.start_with?('UIDL') then sock.write("+OK\r\n1 uid1\r\n2 uid2\r\n.\r\n")
    elsif up.start_with?('RETR')
      m = POP3_MSGS[s.split(' ')[1]].to_s
      sock.write("+OK #{m.bytesize} octets\r\n#{m}.\r\n")
    elsif up.start_with?('QUIT') then sock.write("+OK bye\r\n"); break
    else sock.write("+OK\r\n")
    end
  end
end

# --- TELNET ---
def handle_telnet(sock)
  begin
    Timeout.timeout(0.3) { sock.recv(64) }
  rescue Exception
  end
  sock.write("telnet-banner-hello\r\n")
end

# --- RTSP ---
def handle_rtsp(sock)
  loop do
    req = +''
    until req.include?("\r\n\r\n")
      line = sock.gets or return
      req << line
    end
    method = req.split(' ', 2)[0]
    cseq = (req[/CSeq:\s*(\d+)/i, 1] || '0')
    if method == 'DESCRIBE'
      sdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=test-stream\r\n"
      sock.write("RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nContent-Type: application/sdp\r\nContent-Length: #{sdp.bytesize}\r\n\r\n#{sdp}")
    else
      sock.write("RTSP/1.0 200 OK\r\nCSeq: #{cseq}\r\nPublic: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN\r\n\r\n")
    end
  end
end

# --- TFTP (UDP) ---
TFTP_FILES = { 'hello.txt' => "tftp-hello-content\n" }
def handle_tftp(data, addr, usock)
  op = data[0, 2].unpack1('n')
  fname = data[2..].split("\x00")[0]
  ds = UDPSocket.new; ds.bind('127.0.0.1', 0)
  cip = addr[3]; cport = addr[1]
  if op == 1 # RRQ
    content = (TFTP_FILES[fname] || '').b; blk = 1; i = 0
    loop do
      chunk = content[i, 512] || ''.b
      ds.send([3, blk].pack('nn') + chunk, 0, cip, cport)
      begin
        Timeout.timeout(2) { _, a = ds.recvfrom(64); cip = a[3]; cport = a[1] }
      rescue Exception then break end
      i += 512; blk += 1
      break if chunk.bytesize < 512
    end
  elsif op == 2 # WRQ
    ds.send([4, 0].pack('nn'), 0, cip, cport); buf = ''.b
    loop do
      begin
        d = a = nil
        Timeout.timeout(2) { d, a = ds.recvfrom(2048) }
      rescue Exception then break end
      b = d[2, 2].unpack1('n'); payload = d[4..] || ''.b; buf << payload
      ds.send([4, b].pack('nn'), 0, a[3], a[1])
      break if payload.bytesize < 512
    end
    TFTP_FILES[fname] = buf
  end
  ds.close
end

# Bind ephemeral TCP ports and start each handler.
ftp_srv    = TCPServer.new('127.0.0.1', 0)
dict_srv   = TCPServer.new('127.0.0.1', 0)
gopher_srv = TCPServer.new('127.0.0.1', 0)
pop3_srv   = TCPServer.new('127.0.0.1', 0)
telnet_srv = TCPServer.new('127.0.0.1', 0)
rtsp_srv   = TCPServer.new('127.0.0.1', 0)
proto_accept_loop(ftp_srv)    { |s| handle_ftp(s, ftp_root) }
proto_accept_loop(dict_srv)   { |s| handle_dict(s) }
proto_accept_loop(gopher_srv) { |s| handle_gopher(s) }
proto_accept_loop(pop3_srv)   { |s| handle_pop3(s) }
proto_accept_loop(telnet_srv) { |s| handle_telnet(s) }
proto_accept_loop(rtsp_srv)   { |s| handle_rtsp(s) }

# Implicit-TLS variants (ftps / pop3s / gophers): same handlers behind a TLS
# accept. ftps also wraps its data channel (PROT P) with the same context.
ftps_srv   = TCPServer.new('127.0.0.1', 0)
pop3s_srv  = TCPServer.new('127.0.0.1', 0)
gophers_srv = TCPServer.new('127.0.0.1', 0)
proto_accept_loop_tls(ftps_srv, ssl_ctx)    { |s| handle_ftp(s, ftp_root, ssl_ctx) }
proto_accept_loop_tls(pop3s_srv, ssl_ctx)   { |s| handle_pop3(s) }
proto_accept_loop_tls(gophers_srv, ssl_ctx) { |s| handle_gopher(s) }

# TFTP over UDP.
tftp_usock = UDPSocket.new; tftp_usock.bind('127.0.0.1', 0)
tftp_port_value = tftp_usock.addr[1]
Thread.new do
  loop do
    begin
      data, addr = tftp_usock.recvfrom(2048)
      Thread.new { handle_tftp(data, addr, tftp_usock) }
    rescue => e
      $stderr.puts("tftp error: #{e.class}: #{e.message}")
    end
  end
end

# ---- daemon-backed protocols (sftp/scp, ldap, mqtt) -----------------------
#
# These need real servers (OpenSSH, OpenLDAP, mosquitto). When the binaries are
# present we spin each up in a temp dir on an ephemeral port and write its port
# file (plus, for SSH, the client key + known_hosts the tests pass to curl). On
# any platform/host without the binary — e.g. the Windows Schannel build, which
# also lacks sftp/scp/ldap in libcurl — the port file is simply absent and the
# matching tests skip. Best-effort: a setup failure is logged and skipped, never
# fatal to the rest of the suite.
#
# Every spawn/system call below is given `in: File::NULL`. Without it these
# processes inherit our own STDIN, which — per the header comment — is
# whatever STDIN the Rakefile's `rake test` was itself run with (a real
# terminal in interactive use). A leftover key file from a reused proto_dir
# (PID reuse across runs piling up in Dir.tmpdir) makes ssh-keygen prompt to
# overwrite; with stdout/stderr already sent to File::NULL that prompt is
# invisible, and it blocks reading the terminal's STDIN forever instead of
# hitting EOF — a silent, unkillable-looking hang with an empty log and no
# visible prompt to answer.

def which(bin)
  ENV['PATH'].to_s.split(File::PATH_SEPARATOR).each do |d|
    %W[#{d}/#{bin} /usr/sbin/#{bin} /usr/lib/openssh/#{bin}].each do |p|
      return p if File.executable?(p)
    end
  end
  ['/usr/sbin/' + bin, '/usr/lib/openssh/' + bin].find { |p| File.executable?(p) }
end

proto_dir = File.join(Dir.tmpdir, "mruby-url-proto-#{$$}")
FileUtils.mkdir_p(proto_dir)
child_pids = []

# --- SSH (sftp/scp) ---
begin
  sshd = which('sshd')
  if sshd && which('ssh-keygen')
    sd = File.join(proto_dir, 'ssh'); FileUtils.mkdir_p(sd)
    system('ssh-keygen', '-q', '-t', 'ed25519', '-f', "#{sd}/host", '-N', '', in: File::NULL, out: File::NULL, err: File::NULL)
    system('ssh-keygen', '-q', '-t', 'ed25519', '-f', "#{sd}/client", '-N', '', in: File::NULL, out: File::NULL, err: File::NULL)
    File.binwrite("#{sd}/test.txt", "sftp-hello\nrow2\n")
    File.write("#{sd}/authorized_keys", File.read("#{sd}/client.pub"))
    File.chmod(0600, "#{sd}/authorized_keys")
    ssh_user = ENV['USER'] || 'root'
    ssh_port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    File.write("#{sd}/sshd_config", <<~CFG)
      Port #{ssh_port}
      ListenAddress 127.0.0.1
      HostKey #{sd}/host
      PidFile #{sd}/sshd.pid
      AuthorizedKeysFile #{sd}/authorized_keys
      UsePAM no
      PasswordAuthentication no
      PubkeyAuthentication yes
      Subsystem sftp internal-sftp
      StrictModes no
    CFG
    FileUtils.mkdir_p('/run/sshd') rescue nil
    # -D keeps sshd in the foreground so it stays in our process group and gets
    # reaped with it; without it sshd setsid()s away and would leak.
    ssh_pid = spawn(sshd, '-D', '-f', "#{sd}/sshd_config", '-E', "#{sd}/sshd.log", in: File::NULL)
    child_pids << ssh_pid
    sleep 0.5
    kh = `ssh-keyscan -p #{ssh_port} -t ed25519 127.0.0.1 2>/dev/null </dev/null`
    if !kh.strip.empty?
      File.write("#{sd}/known_hosts", kh)
      write_port_atomic(File.join(STATE_DIR, 'sftp_port'), ssh_port)
      File.write(File.join(STATE_DIR, 'sftp_meta'), "#{ssh_user}\n#{sd}/client\n#{sd}/known_hosts\n#{sd}/test.txt\n")
    end
  end
rescue => e
  $stderr.puts("sshd setup skipped: #{e.class}: #{e.message}")
end

# --- LDAP (slapd) ---
begin
  slapd = which('slapd')
  schema = '/etc/ldap/schema'
  if slapd && File.directory?(schema) && File.exist?("#{schema}/core.schema")
    ld = File.join(proto_dir, 'ldap'); FileUtils.mkdir_p("#{ld}/data")
    modpath = ['/usr/lib/ldap', '/usr/lib/openldap'].find { |p| File.exist?("#{p}/back_mdb.so") || !Dir.glob("#{p}/back_mdb*").empty? }
    File.write("#{ld}/slapd.conf", <<~CFG)
      include #{schema}/core.schema
      include #{schema}/cosine.schema
      include #{schema}/inetorgperson.schema
      #{modpath ? "modulepath #{modpath}\nmoduleload back_mdb" : ''}
      pidfile #{ld}/slapd.pid
      TLSCertificateFile #{CERT_PEM}
      TLSCertificateKeyFile #{KEY_PEM}
      database mdb
      suffix "dc=example,dc=com"
      rootdn "cn=admin,dc=example,dc=com"
      rootpw secret
      directory #{ld}/data
    CFG
    File.write("#{ld}/data.ldif", <<~LDIF)
      dn: dc=example,dc=com
      objectClass: dcObject
      objectClass: organization
      o: Example Org
      dc: example

      dn: cn=Alice,dc=example,dc=com
      objectClass: inetOrgPerson
      cn: Alice
      sn: Smith
      mail: alice@example.com
    LDIF
    slapadd = which('slapadd') || '/usr/sbin/slapadd'
    if system(slapadd, '-f', "#{ld}/slapd.conf", '-l', "#{ld}/data.ldif", in: File::NULL, out: File::NULL, err: File::NULL)
      ldap_port  = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
      ldaps_port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
      pid = spawn(slapd, '-f', "#{ld}/slapd.conf",
                  '-h', "ldap://127.0.0.1:#{ldap_port}/ ldaps://127.0.0.1:#{ldaps_port}/",
                  '-d', '0', in: File::NULL, out: "#{ld}/slapd.log", err: "#{ld}/slapd.log")
      child_pids << pid
      sleep 0.7
      write_port_atomic(File.join(STATE_DIR, 'ldap_port'), ldap_port)
      write_port_atomic(File.join(STATE_DIR, 'ldaps_port'), ldaps_port)
    end
  end
rescue => e
  $stderr.puts("slapd setup skipped: #{e.class}: #{e.message}")
end

# --- MQTT (mosquitto) ---
begin
  mosq = which('mosquitto')
  if mosq
    md = File.join(proto_dir, 'mqtt'); FileUtils.mkdir_p(md)
    mqtt_port  = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    mqtts_port = TCPServer.open('127.0.0.1', 0) { |s| s.addr[1] }
    File.write("#{md}/mosq.conf", <<~CFG)
      listener #{mqtt_port} 127.0.0.1
      allow_anonymous true
      persistence false
      listener #{mqtts_port} 127.0.0.1
      certfile #{CERT_PEM}
      keyfile #{KEY_PEM}
      require_certificate false
    CFG
    pid = spawn(mosq, '-c', "#{md}/mosq.conf", in: File::NULL, out: "#{md}/mosq.log", err: "#{md}/mosq.log")
    child_pids << pid
    sleep 0.5
    # Publish a retained message (over the plaintext listener) so a one-shot
    # subscribe on either listener is deterministic.
    if (mp = which('mosquitto_pub'))
      system(mp, '-h', '127.0.0.1', '-p', mqtt_port.to_s, '-t', 'test/topic', '-m', 'mqtt-retained', '-r',
             in: File::NULL, out: File::NULL, err: File::NULL)
    end
    write_port_atomic(File.join(STATE_DIR, 'mqtt_port'), mqtt_port)
    write_port_atomic(File.join(STATE_DIR, 'mqtts_port'), mqtts_port)
  end
rescue => e
  $stderr.puts("mosquitto setup skipped: #{e.class}: #{e.message}")
end

# Reap the spawned daemons on a clean exit / SIGTERM. This is the best-effort
# path; the hard guarantee is rake killing this fixture's whole process group
# (see the Rakefile), which catches daemons even on SIGKILL when at_exit can't
# run. Also trap TERM/INT so a signalled shutdown still triggers at_exit.
reap = lambda do
  child_pids.each do |pid|
    Process.kill('KILL', -pid) rescue nil   # the child's own group, if any
    Process.kill('KILL', pid) rescue nil
  end
end
at_exit(&reap)
%w[TERM INT].each { |s| Signal.trap(s) { reap.call; exit!(0) } }

# ---- announce + serve -----------------------------------------------------

# server_port is written LAST so its existence means every server is up. The
# fixture is rake's child; rake kills it in an ensure block when tests finish.
write_port_atomic(File.join(STATE_DIR, 'smtp_port'), smtp_port_value)
write_port_atomic(File.join(STATE_DIR, 'imap_port'), imap_port_value)
write_port_atomic(File.join(STATE_DIR, 'ws_port'),   ws_port_value)
write_port_atomic(File.join(STATE_DIR, 'ftp_port'),    ftp_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'dict_port'),   dict_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'gopher_port'), gopher_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'pop3_port'),   pop3_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'telnet_port'), telnet_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'rtsp_port'),   rtsp_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'tftp_port'),   tftp_port_value)
write_port_atomic(File.join(STATE_DIR, 'ftps_port'),    ftps_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'pop3s_port'),   pop3s_srv.addr[1])
write_port_atomic(File.join(STATE_DIR, 'gophers_port'), gophers_srv.addr[1])

port      = server.config[:Port]
port_file = File.join(STATE_DIR, 'server_port')
write_port_atomic(port_file, port)

server.start
