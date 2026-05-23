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

# ---- announce + serve -----------------------------------------------------

# Write port file. The server is rake's child; rake kills it in an ensure
# block when tests finish (or crash).
port      = server.config[:Port]
port_file = File.join(__dir__, 'server_port')
tmp_file  = "#{port_file}.tmp"
File.write(tmp_file, port.to_s)
File.rename(tmp_file, port_file)

server.start
