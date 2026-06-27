# examples/websocket.rb
#
# Minimal WebSocket round-trip against a public echo server.
#
#   mruby examples/websocket.rb
#
# Requires an embedded libcurl built with WebSocket support (7.86+).

ws = URL("wss://echo.websocket.org").connect

# A failed handshake is a value, not a raise — inspect it and stop.
unless ws.open?
  warn "connect failed: #{ws.error}"
  exit 1
end

begin
  ws.send_text("hello from mruby-url")

  msg = ws.receive(timeout: 5)
  if msg.nil?
    puts "timed out waiting for a reply"
  elsif msg.close?
    puts "server closed the connection"
  else
    puts "#{msg.type}: #{msg.data.inspect}"
  end

  # A binary frame, then read the echo back.
  ws.send_binary("\x00\x01\x02\x03")
  reply = ws.receive(timeout: 5)
  puts "echoed #{reply.data.bytesize} bytes" if reply && !reply.close?
ensure
  ws.close(status: 1000)
end
