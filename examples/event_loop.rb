# examples/event_loop.rb
#
# Driving mruby-url from an event loop — the three integration shapes:
#
#   1. Fire-and-forget verbs on URL.default_loop (the usual integration)
#   2. An evented WebSocket: on_open / on_message / on_close, never blocking
#   3. Driving a single session by hand (what a platform-loop adapter does)
#
# URL::IOSelectLoop is the reference URL::EventLoop — it pumps IO.select and
# fires the blocks the session hands it, which is everything a real
# integration (glib, libuv, a game loop) has to provide. A real app would not
# call `loop.run`; its platform loop is already running and plays that role.
#
# Live calls target an httpbin-style server; pass its base URL as the first
# argument (defaults to a local one):
#
#     mruby examples/event_loop.rb http://localhost:8080 [ws://localhost:PORT]
#
# A local httpbin (offline, deterministic):
#
#     podman run --rm -p 8080:8080 docker.io/mccutchen/go-httpbin:latest
#
# The optional second argument points section 2 at a WebSocket echo server
# (e.g. the fixture from `rake test`, or wss://echo.websocket.org).

BASE = ARGV[0] || "http://localhost:8080"
WS   = ARGV[1]

def section(title)
  puts "\n== #{title} =="
end

# ---------------------------------------------------------------------------
section "1. Fire-and-forget: URL.default_loop"
# ---------------------------------------------------------------------------
# Install a loop once at startup and every verb attaches its transfer to it
# and returns nil immediately — nothing blocks. Body bytes arrive through the
# streaming block; your application's loop drives everything.

sel = URL::IOSelectLoop.new
URL.default_loop = sel

body = ""
ret  = URL("#{BASE}/get").get { |chunk| body << chunk }
puts "verb returned:  #{ret.inspect} (nothing blocked)"

# Several transfers ride the same loop concurrently — each on its own session,
# connections and TLS sessions shared via the process-wide cache.
second = ""
URL("#{BASE}/get?tag=second").get { |chunk| second << chunk }

sel.run   # stand-in for your app's already-running platform loop

puts "first body:     #{body.bytesize} bytes"
puts "second body:    #{second.bytesize} bytes"

# ---------------------------------------------------------------------------
section "2. Evented WebSocket"
# ---------------------------------------------------------------------------
# With a loop installed, connect returns immediately in the :connecting state
# and the block becomes the on_open callback (no auto-close). Messages arrive
# through on_message; #send queues without ever blocking; on_close fires once
# when the peer closes, #close is called, or the handshake fails (the failure
# is a value on ws.error, as everywhere in this gem).

if WS
  ws = URL(WS).connect do |w|
    puts "open:           handshake done, saying hello"
    w.send("hello over the loop")
  end
  puts "after connect:  connecting?=#{ws.connecting?}"

  ws.on_message do |msg|
    puts "message:        #{msg.data.inspect} (#{msg.type})"
    ws.close
  end
  ws.on_close { |m| puts "closed:         peer=#{!m.nil?} error=#{ws.error.inspect}" }

  sel.run
else
  puts "(skipped — pass a ws:// echo URL as the second argument)"
end

URL.default_loop = nil   # back to blocking verbs for section 3

# ---------------------------------------------------------------------------
section "3. Driving one session by hand"
# ---------------------------------------------------------------------------
# What default_loop does under the hood, spelled out — and exactly what a
# platform-loop adapter implements. The session asks the loop to watch fds
# and arm timers; the loop fires the session's blocks; the session does the
# rest (socket_action, completion reaping, timeout bookkeeping).

hand    = URL::IOSelectLoop.new
session = URL.open
session.event_loop = hand

status = nil
bytes  = 0
req = URL::Request.new(session, "#{BASE}/get")
req.on_header { |line| status ||= line.strip }
req.on_data   { |chunk| bytes += chunk.bytesize }
req.on_complete { |code| puts "complete:       CURLcode #{code}" }

session.add(req)
session.socket_action   # kick off: registers fds/timers with the loop

hand.run

puts "status line:    #{status}"
puts "body bytes:     #{bytes}"

# ---------------------------------------------------------------------------
section "4. What a real integration implements"
# ---------------------------------------------------------------------------
# Subclass URL::EventLoop and map four primitives onto your platform's loop —
# IOSelectLoop is the complete reference. Sketch (not executed):
#
#   class GlibLoop < URL::EventLoop
#     def watch(io, readiness, &block)   # g_io_add_watch(io.fileno, ...)
#       # call block.(io, :in / :out) whenever the fd becomes ready;
#       # return a handle you can undo later
#     end
#     def unwatch(handle)                # g_source_remove(handle)
#     def arm_timer(ms, &block)          # g_timeout_add(ms) { block.(); false }
#     def cancel_timer(handle)           # g_source_remove(handle)
#   end
#
#   URL.default_loop = GlibLoop.new      # done: verbs + WebSockets ride glib

puts "see the comment in this section for the four-method adapter shape"
