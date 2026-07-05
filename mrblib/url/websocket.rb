# mrblib/url/websocket.rb
#
# URL::WebSocket — the message-level WebSocket client.
#
# The C layer exposes only two framing primitives (easy_ws_recv / easy_ws_send)
# plus the CURLWS_* flag constants. Everything a WebSocket actually *means* —
# reassembling fragmented messages, dispatching text/binary/ping/pong/close,
# the partial-send continuation loop, and blocking on the socket between calls —
# lives here in memory-safe Ruby, in keeping with the gem's FFI-thin-C rule.
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

  # `req` is a CONNECT_ONLY=2 URL::Request whose upgrade handshake has been
  # driven to completion. `error_code` is the libcurl CURLcode from that drive
  # (0 on success). A non-zero code — or a missing active socket — yields a
  # closed socket carrying the failure as a value on #error; nothing is raised.
  def initialize(req, error_code = 0)
    @req    = req            # keeps the easy handle (and its connection) alive
    @handle = req.handle
    @error  = nil

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

  # Block for the next complete message and return a URL::WebSocket::Message,
  # reassembling a fragmented or oversized message across frames. Control PINGs
  # are answered and skipped; PONGs are skipped. Returns a :close Message when
  # the peer closes, or nil if `timeout:` (seconds) elapses first.
  def receive(timeout: nil)
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
  # libcurl's own portable wait; a nil timeout blocks in 1s slices.
  def _recv_chunk(timeout)
    loop do
      frame = URL::Libcurl.easy_ws_recv(@handle, RECV_CHUNK)
      return frame if frame

      if timeout
        ready = URL::Libcurl.multi_poll(@wait_multi, (timeout.to_f * 1000).to_i, @fd, :in)
        return :timeout if ready == 0
      else
        URL::Libcurl.multi_poll(@wait_multi, 1000, @fd, :in)
      end
    end
  end

  # Send a whole message, looping over partial sends. The first call carries
  # the control flag — or 0, letting C classify the payload as TEXT/BINARY —
  # and hands back the flags actually used; any remainder is a continuation of
  # the same frame, re-sent with those flags plus OFFSET so libcurl doesn't
  # start a new frame (and no fragment is ever re-classified).
  def _send_message(data, flag)
    return nil if @closed   # no-op on a closed/failed socket; never raises

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

      URL::Libcurl.multi_poll(@wait_multi, 1000, @fd, :out)
    end
  end
end
