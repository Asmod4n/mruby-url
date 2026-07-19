# mrblib/url/websocket.rb
#
# URL::WebSocket — the message-level WebSocket client.
#
# The C layer exposes only two framing primitives (easy_ws_recv / easy_ws_send)
# plus the CURLWS_* flag constants. Everything a WebSocket actually *means* —
# reassembling fragmented messages, dispatching text/binary/ping/pong/close,
# the partial-send continuation loop — lives here in memory-safe Ruby, in
# keeping with the gem's FFI-thin-C rule.
#
# Every wait goes through the owning session's event loop, the same
# URL::EventLoop everything else in the gem drives through: the socket fd is
# watched for the connection's whole life and gets a _service pass whenever
# the loop wakes it, so frames are drained and PINGs answered even while
# unrelated transfers are being driven — and a blocking #receive just drives
# that same loop in turn. A WebSocket never starves the rest of the gem, and
# the rest of the gem never starves a WebSocket.
#
# You get one from URL("wss://h").connect; see mrblib/url/dispatch.rb for the
# connect path that drives the upgrade handshake to completion before handing
# the established CONNECT_ONLY easy handle over.

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

  # Cap on buffered inbound messages. This socket is serviced whenever the
  # loop wakes it; once the inbox is full it stops reading and the kernel's
  # socket buffer applies backpressure to the peer.
  INBOX_MAX = 64

  # `req` is a CONNECT_ONLY=2 URL::Request whose upgrade handshake has been
  # driven to completion on `session`. `error_code` is the libcurl CURLcode
  # from that drive (0 on success). A non-zero code — or a missing active
  # socket — yields a closed socket carrying the failure as a value on
  # #error; nothing is raised.
  def initialize(req, error_code, session)
    @req     = req            # keeps the easy handle (and its connection) alive
    @handle  = req.handle
    @session = session        # #close/#_detach remove the easy through it
    @error   = nil
    @inbox   = []             # complete inbound Messages, in arrival order

    fd = error_code == 0 ? URL::Libcurl.easy_getinfo(@handle, :activesocket) : nil
    if error_code == 0 && fd
      @fd  = fd                # libcurl owns this fd; we only wait on it
      @io  = IO.for_fd(fd)
      @io.autoclose = false
      @loop         = session.event_loop
      @closed       = false
      @rx_buf       = String.new   # cross-frame reassembly state
      @rx_type      = nil
      @pending_pong = nil          # latest unanswered PING's payload
      @tx_busy      = false        # a message send is mid-continuation
      # Watched for the connection's whole life: _service runs whenever the
      # loop wakes this fd, so frames are drained and PINGs answered even
      # while unrelated transfers are driven on the same loop.
      @watch_handle = @loop.watch(@io, :in) { _service }
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
  # peer close, or #close.
  def open?;   !@closed; end
  def closed?;  @closed; end

  # The handshake failure as a value, or nil when the connection came up
  # cleanly. A URL::TransferError subclass: the CURLcode-mapped class when
  # libcurl reported one (e.g. URL::CouldntConnect), or URL::WebSocketError when
  # the server replied with a non-101 HTTP response. Same two-tier model as
  # URL::Response#error — a value, never raised for you.
  def error; @error; end

  # ---- sending ------------------------------------------------------------

  # Send a message. The frame type is decided by the payload itself, down in
  # the C primitive: valid UTF-8 goes out as a TEXT frame, anything else as
  # BINARY (mrb_str_is_utf8 from mruby-string-is-utf8). There is deliberately
  # no way to choose — the WebSocket wire distinction *is* "valid UTF-8 or
  # not" (RFC 6455 §5.6), so the payload already carries the answer.
  def send(data)
    _send_message(data.to_s, 0)
  end

  # An unsolicited PING (libcurl answers an inbound PING with a PONG itself, so
  # you rarely need #pong). `payload` is an optional application body.
  def ping(payload = ""); _send_message(payload.to_s, PING); end
  def pong(payload = ""); _send_message(payload.to_s, PONG); end

  # ---- receiving ----------------------------------------------------------

  # Block for the next complete message and return a URL::WebSocket::Message —
  # reassembly, PING answering and PONG skipping all happen in _service,
  # which also runs whenever the loop wakes this socket for unrelated
  # reasons, so a message may already be waiting in the inbox when this is
  # called. Returns a :close Message when the peer closes, or nil if
  # `timeout:` (a chrono duration: 5.s, 500.ms, …) elapses first. The
  # deadline covers the whole message: it is computed once, up front, so
  # trickling fragments can't restart the clock. Waiting here is just this
  # socket's fd's run_once round — every other transfer and websocket on the
  # same loop keeps progressing regardless, since run_once services all of
  # them together, not just this one.
  def receive(timeout: nil)
    deadline = timeout && Chrono::Steady.now + timeout
    loop do
      _service                     # drain whatever is already readable
      msg = @inbox.shift
      return msg if msg
      if (e = @rx_error)
        @rx_error = nil
        raise e                    # transport failure mid-receive, as ever
      end
      return nil if @closed
      return nil if deadline && Chrono::Steady.now >= deadline
      @loop.run_once(deadline && deadline - Chrono::Steady.now)
    end
  end

  # Iterate messages until the connection closes (or the block breaks).
  def each
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
  def close(status: nil, reason: "")
    return self if @closed
    @closed = true
    payload =
      if status
        # 2-byte big-endian status code + reason, without depending on pack.
        ((status >> 8) & 0xff).chr + (status & 0xff).chr + reason.to_s
      else
        ""
      end
    begin
      _send_once(payload, CLOSE)
    rescue StandardError
      # peer may already be gone; closing is best-effort
    end
    _detach
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

  public

  # One service pass, run whenever the loop wakes this socket's fd (and by
  # #receive before it waits): flush the pending PONG, then drain readable
  # frames — reassembling fragments, answering PINGs, skipping PONGs — into
  # @inbox as complete Messages, until libcurl reports CURLE_AGAIN or the
  # inbox is full (then the kernel buffer applies backpressure). ws_recv /
  # ws_send never touch a multi, so this is safe at any point in the loop. A
  # transport failure is stashed (raised by the next #receive, the same
  # surface it raised from before) so servicing can never break an unrelated
  # caller driving the same loop. Internal — the loop's watch block is the
  # only intended caller.
  def _service
    return if @closed
    begin
      _flush_pong

      while @inbox.size < INBOX_MAX
        frame = URL::Libcurl.easy_ws_recv(@handle, RECV_CHUNK)
        break unless frame   # CURLE_AGAIN — nothing more readable now

        data, flags, bytesleft = frame

        if (flags & CLOSE) != 0
          @inbox << Message.new(:close, data)
          _mark_closed
          break
        elsif (flags & PING) != 0
          _pong_or_queue(data)   # echo the application payload back
          next
        elsif (flags & PONG) != 0
          next
        end

        @rx_type ||= (flags & BINARY) != 0 ? :binary : :text
        @rx_buf << data

        # Message is complete once this frame is fully drained (bytesleft == 0)
        # and it was the final fragment (CONT clear).
        if bytesleft == 0 && (flags & CONT) == 0
          @inbox << Message.new(@rx_type, @rx_buf)
          @rx_buf  = String.new
          @rx_type = nil
        end
      end
    rescue StandardError => e
      @rx_error = e
      _mark_closed
    end
    nil
  end

  private

  # Peer closed (or the transport died): stop watching the fd and mark the
  # socket unusable. Messages already in @inbox stay deliverable.
  def _mark_closed
    @closed = true
    _detach
    nil
  end

  # Stop watching the fd and let the easy leave its multi — the CONNECT_ONLY
  # easy stayed attached for the socket's whole life (removal is what kills
  # its connection), so this runs exactly once, when the socket is done.
  # Session#remove defers the multi_remove itself if a C callback is live
  # above us; nothing here needs to know about that.
  def _detach
    return unless @fd
    @loop.unwatch(@watch_handle)
    @session.remove(@req)
    @fd = nil
    nil
  end

  # Answer a PING now if the socket takes it, otherwise remember the payload —
  # a single slot, latest wins (RFC 6455 §5.5.3: only the most recent
  # unanswered PING needs a PONG), flushed on a later wake. Never blocks, and
  # never sends while a message send is mid-continuation: injecting a frame
  # between OFFSET fragments would corrupt libcurl's outgoing frame state.
  def _pong_or_queue(payload)
    if @tx_busy || URL::Libcurl.easy_ws_send(@handle, payload, PONG, 0).nil?
      @pending_pong = payload
    end
    nil
  end

  def _flush_pong
    return if @pending_pong.nil? || @tx_busy
    @pending_pong = nil if URL::Libcurl.easy_ws_send(@handle, @pending_pong, PONG, 0)
    nil
  end

  # Send a whole message, looping over partial sends. The first call carries
  # the control flag — or 0, letting C classify the payload as TEXT/BINARY —
  # and hands back the flags actually used; any remainder is a continuation of
  # the same frame, re-sent with those flags plus OFFSET so libcurl doesn't
  # start a new frame (and no fragment is ever re-classified).
  def _send_message(data, flag)
    return nil if @closed   # no-op on a closed/failed socket; never raises

    # @tx_busy keeps _service from injecting a PONG between the OFFSET
    # continuation fragments below — one outgoing frame at a time.
    @tx_busy = true
    begin
      sent, flag = _send_once(data, flag)
      total = data.bytesize
      while sent < total
        rest    = data.byteslice(sent, total - sent)
        n, flag = _send_once(rest, flag | OFFSET)
        sent   += n
      end
      sent
    ensure
      @tx_busy = false
    end
  end

  # One ws_send, waiting on writability while libcurl reports CURLE_AGAIN
  # (ws_send => nil). The fd is normally only watched for :in (servicing
  # inbound frames), so a second, transient :out registration rides
  # alongside it for just this wait — the loop's run_once services both
  # (and everything else registered on it) together, so nothing in flight
  # starves while this socket drains. Returns [bytes_accepted, flags_used].
  def _send_once(data, flags)
    loop do
      r = URL::Libcurl.easy_ws_send(@handle, data, flags, 0)
      return r if r

      out_handle = @loop.watch(@io, :out) { }
      begin
        @loop.run_once
      ensure
        @loop.unwatch(out_handle)
      end
    end
  end
end
