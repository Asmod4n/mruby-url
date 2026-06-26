# mrblib/url.rb
#
# Public surface of mruby-url. Everything a user is meant to call lives here:
#
#   URL.get / .head / .delete / .options / .post / .put / .patch
#   URL.shared          - the reused per-state session (tune its pool)
#   URL.default_loop=   - plug in a platform event loop once at startup
#   URL::Response       - what the verbs return
#   URL::EventLoop      - subclass to integrate a native event loop
#   URL::Error          - usage errors raise it; the per-CURLcode transfer-error
#                         family (Response#error) descends from it — see
#                         mrblib/url/errors.rb
#
# The internal plumbing (request dispatch, the built-in IO.select loop,
# transfer buffering, the Request callback setters) lives under mrblib/url/.
# Dir.glob sorts "url.rb" before "url/...", so this file loads first and the
# user-facing classes here — including URL::EventLoop, which the internal
# URL::IOSelectLoop subclasses — are defined before the plumbing loads.

# ============================================================================
#  Errors
#
#  The taxonomy — URL::Error (usage errors) and the per-CURLcode
#  URL::TransferError family returned as a value by Response#error — lives in
#  mrblib/url/errors.rb, which loads after this file. We only open URL here so
#  the user-facing classes below (EventLoop, Response) have their namespace.
# ============================================================================

class URL; end

# ============================================================================
#  URL::EventLoop — subclass and implement four primitives
#
#    def watch(io, readiness, &block)   # called when fd readiness changes
#    def unwatch(handle)
#    def arm_timer(ms, &block)          # block.() when timer fires
#    def cancel_timer(handle)
#
#  The block passed to watch.(io, cond) drives socket_action + info_read +
#  remove. The block passed to arm_timer.() does the same for timeouts.
#  Your loop only needs to invoke the block at the right moment.
# ============================================================================

class URL::EventLoop
  def watch(io, readiness, &block)
    raise NotImplementedError, "#{self.class}#watch"
  end

  def unwatch(handle)
    raise NotImplementedError, "#{self.class}#unwatch"
  end

  def arm_timer(ms, &block)
    raise NotImplementedError, "#{self.class}#arm_timer"
  end

  def cancel_timer(handle)
    raise NotImplementedError, "#{self.class}#cancel_timer"
  end
end

# ============================================================================
#  URL::Response
# ============================================================================

class URL::Response
  attr_reader :url, :effective_url, :code, :body, :raw_headers,
              :total_time, :content_type, :error_code

  def initialize(url:, effective_url:, code:, body:, raw_headers:,
                 total_time:, content_type:, error_code:)
    @url           = url
    @effective_url = effective_url
    @code          = code
    @body          = body
    @raw_headers   = raw_headers
    @total_time    = total_time
    @content_type  = content_type
    @error_code    = error_code
  end

  def headers
    @headers ||= _parse_headers
  end

  def [](name)
    headers[name.to_s.downcase]
  end

  def json
    @json ||= JSON.parse(@body)
  end

  def json_lazy
    @json_lazy ||= JSON.parse_lazy(@body)
  end

  def into(target)
    json_lazy.into(target)
  end

  # The error as a *value*: nil on a clean success, otherwise an exception object
  # you can inspect or raise yourself — nothing is raised for you. It is set for
  # both kinds of failure:
  #   * a transport/CURLcode failure (timeout, DNS, TLS, refused connection) — the
  #     matching URL::TransferError subclass, or a reused built-in such as
  #     SocketError for a DNS failure;
  #   * an HTTP error status (>= 400) even though libcurl itself returned OK — a
  #     URL::HttpReturnedError (libcurl's own CURLE_HTTP_RETURNED_ERROR meaning).
  # Usage errors (unsupported scheme, bad args) still raise at the call.
  def error
    return @error if @error
    @error =
      if @error_code != 0
        URL._transfer_error(self, @error_code, error_message)
      elsif @code && @code >= 400
        URL::HttpReturnedError.new(
          "HTTP #{@code} for #{@effective_url}",
          response: self, curl_code: 22, curl_message: URL::Request.strerror(22)
        )
      end
  end

  # Cross into exception flow on demand: raise whatever #error holds (a transport
  # failure or an HTTP status >= 400), or return self when the response is a clean
  # success — so it chains: resp.raise_for_status!.json
  def raise_for_status!
    e = error
    raise e if e
    self
  end

  def content_length
    cl = headers["content-length"]
    cl && cl.to_i
  end

  def location;          headers["location"];          end
  def server;            headers["server"];            end
  def date;              headers["date"];              end
  def etag;              headers["etag"];              end
  def last_modified;     headers["last-modified"];     end
  def cache_control;     headers["cache-control"];     end
  def transfer_encoding; headers["transfer-encoding"]; end
  def content_encoding;  headers["content-encoding"];  end

  def set_cookies
    v = headers["set-cookie"]
    return [] unless v
    v.is_a?(Array) ? v : [v]
  end

  def status;         @code;                                end
  def informational?; @code && @code >= 100 && @code < 200; end
  def success?;       @code && @code >= 200 && @code < 300; end
  def redirect?;      @code && @code >= 300 && @code < 400; end
  def client_error?;  @code && @code >= 400 && @code < 500; end
  def server_error?;  @code && @code >= 500 && @code < 600; end

  def error?
    @error_code != 0 || (@code && @code >= 400)
  end

  def error_message
    return nil if @error_code == 0
    case @error_code
    when 6  then "couldn't resolve host (#{@effective_url})"
    when 7  then "couldn't connect to #{@effective_url}"
    when 28
      t = @total_time && @total_time > 0 ? " after #{@total_time.round(1)}s" : ""
      "timed out#{t} (#{@effective_url})"
    when 35 then "SSL connect error (#{@effective_url})"
    when 60 then "SSL certificate verification failed (#{@effective_url})"
    else         "#{URL::Request.strerror(@error_code)} (#{@effective_url})"
    end
  end

  def inspect
    size = @body ? @body.bytesize : 0
    size_str = if    size < 1024        then "#{size}B"
               elsif size < 1024 * 1024 then "#{(size / 1024.0).round(1)}KB"
               else                          "#{(size / 1024.0 / 1024.0).round(1)}MB"
               end
    time_str = @total_time && @total_time > 0 ? " in #{(@total_time * 1000).round}ms" : ""
    ct_str   = @content_type ? " #{@content_type}" : ""
    "#<#{self.class} #{@code}#{ct_str} #{size_str}#{time_str} #{@effective_url.inspect}>"
  end

  def _parse_headers
    result = {}
    @raw_headers.each do |raw|
      line = raw.chomp
      if line.start_with?("HTTP/")
        result = {}
        next
      end
      next if line.empty?
      name, sep, value = line.partition(":")
      next if sep.empty?
      key = name.strip.downcase
      next if key.empty?
      val = value.strip
      if result.key?(key)
        prev = result[key]
        result[key] = prev.is_a?(Array) ? (prev << val) : [prev, val]
      else
        result[key] = val
      end
    end
    result
  end
end

# ============================================================================
#  URL::Batch — the request builder yielded by URL.parallel
#
#  Inside `URL.parallel { |p| ... }` you get one of these as `p`. Queue requests
#  with the same verbs you'd call on URL (get/head/delete/options/post/put/
#  patch), each tagged with an optional key: (defaults to its submission index,
#  so duplicate URLs stay distinct). Register on_complete to receive each
#  response as its transfer lands. The driving + result collection live in
#  URL._drive_parallel (mrblib/url/dispatch.rb).
# ============================================================================

class URL::Batch
  def initialize
    @entries     = []
    @on_complete = nil
  end

  def get(url, key: nil, **opts, &block);                _add(:GET,     url, nil,  key, opts, block); end
  def head(url, key: nil, **opts, &block);               _add(:HEAD,    url, nil,  key, opts, block); end
  def delete(url, body = nil, key: nil, **opts, &block); _add(:DELETE,  url, body, key, opts, block); end
  def options(url, key: nil, **opts, &block);            _add(:OPTIONS, url, nil,  key, opts, block); end
  def post(url, body = nil, key: nil, **opts, &block);   _add(:POST,    url, body, key, opts, block); end
  def put(url, body = nil, key: nil, **opts, &block);    _add(:PUT,     url, body, key, opts, block); end
  def patch(url, body = nil, key: nil, **opts, &block);  _add(:PATCH,   url, body, key, opts, block); end

  # Called with (key, URL::Response) as each transfer finishes — in completion
  # order, not submission order.
  def on_complete(&block)
    @on_complete = block
    self
  end

  # Internal: consumed by URL._drive_parallel.
  attr_reader :entries
  def completion_block; @on_complete; end

  private

  def _add(method, url, body, key, opts, on_chunk)
    @entries << {
      method:   method,
      url:      url,
      body:     body,
      key:      key.nil? ? @entries.size : key,
      opts:     opts,
      on_chunk: on_chunk,
    }
    self
  end
end

# ============================================================================
#  URL — the high-level verbs (the one API users call)
#
#  Blocking by default: each verb drives URL.shared (a session reused across
#  calls so libcurl's connection pool, TLS sessions and HTTP/2 streams
#  persist) and returns a URL::Response. A verb called from inside a callback
#  can't reuse the busy session, so it transparently runs on a throwaway one.
#
#  Set URL.default_loop= with a URL::EventLoop subclass to drive transfers on
#  a native loop instead; the verbs then fire-and-forget and return nil.
#
#  The dispatch behind these verbs lives in mrblib/url/dispatch.rb.
# ============================================================================

class URL
  DEFAULT_USER_AGENT      = "mruby-url".freeze
  DEFAULT_TIMEOUT_MS      = 30_000
  DEFAULT_FOLLOW_LOCATION = true

  # The protocol schemes compiled into the embedded libcurl (lowercased), e.g.
  # "http", "https", "smtp", "smtps". Published from C as a frozen Array.
  PROTOS = URL::Libcurl::PROTOCOLS

  class << self
    # True when the embedded libcurl was built with support for `proto`
    # (case-insensitive), e.g. URL.supports?("smtps").
    def supports?(proto)
      PROTOS.include?(proto.to_s.downcase)
    end
    # Set once at startup with a platform-driven EventLoop instance; the
    # verbs then attach new sessions to it and return immediately.
    def default_loop=(loop)
      unless loop.is_a?(EventLoop)
        raise TypeError, "expected a URL::EventLoop, got #{loop.class}"
      end
      @default_loop = loop
    end

    def default_loop
      @default_loop
    end

    # Per-mrb_state session reused by every blocking verb so libcurl's
    # connection pool, TLS sessions and HTTP/2 streams persist across calls.
    # Tune the pool on it directly, e.g. URL.shared.setopt(:max_total_connections, 64).
    def shared
      @shared ||= open
    end

    def get(url, **opts, &block);                _fire(:GET,     url, nil,  opts, &block); end
    def head(url, **opts, &block);               _fire(:HEAD,    url, nil,  opts, &block); end
    def delete(url, body = nil, **opts, &block); _fire(:DELETE,  url, body, opts, &block); end
    def options(url, **opts, &block);            _fire(:OPTIONS, url, nil,  opts, &block); end
    def post(url, body = nil, **opts, &block);   _fire(:POST,    url, body, opts, &block); end
    def put(url, body = nil, **opts, &block);    _fire(:PUT,     url, body, opts, &block); end
    def patch(url, body = nil, **opts, &block);  _fire(:PATCH,   url, body, opts, &block); end

    # ----------------------------------------------------------------------
    #  RFC-verb dispatch (non-HTTP protocols)
    #
    #  Each method below is named after the protocol's RFC verb (lowercased)
    #  and dispatches on the URL scheme to that protocol's implementation,
    #  gated on URL.supports?(scheme). A scheme with no arm — or an arm whose
    #  protocol libcurl wasn't built with — raises URL::Error before any
    #  connection attempt. The arms themselves live in dispatch.rb; the verbs
    #  here are the public surface.
    # ----------------------------------------------------------------------

    # send — submit/send a message. (Deliberately overrides Object#send; use
    # URL.__send__ for reflection. SMTP submission has no single issuable RFC
    # verb — curl runs MAIL/RCPT/DATA for us.) For smtp/smtps this is the
    # mail-send path: `server_url` carries the scheme (e.g.
    # "smtps://mail.example.com:465"); `body` is the full RFC822 message
    # (positional); `from:`/`to:` are the envelope (to: a String or an Array).
    # The body is streamed to libcurl's read callback, chunked in Ruby. Extra
    # **opts (ssl_verify_peer:, userpwd:, timeout_ms:, …) pass straight through
    # to setopt. Blocking, like the verbs: returns a URL::Response whose `code`
    # is the final SMTP reply (e.g. 250).
    def send(server_url, body, from:, to:, **opts)
      case _scheme_of(server_url)
      when "smtp", "smtps"
        _require_protocol!(server_url)
        session    = shared
        session    = open if session._busy?
        recipients = to.is_a?(Array) ? to : [to]
        req, state = _build_mail_request(session, server_url, from, recipients, body, opts)
        _drive_sync(session, server_url, req, state)
      else
        raise URL::Error, "send not available for #{_scheme_of(server_url)}"
      end
    end

    # UID MOVE (RFC 6851) — move message `uid:` to mailbox `to:`. The source
    # mailbox is the URL path (imaps://host/INBOX); the uid goes into the
    # command, not the URL. Returns a URL::Response; raises URL::Error on a
    # NO/BAD reply.
    def move(url, uid:, to:, **opts)
      case _scheme_of(url)
      when "imap", "imaps"
        _require_protocol!(url)
        _imap(url, "UID MOVE #{uid} #{to}", opts)
      else
        raise URL::Error, "move not available for #{_scheme_of(url)}"
      end
    end

    # UID STORE (RFC 3501 §6.4.6) — change flags on message `uid:`. `op:` is
    # "+" (add, the default), "-" (remove) or "" (replace); `flags:` is the
    # flag string, e.g. "\\Deleted". Returns a URL::Response; raises on failure.
    def store(url, uid:, flags:, op: "+", **opts)
      case _scheme_of(url)
      when "imap", "imaps"
        _require_protocol!(url)
        _imap(url, "UID STORE #{uid} #{op}FLAGS (#{flags})", opts)
      else
        raise URL::Error, "store not available for #{_scheme_of(url)}"
      end
    end

    # EXPUNGE (RFC 3501 §6.4.3) — permanently remove \Deleted-flagged messages
    # from the mailbox in the URL path. Returns a URL::Response; raises on
    # failure. Deleting a message is the documented two-step idiom:
    # store(uid:, flags: "\\Deleted") then expunge(url).
    def expunge(url, **opts)
      case _scheme_of(url)
      when "imap", "imaps"
        _require_protocol!(url)
        _imap(url, "EXPUNGE", opts)
      else
        raise URL::Error, "expunge not available for #{_scheme_of(url)}"
      end
    end

    # UID FETCH (RFC 3501 §6.4.5) — fetch message `uid:` from the mailbox in
    # the URL path. Implemented as a plain transfer against the IMAP URL with
    # ";UID=<uid>" appended, so curl issues "UID FETCH <uid> BODY[]" itself and
    # hands the message bytes to the write callback. The message is returned in
    # the Response body, or streamed to `&block` if one is given. Raises on a
    # NO/BAD reply.
    def fetch(url, uid:, **opts, &block)
      case _scheme_of(url)
      when "imap", "imaps"
        _require_protocol!(url)
        _imap(url, nil, opts, ";UID=#{uid}", block)
      else
        raise URL::Error, "fetch not available for #{_scheme_of(url)}"
      end
    end

    # ----------------------------------------------------------------------
    #  Parallel fan-out
    # ----------------------------------------------------------------------

    # Run several requests concurrently on one session and collect them as they
    # finish. Inside the block, queue requests on the yielded URL::Batch (same
    # verbs as URL), each tagged with an optional key: (defaults to its
    # submission index, so duplicate URLs stay distinct). Returns a Hash of
    # { key => URL::Response } once all complete; register p.on_complete to also
    # receive each response the moment its transfer lands.
    #
    #   results = URL.parallel do |p|
    #     p.get("https://a.example/feed",   key: :feed)
    #     p.post("https://b.example/login", key: :login, json: { ... })
    #     p.on_complete { |key, resp| warm(key, resp) }
    #   end
    #   results[:feed].json
    #
    # Runs on URL.shared by default — so the connection pool, TLS sessions and
    # HTTP/2 multiplexing carry over — falling back to a throwaway session when
    # called re-entrantly from inside a callback. Runtime failures are values
    # like everywhere else: each Response's #error is set, nothing is raised.
    def parallel
      raise ArgumentError, "URL.parallel requires a block" unless block_given?
      batch = Batch.new
      yield batch
      _drive_parallel(batch.entries, batch.completion_block)
    end
  end

  # Per-session event loop. Users only touch this for bring-your-own-loop
  # integration; the verbs set it internally.
  def event_loop
    @event_loop
  end

  def event_loop=(loop)
    unless loop.nil? || loop.is_a?(EventLoop)
      raise TypeError, "expected a URL::EventLoop, got #{loop.class}"
    end
    @event_loop = loop
  end
end
