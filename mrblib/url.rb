# mrblib/url.rb

# ============================================================================
#  URL::Error / URL::HTTPError
# ============================================================================
JSON.zero_copy_parsing = true
class URL
  class Error < StandardError; end

  # Raised by Response#raise_for_status! when a request resulted in a
  # transport error (curl error code != 0) or an HTTP response of 4xx/5xx.
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
#  URL::EventLoop
#
#  The integration interface for real event loops. Subclass, override
#  #on_socket and #on_timer, hand an instance to URL#event_loop=. libcurl
#  will call into your loop whenever it needs fds watched or a wake-up
#  scheduled.
#
#  Your loop calls back into the session:
#
#    session.socket_action(fd, :in | :out | :inout | :err)
#                                          a watched fd became ready
#    session.socket_action                 the timer you scheduled fired
#    session.info_read { |req, code| }     drain completed transfers (after
#                                          every socket_action)
# ============================================================================

class URL::EventLoop
  # libcurl wants you to start, modify, or stop watching `fd`.
  #
  # `what` is one of:
  #   :in     - wake when fd is readable
  #   :out    - wake when fd is writable
  #   :inout  - wake on either
  #   :remove - stop watching this fd entirely
  def on_socket(fd, what)
    raise NotImplementedError, "#{self.class}#on_socket(fd, what)"
  end

  # libcurl wants you to (re-)arm a single one-shot wake-up.
  #
  # `ms` is the delay in milliseconds. ms < 0 means cancel any pending timer.
  def on_timer(ms)
    raise NotImplementedError, "#{self.class}#on_timer(ms)"
  end
end

# ============================================================================
#  URL#event_loop=
# ============================================================================

class URL
  def event_loop=(loop)
    unless loop.is_a?(EventLoop)
      raise TypeError, "expected a URL::EventLoop, got #{loop.class}"
    end
    @event_loop = loop
  end

  def event_loop
    @event_loop
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

  def append_body(chunk);   @body << chunk;        end
  def append_header(line);  @raw_headers << line;  end
end

# ============================================================================
#  URL::IOSelectLoop
#
#  Built-in EventLoop subclass. Drives transfers with IO.select on raw
#  integer fds — no mruby-io IO objects involved, which avoids the
#  autoclose-on-GC hazard libcurl-owned fds would otherwise hit (mruby-io
#  has no IO#autoclose= and would close the fd on the IO's finalizer).
# ============================================================================

class URL::IOSelectLoop < URL::EventLoop
  def initialize(session)
    @session    = session
    @watched    = {}    # fd_int => :in / :out / :inout
    @ios        = {}    # fd_int => IO    (keeps wrapper alive across calls)
    @timeout_ms = 0
  end

  def on_socket(io, what)
    fd_int = io.fileno
    case what
    when :in, :out, :inout
      @watched[fd_int] = what
      @ios[fd_int]     = io       # may overwrite a previous wrapper for same fd
    when :remove
      @watched.delete(fd_int)
      @ios.delete(fd_int)
    end
  end

  def on_timer(ms)
    @timeout_ms = ms
  end

  def run(&on_complete)
    running = @session.socket_action
    @session.info_read(&on_complete) if on_complete

    while running > 0
      reads  = []
      writes = []
      @watched.each do |fd_int, mode|
        io = @ios[fd_int]
        next unless io                  # defensive: skip if somehow desynced
        reads  << io if mode == :in  || mode == :inout
        writes << io if mode == :out || mode == :inout
      end

      sel_timeout = @timeout_ms < 0 ? nil : @timeout_ms / 1000.0
      r, w, _e = IO.select(reads, writes, nil, sel_timeout)

      if r.nil? && w.nil?
        running = @session.socket_action
      else
        r&.each { |io| running = @session.socket_action(io, :in)  }
        w&.each { |io| running = @session.socket_action(io, :out) }
      end

      @session.info_read(&on_complete) if on_complete
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

  # Parsed headers: lowercase name => String, or Array when repeated (e.g.
  # Set-Cookie). For redirect chains only the final response's headers are
  # kept; the full sequence stays in #raw_headers.
  def headers
    @headers ||= _parse_headers
  end

  def [](name)
    headers[name.to_s.downcase]
  end

  # JSON parsing (mruby-fast-json). Cached after first call. Pass the body
  # through the parser of your choice if you want different options.
  def json
    @json ||= JSON.parse(@body)
  end

  # Lazy parsing (mruby-fast-json). Returns a JSON::Document for zero-copy
  # access and integration with native_ext_type.
  #
  # Example:
  #
  #   class User
  #     attr_accessor :id, :name
  #     native_ext_type :@id,   Integer
  #     native_ext_type :@name, String
  #   end
  #
  #   response.json_lazy.into(User.new)   # fill an instance
  #   response.json_lazy.array_each do |doc|
  #     u = User.new
  #     doc.into(u)
  #     # use u
  #   end
  def json_lazy
    @json_lazy ||= JSON.parse_lazy(@body)
  end

  # Fill the ivars of `target` from the JSON response body, using whatever
  # schema `target` (or its class) declared via native_ext_type. `target`
  # may be:
  #
  #   - an instance:  fills its instance variables
  #   - a class:      fills the class's ivars (singleton-style state)
  #   - a module:     same — fills the module's ivars
  #
  # For arrays of objects, drop down to json_lazy.array_each directly so
  # you control how each instance is constructed.
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

  def status;         @code;                                       end
  def informational?; @code && @code >= 100 && @code < 200;        end
  def success?;       @code && @code >= 200 && @code < 300;        end
  def redirect?;      @code && @code >= 300 && @code < 400;        end
  def client_error?;  @code && @code >= 400 && @code < 500;        end
  def server_error?;  @code && @code >= 500 && @code < 600;        end

  def error?
    @error_code != 0 || (@code && @code >= 400)
  end

  # Decorated error message — adds context (URL, timeout duration) to the
  # common libcurl error codes so users get something actionable instead of
  # a four-word strerror string.
  def error_message
    return nil if @error_code == 0
    base = URL::Request.strerror(@error_code)
    case @error_code
    when 6  # CURLE_COULDNT_RESOLVE_HOST
      "couldn't resolve host (#{@effective_url})"
    when 7  # CURLE_COULDNT_CONNECT
      "couldn't connect to #{@effective_url}"
    when 28 # CURLE_OPERATION_TIMEDOUT
      t = @total_time && @total_time > 0 ? " after #{@total_time.round(1)}s" : ""
      "timed out#{t} (#{@effective_url})"
    when 35 # CURLE_SSL_CONNECT_ERROR
      "SSL connect error (#{@effective_url})"
    when 60 # CURLE_PEER_FAILED_VERIFICATION
      "SSL certificate verification failed (#{@effective_url})"
    else
      "#{base} (#{@effective_url})"
    end
  end

  def inspect
    size = @body ? @body.bytesize : 0
    size_str = if    size < 1024         then "#{size}B"
               elsif size < 1024 * 1024  then "#{(size / 1024.0).round(1)}KB"
               else                           "#{(size / 1024.0 / 1024.0).round(1)}MB"
               end
    time_str = @total_time && @total_time > 0 ? " in #{(@total_time * 1000).round}ms" : ""
    ct_str   = @content_type ? " #{@content_type}"                                    : ""
    "#<#{self.class} #{@code}#{ct_str} #{size_str}#{time_str} #{@effective_url.inspect}>"
  end

  def _parse_headers
    result = {}
    @raw_headers.each do |raw|
      line = raw.chomp
      if line.start_with?("HTTP/")
        result = {}                     # reset for each step of a redirect chain
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
#  Every method here uses a process-wide (per-mrb_state) shared session +
#  IOSelectLoop. libcurl's connection pool, TLS sessions, and HTTP/2 stream
#  reuse persist across calls — which is most of the perf win of using
#  multi in the first place.
#
#  Defaults applied unless explicitly overridden:
#    timeout_ms:      30_000   (30s — prevents indefinite hangs)
#    follow_location: true     (HTTP redirects followed)
#    user_agent:      "mruby-url"
#    accept_encoding: ""       (libcurl advertises and decompresses)
#
#  Convenience kwargs the shorthand understands:
#    params: { ... }           appended as URL query string (URI.encode)
#    json:   <object>          JSON.dump'd body + JSON Content-Type/Accept
#    form:   { ... }           x-www-form-urlencoded body + Content-Type
#    auth:   "user:pass" |
#            ["user", "pass"]  Basic auth via CURLOPT_USERPWD
#    bearer: "<token>"         Authorization: Bearer <token>
#    headers: { ... }          user headers; override any auto-set ones
#
#  All curl_easy setopts are also accepted as kwargs (timeout_ms, proxy,
#  cookiefile, cookiejar, verbose, etc.). See URL::Request#setopt for the
#  full list.
#
#  Streaming: pass a block to receive body chunks as they arrive instead
#  of buffering. Response#body will be "" in that case.
#
#    URL.get("https://huge.example/file") { |chunk| f.write(chunk) }
#
#  Not re-entrant: don't call a one-shot from inside an on_data / on_header
#  block that fired from the same shared session.
# ============================================================================

class URL
  DEFAULT_USER_AGENT      = "mruby-url".freeze
  DEFAULT_TIMEOUT_MS      = 30_000
  DEFAULT_FOLLOW_LOCATION = true

  class << self
    # The session used by every one-shot below. Lazy-initialised once,
    # reused forever. Public so it can be tuned.
    def shared
      @shared ||= begin
        s = open
        s.event_loop = IOSelectLoop.new(s)
        s
      end
    end

    def get(url, **opts, &block);        _fire(:GET,     url, nil,  opts, &block); end
    def head(url, **opts, &block);       _fire(:HEAD,    url, nil,  opts, &block); end
    def delete(url, body = nil, **opts, &block); _fire(:DELETE, url, body, opts, &block); end
    def options(url, **opts, &block);    _fire(:OPTIONS, url, nil,  opts, &block); end
    def post(url, body = nil, **opts, &block);   _fire(:POST,  url, body, opts, &block); end
    def put(url, body = nil, **opts, &block);    _fire(:PUT,   url, body, opts, &block); end
    def patch(url, body = nil, **opts, &block);  _fire(:PATCH, url, body, opts, &block); end

    # parallel(urls, **opts) -> { url => Response }
    #
    # Issues every URL as a concurrent GET on the shared session, drives
    # until all complete, returns a hash keyed by the exact value the
    # caller passed.
    def parallel(urls, **opts)
      session = shared

      triples = urls.map do |url|
        req, state = _build_request(:GET, url, nil, opts, nil)
        session.add(req)
        [url, req, state]
      end

      begin
        states_by_id = {}
        triples.each { |_url, req, state| states_by_id[req.object_id] = state }

        session.event_loop.run do |req, code|
          s = states_by_id[req.object_id]
          s.error_code = code if s && code != 0
        end

        out = {}
        triples.each { |url, req, state| out[url] = _response_from(url, req, state) }
        out
      ensure
        triples.each { |_url, req, _state| session.remove(req) }
      end
    end

    # Routes to a non-blocking path when the event loop has no #run
    # (platform-driven, e.g. Ascaridol::EventLoop), or to _one_shot when
    # it does (IOSelectLoop). Non-blocking returns nil; on_data callbacks
    # fire from the platform loop as data arrives.
    def _fire(method, url, body, opts, &on_chunk)
      session = shared
      if session.event_loop.respond_to?(:run)
        _one_shot(method, url, body, opts, &on_chunk)
      else
        req, _state = _build_request(method, url, body, opts, on_chunk)
        session.add(req)
        session.socket_action
        nil
      end
    end

    def _one_shot(method, url, body, opts, &on_chunk)
      session = shared
      req, state = _build_request(method, url, body, opts, on_chunk)
      session.add(req)
      begin
        session.event_loop.run do |r, code|
          state.error_code = code if r.equal?(req) && code != 0
        end
        _response_from(url, req, state)
      ensure
        session.remove(req)
      end
    end

    def _build_request(method, url, body, opts, on_chunk)
      # Pull our convenience kwargs out of opts so they don't reach setopt.
      params    = opts.delete(:params)
      json_body = opts.delete(:json)
      form_body = opts.delete(:form)
      auth      = opts.delete(:auth)
      bearer    = opts.delete(:bearer)
      user_hdrs = opts.delete(:headers)

      # Auto-set headers — user-provided ones win.
      auto_hdrs = {}

      if json_body
        body = JSON.dump(json_body)
        auto_hdrs["Content-Type"] = "application/json"
        auto_hdrs["Accept"]       = "application/json"
      elsif form_body
        body = _encode_form(form_body)
        auto_hdrs["Content-Type"] = "application/x-www-form-urlencoded"
      end

      if bearer
        auto_hdrs["Authorization"] = "Bearer #{bearer}"
      end

      # Defaults applied iff not explicitly overridden.
      opts[:timeout_ms]      = DEFAULT_TIMEOUT_MS      unless opts.key?(:timeout_ms)
      opts[:follow_location] = DEFAULT_FOLLOW_LOCATION unless opts.key?(:follow_location)
      opts[:user_agent]      = DEFAULT_USER_AGENT      unless opts.key?(:user_agent)

      # Basic auth via libcurl (libcurl builds the Authorization header).
      if auth
        user, pass = auth.is_a?(Array) ? auth : auth.to_s.split(":", 2)
        opts[:userpwd] = "#{user}:#{pass}"
      end

      url_str = _stringify_url(url, params)
      req     = URL::Request._open(url_str)

      case method
      when :GET
        # nothing
      when :HEAD
        req.setopt(:nobody, true)
      else
        req.setopt(:custom_request, method.to_s)
      end

      req.setopt(:post_fields, body) if body

      opts.each { |k, v| req.setopt(k, v) }

      # Merge headers: auto first, user overrides.
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

    # Resolve a user-supplied URL (String, URI from mruby-uri-parser, or
    # anything to_s'able) to a normalized WHATWG href, optionally appending
    # a query string built from `params`.
    def _stringify_url(url, params = nil)
      base = url.respond_to?(:href) ? url.href : URI.parse(url.to_s).href
      return base if params.nil? || params.empty?

      qs = _encode_kv(params)

      # Respect existing fragment / query.
      base_without_frag, frag = base.split("#", 2)
      sep = base_without_frag.include?("?") ? "&" : "?"
      result = "#{base_without_frag}#{sep}#{qs}"
      result = "#{result}##{frag}" if frag
      result
    end

    def _encode_form(form)
      _encode_kv(form)
    end

    # Hash -> "k=v&k=v" with URI.encode (mruby-uri-parser, WHATWG-strict).
    # Array values expand to repeated key=v pairs.
    def _encode_kv(h)
      pairs = []
      h.each do |k, v|
        ks = URI.encode(k.to_s)
        case v
        when Array
          v.each { |vv| pairs << "#{ks}=#{URI.encode(vv.to_s)}" }
        else
          pairs << "#{ks}=#{URI.encode(v.to_s)}"
        end
      end
      pairs.join("&")
    end
  end
end
