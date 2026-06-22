# mrblib/url.rb
#
# One CURLM per request. URL.get / URL.post / etc. each create a fresh
# isolated session. No session is ever shared across requests, so a write
# callback that calls URL.get starts a completely independent transfer.
#
# Platform integration: set URL.default_loop= once at app startup with a
# URL::EventLoop subclass driven by your native event loop (GLib, etc.).
# That loop is attached to every new session created by the high-level
# verbs. If no default loop is set, IOSelectLoop is used for synchronous
# blocking requests.

JSON.zero_copy_parsing = true

# ============================================================================
#  URL::Error / URL::HTTPError
# ============================================================================

class URL
  class Error < StandardError; end

  class HTTPError < Error
    attr_reader :response

    def initialize(response)
      @response = response
      msg = if response.error_code != 0
              "transport error: #{response.error_message}"
            else
              "HTTP #{response.code} #{response.effective_url}"
            end
      super(msg)
    end
  end
end

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

# Session instances drive libcurl; the C socket/timer callbacks read
# @event_loop off the session. #event_loop= is the public setter for users
# plugging in their own loop; the high-level verbs set it internally.
class URL
  def event_loop
    @event_loop
  end

  def event_loop=(loop)
    unless loop.nil? || loop.is_a?(EventLoop)
      raise TypeError, "expected a URL::EventLoop, got #{loop.class}"
    end
    @event_loop = loop
  end

  # --- internal session bookkeeping (not part of the request API) ---

  # True while this session's blocking loop is driving a transfer. Lets the
  # high-level verbs notice a re-entrant call (a URL.get from inside a
  # callback): the session can't drive a second transfer, so a throwaway one
  # is used for that nested fetch instead.
  def _busy?
    @running ? true : false
  end

  def _busy=(flag)
    @running = flag
    flag
  end

  # IOSelectLoop bound to this session, created once and reused across
  # blocking calls so libcurl's socket registrations survive between requests.
  def _sync_loop
    @sync_loop ||= IOSelectLoop.new(self)
  end
end

# ============================================================================
#  URL::Request — block-style on_data / on_header setters
# ============================================================================

class URL::Request
  def on_data(&block)
    @on_data = block
    self
  end

  def on_header(&block)
    @on_header = block
    self
  end
end

# ============================================================================
#  URL::TransferState  (internal)
# ============================================================================

class URL::TransferState
  attr_accessor :error_code
  attr_reader   :body, :raw_headers

  def initialize
    @body        = String.new
    @raw_headers = []
    @error_code  = 0
  end

  def append_body(chunk);  @body << chunk;       end
  def append_header(line); @raw_headers << line; end
end

# ============================================================================
#  URL::IOSelectLoop
#
#  Synchronous pull-driven loop used when no platform loop is available.
#  Each call to #run pumps a single request to completion.
# ============================================================================

class URL::IOSelectLoop < URL::EventLoop
  def initialize(session)
    @session    = session
    @watching   = {}   # fd_int => { io:, readiness: }
    @timeout_ms = -1
  end

  def watch(io, readiness, &_block)
    fd = io.fileno
    @watching[fd] = { io: io, readiness: readiness }
    fd
  end

  def unwatch(handle)
    @watching.delete(handle)
  end

  def arm_timer(ms, &_block)
    @timeout_ms = ms
    :timer
  end

  def cancel_timer(_handle)
    @timeout_ms = -1
  end

  def run(&on_complete)
    @session.socket_action
    @session.info_read { |req, code| on_complete&.call(req, code) }

    until @watching.empty? && @timeout_ms < 0
      reads  = []
      writes = []
      @watching.each_value do |w|
        reads  << w[:io] if w[:readiness] == :in  || w[:readiness] == :inout
        writes << w[:io] if w[:readiness] == :out || w[:readiness] == :inout
      end

      sel_timeout = @timeout_ms < 0 ? nil : @timeout_ms / 1000.0
      r, w, _e = IO.select(reads, writes, nil, sel_timeout)

      if r.nil? && w.nil?
        @session.socket_action
      else
        r&.each { |io| @session.socket_action(io, :in)  }
        w&.each { |io| @session.socket_action(io, :out) }
      end

      @session.info_read { |req, code| on_complete&.call(req, code) }
    end
  end

  # Drive the session until `target` completes (or the loop falls idle),
  # rather than until every socket is gone. Required for the reused shared
  # session, whose kept-alive sockets can outlive any single request.
  def run_until(target, &on_complete)
    finished = false
    drain = lambda do |req, code|
      finished = true if req.equal?(target)
      on_complete.call(req, code) if on_complete
    end

    @session.socket_action
    @session.info_read(&drain)

    until finished
      reads  = []
      writes = []
      @watching.each_value do |w|
        reads  << w[:io] if w[:readiness] == :in  || w[:readiness] == :inout
        writes << w[:io] if w[:readiness] == :out || w[:readiness] == :inout
      end

      break if reads.empty? && writes.empty? && @timeout_ms < 0

      sel_timeout = @timeout_ms < 0 ? nil : @timeout_ms / 1000.0
      r, w, _e = IO.select(reads, writes, nil, sel_timeout)

      if r.nil? && w.nil?
        @session.socket_action
      else
        r&.each { |io| @session.socket_action(io, :in)  }
        w&.each { |io| @session.socket_action(io, :out) }
      end

      @session.info_read(&drain)
    end
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

  def raise_for_status!
    return self unless error?
    raise URL::HTTPError.new(self)
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
#  URL — high-level HTTP verbs
#
#  Each call creates a fresh isolated session (one CURLM per request).
#  If a platform event loop has been set via URL.default_loop=, the session
#  is attached to it and the call returns immediately (fire-and-forget).
#  Otherwise an IOSelectLoop is created and the call blocks until done.
# ============================================================================

class URL
  DEFAULT_USER_AGENT      = "mruby-url".freeze
  DEFAULT_TIMEOUT_MS      = 30_000
  DEFAULT_FOLLOW_LOCATION = true

  class << self
    # Set once at startup with a platform-driven EventLoop instance.
    # All non-blocking verbs will attach new sessions to this loop.
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

    def _fire(method, url, body, opts, &on_chunk)
      if @default_loop
        _fire_async(method, url, body, opts, &on_chunk)
      else
        _fire_sync(method, url, body, opts, &on_chunk)
      end
    end

    # Non-blocking: attach to the platform loop and return immediately.
    # The session lives until info_read sees the request complete, at which
    # point the action block calls session.remove and lets GC clean up.
    def _fire_async(method, url, body, opts, &on_chunk)
      session = open
      session.event_loop = @default_loop
      req, _state = _build_request(session, method, url, body, opts, on_chunk)
      session.add(req)
      session.socket_action
      nil
    end

    # Blocking. Reuse the shared session, except when it's already mid-flight
    # because we were called from inside one of its callbacks — then it can't
    # drive a second transfer, so this nested fetch gets a throwaway session.
    def _fire_sync(method, url, body, opts, &on_chunk)
      session = shared
      session = open if session._busy?

      loop = session._sync_loop
      session.event_loop = loop

      req, state = _build_request(session, method, url, body, opts, on_chunk)
      session.add(req)
      session._busy = true

      begin
        loop.run_until(req) do |r, code|
          state.error_code = code if r.equal?(req) && code != 0
        end
        _response_from(url, req, state)
      ensure
        session._busy = false
        session.remove(req) rescue nil
      end
    end

    def _build_request(session, method, url, body, opts, on_chunk)
      params    = opts.delete(:params)
      json_body = opts.delete(:json)
      form_body = opts.delete(:form)
      auth      = opts.delete(:auth)
      bearer    = opts.delete(:bearer)
      user_hdrs = opts.delete(:headers)

      auto_hdrs = {}

      if json_body
        body = JSON.dump(json_body)
        auto_hdrs["Content-Type"] = "application/json"
        auto_hdrs["Accept"]       = "application/json"
      elsif form_body
        body = _encode_form(form_body)
        auto_hdrs["Content-Type"] = "application/x-www-form-urlencoded"
      end

      auto_hdrs["Authorization"] = "Bearer #{bearer}" if bearer

      opts[:timeout_ms]      = DEFAULT_TIMEOUT_MS      unless opts.key?(:timeout_ms)
      opts[:follow_location] = DEFAULT_FOLLOW_LOCATION unless opts.key?(:follow_location)
      opts[:user_agent]      = DEFAULT_USER_AGENT       unless opts.key?(:user_agent)

      if auth
        user, pass = auth.is_a?(Array) ? auth : auth.to_s.split(":", 2)
        opts[:userpwd] = "#{user}:#{pass}"
      end

      url_str = _stringify_url(url, params)
      req     = URL::Request._open(session, url_str)

      case method
      when :GET    then # nothing
      when :HEAD   then req.setopt(:nobody, true)
      else              req.setopt(:custom_request, method.to_s)
      end

      req.setopt(:post_fields, body) if body
      opts.each { |k, v| req.setopt(k, v) }

      merged = auto_hdrs
      if user_hdrs
        merged = auto_hdrs.dup
        user_hdrs.each { |k, v| merged[k.to_s] = v }
      end
      req.headers = merged unless merged.empty?

      state = URL::TransferState.new
      if on_chunk
        req.on_data { |chunk| on_chunk.call(chunk) }
      else
        req.on_data { |chunk| state.append_body(chunk) }
      end
      req.on_header { |line| state.append_header(line) }

      [req, state]
    end

    def _response_from(url, req, state)
      URL::Response.new(
        url:           url,
        effective_url: req.effective_url,
        code:          req.response_code,
        body:          state.body,
        raw_headers:   state.raw_headers,
        total_time:    req.total_time,
        content_type:  req.content_type,
        error_code:    state.error_code,
      )
    end

    def _stringify_url(url, params = nil)
      base = url.respond_to?(:href) ? url.href : URI.parse(url.to_s).href
      return base if params.nil? || params.empty?
      qs = _encode_kv(params)
      base_without_frag, frag = base.split("#", 2)
      sep    = base_without_frag.include?("?") ? "&" : "?"
      result = "#{base_without_frag}#{sep}#{qs}"
      result = "#{result}##{frag}" if frag
      result
    end

    def _encode_form(form)
      _encode_kv(form)
    end

    def _encode_kv(h)
      pairs = []
      h.each do |k, v|
        ks = URI.encode(k.to_s)
        case v
        when Array then v.each { |vv| pairs << "#{ks}=#{URI.encode(vv.to_s)}" }
        else            pairs << "#{ks}=#{URI.encode(v.to_s)}"
        end
      end
      pairs.join("&")
    end
  end
end