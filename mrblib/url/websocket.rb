# mrblib/url/websocket.rb
#
# URL::WebSocket — the message-level WebSocket client.
#
# The C layer exposes only two framing primitives (easy_ws_recv / easy_ws_send)
# plus the CURLWS_* flag constants. Everything a WebSocket actually *means* —
# reassembling fragmented messages, dispatching text/binary/ping/pong/close,
# the partial-send continuation loop, and waiting on the socket between calls —
# lives here in memory-safe Ruby, in keeping with the gem's FFI-thin-C rule.
#
# You get one from URL("wss://h").connect. Two modes, decided by whether an
# event loop is installed (URL.default_loop):
#
#   * BLOCKING (default): connect drives the upgrade handshake to completion
#     before returning; #receive blocks for the next message, #send blocks
#     until the payload is written. The waits ride curl_multi_poll.
#   * EVENTED: connect returns immediately with a socket in the :connecting
#     state; the handshake, all reads and all writes ride the event loop.
#     Messages arrive through #on_message, the open/close transitions through
#     #on_open / #on_close, and #send queues without blocking. #receive/#each
#     are meaningless here and raise.
#
# See mrblib/url/dispatch.rb for both connect paths.

# Raised-as-a-value when the upgrade handshake completes at the transport level
# but the server never switched protocols (no 101) — so libcurl hands back
# CURLE_OK with no usable WebSocket socket. Part of the URL::TransferError
# family, so `rescue URL::TransferError` and `ws.error` treat it like any other
# transfer failure.
class URL::WebSocketError < URL::TransferError; end

class URL::WebSocket
  # Map the published CURLWS_* bitmask flags to local names.
  TEXT   = URL::Libcurl::WS_TEXT
  BINARY = URL::Libcurl::WS_BINARY
  CONT   = URL::Libcurl::WS_CONT
  CLOSE  = URL::Libcurl::WS_CLOSE
  PING   = URL::Libcurl::WS_PING
  PONG   = URL::Libcurl::WS_PONG
  OFFSET = URL::Libcurl::WS_OFFSET

  # Bytes pulled per ws_recv call. A frame larger than this is delivered in
  # several chunks (meta.bytesleft > 0); #receive stitches them back together.
  RECV_CHUNK = 65_536

  # Slice for the blocking waits when the caller gave no timeout. multi_poll
  # returns the moment the socket is ready, so this only bounds how long a
  # completely idle connection sleeps before looping — big on purpose, so an
  # idle #receive doesn't wake Ruby needlessly.
  IDLE_SLICE_MS = 3_600_000

  # One inbound message handed back by #receive. `type` is :text, :binary or
  # :close; `data` is the (reassembled) payload bytes.
  class Message
    attr_reader :type, :data
    def initialize(type, data)
      @type = type
      @data = data
    end

    def text?;   @type == :text;   end
    def binary?; @type == :binary; end
    def close?;  @type == :close;  end
    def to_s;    @data;            end
  end

  # `req` is a CONNECT_ONLY=2 URL::Request. Blocking mode (no `event_loop`):
  # the upgrade handshake has already been driven to completion and
  # `error_code` is the libcurl CURLcode from that drive (0 on success); a
  # non-zero code — or a missing active socket — yields a closed socket
  # carrying the failure as a value on #error; nothing is raised.
  #
  # Evented mode (`event_loop:` given): the handshake hasn't run yet — the
  # socket starts out :connecting and dispatch.rb finishes construction via
  # _handshake_done once the session it attached the request to reaps it.
  def initialize(req, error_code = 0, event_loop: nil)
    @req    = req            # keeps the easy handle (and its connection) alive
    @handle = req.handle
    @error  = nil
    @loop   = event_loop

    if @loop
      @connecting = true
      @closed     = false
      @outbox     = []        # [payload, flags] pairs awaiting a writable socket
      return
    end

    fd = error_code == 0 ? URL::Libcurl.easy_getinfo(@handle, :activesocket) : nil
    if error_code == 0 && fd
      @fd = fd                # libcurl owns this fd; we only wait on it
      # A bare multi handle used purely as libcurl's portable waiting
      # primitive (curl_multi_poll with @fd as an extra fd) — no transfers
      # ever attach to it.
      @wait_multi = URL::Libcurl.multi_init
      @closed = false
    else
      # Either a CURLcode failure, or curl returned OK with no upgraded socket
      # (server answered with a normal HTTP response, not 101). Both become a
      # descriptive value on #error — naming the actual HTTP status when we have
      # one — never a raise.
      @closed = true
      @error  = _build_connect_error(error_code)
    end
  end

  # A live WebSocket owns a connection (and the libcurl easy handle behind it)
  # that can't be duplicated — curl_easy_duphandle copies options but not the
  # established socket. Refuse dup/clone; open another with URL("wss://…").connect.
  def initialize_copy(orig)
    raise NotImplementedError,
          "can't dup/clone #{self.class}: a live WebSocket owns a connection " \
          "that can't be duplicated"
  end

  # True while the socket is live and usable. False after a failed handshake, a
  # peer close, or #close — and false while an evented connect is still mid-
  # handshake (see #connecting?).
  def open?;   !@closed && !@connecting; end
  def closed?;  @closed; end

  # True between an evented connect returning and the upgrade handshake
  # finishing (at which point #on_open fires and #open? flips true, or the
  # failure lands on #error and #on_close fires). Always false in blocking
  # mode — there connect only returns finished sockets.
  def connecting?; !!@connecting; end

  # The handshake failure as a value, or nil when the connection came up
  # cleanly. A URL::TransferError subclass: the CURLcode-mapped class when
  # libcurl reported one (e.g. URL::CouldntConnect), or URL::WebSocketError when
  # the server replied with a non-101 HTTP response. Same two-tier model as
  # URL::Response#error — a value, never raised for you.
  def error; @error; end

  # ---- evented callbacks ---------------------------------------------------
  # Only meaningful on an evented socket (one opened while URL.default_loop is
  # installed); setting them on a blocking socket is a usage mistake and
  # raises. Each fires on the loop's thread, from inside the readiness blocks.
  #
  # To make callback registration race-free, a callback whose moment has
  # already passed fires immediately: on_open set after the handshake finished
  # runs right away, on_close set after the socket closed runs right away.

  # The socket came up: the upgrade handshake completed and #open? is true.
  # Yields the socket itself.
  def on_open(&block)
    _evented_only!(:on_open)
    if @connecting
      @on_open = block
    elsif !@closed
      block.call(self)
    end
    self
  end

  # One complete inbound message (a URL::WebSocket::Message, text or binary).
  # Fragmented / oversized messages are reassembled first; PING/PONG frames
  # are handled internally and never surface here.
  def on_message(&block)
    _evented_only!(:on_message)
    @on_message = block
    self
  end

  # The socket went away. Yields the peer's :close Message when the peer
  # closed the connection, or nil for a local #close, a failed handshake or a
  # transport error — #error carries the failure in the latter two cases.
  # Fires exactly once.
  def on_close(&block)
    _evented_only!(:on_close)
    if @closed
      block.call(@close_msg)
    else
      @on_close = block
    end
    self
  end

  # ---- sending ------------------------------------------------------------

  # Send a message. The frame type is decided by the payload itself, down in
  # the C primitive: valid UTF-8 goes out as a TEXT frame, anything else as
  # BINARY (mrb_str_is_utf8 from mruby-string-is-utf8). There is deliberately
  # no way to choose — the WebSocket wire distinction *is* "valid UTF-8 or
  # not" (RFC 6455 §5.6), so the payload already carries the answer.
  #
  # Blocking mode: writes the whole message (looping over partial sends) and
  # returns the byte count. Evented mode: never blocks — what the socket won't
  # take right now is queued and flushed when the loop reports writability
  # (returns nil immediately; a send while still :connecting queues too and
  # goes out once the handshake completes).
  def send(data)
    _send_message(data.to_s, 0)
  end

  # An unsolicited PING (libcurl answers an inbound PING with a PONG itself, so
  # you rarely need #pong). `payload` is an optional application body.
  def ping(payload = ""); _send_message(payload.to_s, PING); end
  def pong(payload = ""); _send_message(payload.to_s, PONG); end

  # ---- receiving ----------------------------------------------------------

  # Block for the next complete message and return a URL::WebSocket::Message,
  # reassembling a fragmented or oversized message across frames. Control PINGs
  # are answered and skipped; PONGs are skipped. Returns a :close Message when
  # the peer closes, or nil if `timeout:` (seconds) elapses first.
  def receive(timeout: nil)
    _blocking_only!(:receive)
    return nil if @closed
    buf  = String.new
    type = nil
    loop do
      chunk = _recv_chunk(timeout)
      return nil if chunk == :timeout

      data, flags, bytesleft = chunk

      if (flags & CLOSE) != 0
        @closed = true
        return Message.new(:close, data)
      elsif (flags & PING) != 0
        pong(data)   # echo the application payload back
        next
      elsif (flags & PONG) != 0
        next
      end

      type ||= (flags & BINARY) != 0 ? :binary : :text
      buf << data

      # Message is complete once this frame is fully drained (bytesleft == 0)
      # and it was the final fragment (CONT clear).
      return Message.new(type, buf) if bytesleft == 0 && (flags & CONT) == 0
    end
  end

  # Iterate messages until the connection closes (or the block breaks).
  def each
    _blocking_only!(:each)
    raise ArgumentError, "URL::WebSocket#each requires a block" unless block_given?
    loop do
      msg = receive
      break if msg.nil? || msg.close?
      yield msg
    end
    self
  end

  # ---- lifecycle ----------------------------------------------------------

  # Send a CLOSE frame and mark the socket closed. `status` is an optional
  # numeric close code (e.g. 1000); `reason` an optional UTF-8 string. The
  # underlying connection is torn down when the easy handle is GC'd.
  #
  # Evented mode: the CLOSE frame joins the outbound queue (a control frame
  # must not interleave into a partially written message), later sends no-op,
  # and #on_close fires once the queue has drained and the frame is out.
  def close(status: nil, reason: "")
    return self if @closed
    payload =
      if status
        # 2-byte big-endian status code + reason, without depending on pack.
        ((status >> 8) & 0xff).chr + (status & 0xff).chr + reason.to_s
      else
        ""
      end

    if @loop
      return self if @closing
      @closing = true
      if @connecting
        # Mid-handshake: nothing is writable yet — just tear down; the easy
        # handle's GC drops the half-open connection.
        _teardown
      else
        @outbox << [payload, CLOSE]
        _flush_outbox
      end
      return self
    end

    @closed = true
    begin
      _send_once(payload, CLOSE)
    rescue StandardError
      # peer may already be gone; closing is best-effort
    end
    self
  end

  private

  # Build a descriptive URL::TransferError for a connect that didn't yield a
  # usable socket. Always names the HTTP status when the server gave one, so the
  # common "server answered with a page instead of upgrading" case reads clearly
  # instead of curl's opaque "HTTP response code said error".
  def _build_connect_error(error_code)
    where  = URL::Libcurl.easy_getinfo(@handle, :effective_url)
    status = URL::Libcurl.easy_getinfo(@handle, :response_code) rescue nil
    upgrade_refused = status && status >= 100 && status != 101

    if error_code != 0
      detail = URL::Libcurl.easy_strerror(error_code)
      msg =
        if upgrade_refused
          "websocket upgrade refused: server replied HTTP #{status} " \
          "(expected 101 Switching Protocols) for #{where} — #{detail}"
        else
          "websocket handshake failed: #{detail} (#{where})"
        end
      URL._transfer_error(self, error_code, msg)
    elsif upgrade_refused
      URL::WebSocketError.new(
        "websocket upgrade refused: server replied HTTP #{status} " \
        "(expected 101 Switching Protocols) for #{where}"
      )
    else
      URL::WebSocketError.new(
        "websocket upgrade did not complete (no socket established) for #{where}"
      )
    end
  end

  # One ws_recv, blocking on readability while libcurl reports CURLE_AGAIN
  # (ws_recv => nil). Returns the [data, flags, bytesleft] triple, or :timeout.
  # Readiness comes from curl_multi_poll with the ws socket as an extra fd —
  # libcurl's own portable wait; it returns the moment the fd is ready, so a
  # nil timeout just sleeps in big idle slices.
  def _recv_chunk(timeout)
    loop do
      frame = URL::Libcurl.easy_ws_recv(@handle, RECV_CHUNK)
      return frame if frame

      if timeout
        ready = URL::Libcurl.multi_poll(@wait_multi, URL._duration_ms(timeout), @fd, :in)
        return :timeout if ready == 0
      else
        URL::Libcurl.multi_poll(@wait_multi, IDLE_SLICE_MS, @fd, :in)
      end
    end
  end

  # Send a whole message. Blocking mode: loop over partial sends until every
  # byte is written, waiting on writability in between, and return the byte
  # count. Evented mode: append to the outbound queue and flush as much as the
  # socket takes right now; the rest goes out from the loop's writability
  # callback (returns nil immediately).
  #
  # The first ws_send carries the control flag — or 0, letting C classify the
  # payload as TEXT/BINARY — and hands back the flags actually used; any
  # remainder is a continuation of the same frame, re-sent with those flags
  # plus OFFSET so libcurl doesn't start a new frame (and no fragment is ever
  # re-classified).
  def _send_message(data, flag)
    return nil if @closed || @closing   # no-op on a closed/failed socket; never raises

    if @loop
      @outbox << [data, flag]
      _flush_outbox unless @connecting   # queued pre-handshake bytes flush on open
      return nil
    end

    sent, flag = _send_once(data, flag)
    total = data.bytesize
    while sent < total
      rest    = data.byteslice(sent, total - sent)
      n, flag = _send_once(rest, flag | OFFSET)
      sent   += n
    end
    sent
  end

  # One ws_send, blocking on writability while libcurl reports CURLE_AGAIN
  # (ws_send => nil). Returns [bytes_accepted, flags_used] for this call.
  def _send_once(data, flags)
    loop do
      r = URL::Libcurl.easy_ws_send(@handle, data, flags, 0)
      return r if r

      URL::Libcurl.multi_poll(@wait_multi, IDLE_SLICE_MS, @fd, :out)
    end
  end

  # ---- evented internals ----------------------------------------------------

  def _evented_only!(name)
    return if @loop
    raise URL::Error,
          "URL::WebSocket##{name} only fires on an evented socket (one opened " \
          "with URL.default_loop installed) — a blocking socket delivers " \
          "through #receive/#each"
  end

  def _blocking_only!(name)
    return unless @loop
    raise URL::Error,
          "URL::WebSocket##{name} would block the event loop — an evented " \
          "socket delivers messages through #on_message"
  end

  public

  # dispatch.rb hands over the session that drives the handshake. The socket
  # keeps it for its whole life: the easy must STAY attached to that multi —
  # removing a CONNECT_ONLY easy from its multi severs the established
  # connection — so the reap leaves it in place (on_complete detach: false)
  # and _teardown detaches it at the very end. Internal plumbing.
  def _bind_connect_session(session)
    @session = session
    self
  end

  # Completion of the evented CONNECT_ONLY transfer (called from the
  # handshake Request's on_complete, i.e. from inside the loop's readiness
  # block). Finish construction: pull the upgraded fd, start watching it, and
  # fire on_open — or turn the failure into the usual value on #error and
  # fire on_close.
  def _handshake_done(code)
    if @closed                    # locally closed mid-handshake; drop it
      _release_session
      return
    end

    @connecting = false
    fd = code == 0 ? URL::Libcurl.easy_getinfo(@handle, :activesocket) : nil

    unless fd
      _release_session
      @error     = _build_connect_error(code)
      @close_msg = nil
      @closed    = true
      cb = @on_close
      @on_close = nil
      cb.call(nil) if cb
      return
    end

    @fd = fd
    @io = IO.for_fd(fd)
    @io.autoclose = false          # libcurl owns this fd; never close it
    @recv_buf  = String.new
    @recv_type = nil
    @watch_readiness = nil
    @watch_handle    = nil
    @_ready_block = lambda do |_io, cond|
      _evented_ready(cond)
      true
    end
    _rewatch(@outbox.empty? ? :in : :inout)

    cb = @on_open
    @on_open = nil
    cb.call(self) if cb
    _flush_outbox unless @closed || @outbox.empty?
    nil
  end

  private

  # Loop readiness callback: writable → flush what's queued; readable → drain
  # every frame the socket has right now. A transport failure mid-drain
  # becomes a value on #error plus an on_close, mirroring how every other
  # runtime failure in the gem stays a value.
  def _evented_ready(cond)
    _flush_outbox if cond == :out || cond == :inout
    _drain_frames if !@closed && (cond == :in || cond == :inout)
  rescue RuntimeError => e
    @error = URL::TransferError.new(e.message)
    _teardown
  end

  # Pull frames until libcurl reports CURLE_AGAIN (ws_recv => nil),
  # reassembling messages exactly like the blocking #receive and handing each
  # complete one to on_message.
  def _drain_frames
    until @closed
      frame = URL::Libcurl.easy_ws_recv(@handle, RECV_CHUNK)
      return unless frame

      data, flags, bytesleft = frame

      if (flags & CLOSE) != 0
        _teardown(Message.new(:close, data))
        return
      elsif (flags & PING) != 0
        pong(data)   # echo the application payload back (rides the outbox)
        next
      elsif (flags & PONG) != 0
        next
      end

      @recv_type ||= (flags & BINARY) != 0 ? :binary : :text
      @recv_buf << data

      if bytesleft == 0 && (flags & CONT) == 0
        msg = Message.new(@recv_type, @recv_buf)
        @recv_buf  = String.new
        @recv_type = nil
        cb = @on_message
        cb.call(msg) if cb
      end
    end
  end

  # Write queued messages until the socket stops taking bytes, preserving
  # message order and frame continuations. While anything is left the watch
  # includes :out so the loop calls back on writability; once drained it goes
  # back to :in only. A flushed CLOSE (queued by #close) tears the socket down.
  def _flush_outbox
    while (entry = @outbox.first)
      pending = _send_nonblocking(entry[0], entry[1])
      if pending
        @outbox[0] = pending
        _rewatch(:inout)
        return
      end
      @outbox.shift
    end
    if @closing
      _teardown
    else
      _rewatch(:in)
    end
    nil
  end

  # Push one message as far as the socket allows without waiting. Returns nil
  # when fully written, or the [rest, flags] continuation pair to retry when
  # the socket is writable again.
  def _send_nonblocking(data, flags)
    total = data.bytesize
    sent  = 0
    while sent < total || (total == 0 && sent == 0)
      chunk = sent == 0 ? data : data.byteslice(sent, total - sent)
      r = URL::Libcurl.easy_ws_send(@handle, chunk, flags, 0)
      return [chunk, flags] unless r   # CURLE_AGAIN: resend this chunk later

      n, used = r
      flags = used | OFFSET
      sent += n
      break if total == 0              # empty payload (bare CLOSE/PING) sends once
    end
    nil
  end

  # (Re-)register the ws fd with the loop under the given readiness, dropping
  # any previous registration first (EventLoop watches are fixed-readiness).
  def _rewatch(readiness)
    return if @closed
    return if @watch_readiness == readiness && @watch_handle

    @loop.unwatch(@watch_handle) if @watch_handle
    @watch_handle    = @loop.watch(@io, readiness, &@_ready_block)
    @watch_readiness = readiness
    nil
  end

  # Final transition, evented mode. Unhook from the loop, detach the easy
  # from the handshake session's multi (releasing the connection), mark
  # closed, fire on_close exactly once. `close_msg` is the peer's :close
  # Message when the peer initiated; nil for local close and errors.
  def _teardown(close_msg = nil)
    return if @closed
    @closed    = true
    @close_msg = close_msg
    if @watch_handle
      @loop.unwatch(@watch_handle)
      @watch_handle = nil
    end
    @outbox.clear
    _release_session
    cb = @on_close
    @on_close = nil
    cb.call(close_msg) if cb
    nil
  end

  # Detach the easy from the session that drove the handshake and drop the
  # session. Once the socket is done the connection may go with it — until
  # then the attachment is what keeps the connection alive.
  def _release_session
    if @session
      @session.remove(@req) rescue nil
      @session = nil
    end
    nil
  end
end
