#!/usr/bin/env ruby
# test/server.rb — runs under MRI, child of the mruby test process.
#
# Lifecycle: parent (mruby) launches us via IO.popen("...", "r+") so our
# STDIN is the read end of a pipe whose write end the parent holds.
# When the parent dies — clean exit, segfault, killed, doesn't matter —
# the kernel closes the write end, our read on STDIN returns, we exit.
# No at_exit, no signal handler, no leaked process.

# Redirect stderr to a log file *first*, so any failure during require or
# server setup is captured. Without this we have no idea why the child died.
$stderr.reopen(File.join(File.dirname(__FILE__), 'server.log'), 'w')
$stderr.sync = true

require 'webrick'
require 'json'
require 'zlib'
require 'stringio'
require 'socket'
require 'openssl'

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

# /status/418 -> 418, etc. Covers success?/client_error?/server_error?.
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

# /slow/2000 -> wait 2s then respond. Covers timeout_ms + error_message.
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

received_file = File.join(__dir__, 'smtp_received')
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
# Minimal IMAPS endpoint for the URL IMAP verbs (move/store/expunge/fetch).
# Implicit TLS, like the SMTP fixture: the socket is wrapped in SSL on accept
# (no STARTTLS) and the same self-signed cert is reused.
#
# We speak just enough of curl's IMAP client flow: an untagged "* OK" greeting,
# then tagged CAPABILITY / LOGIN (accept any creds) / SELECT (untagged EXISTS +
# OK), then the command under test. curl drives a SELECTed mailbox then either
# issues our -X custom request (UID STORE / EXPUNGE / UID MOVE) or, for a
# message fetch, translates the URL's ";UID=<n>" into "UID FETCH <n> BODY[]"
# itself. Each tagged command gets the right untagged response and a tagged
# "OK"; FETCH returns a small literal-counted message body. Every received
# command line is appended to test/imap_received so the mruby tests can assert.
#
# Self-signed cert generated above; the client (curl/mruby) is told not to
# verify it (ssl_verify_peer:/ssl_verify_host: false in the test).

imap_received_file = File.join(__dir__, 'imap_received')
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

# ---- announce + serve -----------------------------------------------------

# Write the SMTP port first; server_port is written LAST so its existence means
# both servers are up. The server is rake's child; rake kills it in an ensure
# block when tests finish (or crash).
def write_port_atomic(path, value)
  tmp = "#{path}.tmp"
  File.write(tmp, value.to_s)
  File.rename(tmp, path)
end

write_port_atomic(File.join(__dir__, 'smtp_port'), smtp_port_value)
write_port_atomic(File.join(__dir__, 'imap_port'), imap_port_value)

port      = server.config[:Port]
port_file = File.join(__dir__, 'server_port')
write_port_atomic(port_file, port)

server.start
