# mrblib/url.rb
#
# Public surface of mruby-url. Everything a user is meant to call lives here:
#
#   URL.get / .head / .delete / .options / .post / .put / .patch
#   URL.shared          - the reused per-state session (tune its pool)
#   URL.default_loop=   - plug in a platform event loop once at startup
#   URL::Response       - what the verbs return
#   URL::EventLoop      - subclass to integrate a native event loop
#   URL::Error / URL::HTTPError
#
# The internal plumbing (request dispatch, the built-in IO.select loop,
# transfer buffering, the Request callback setters) lives under mrblib/url/.
# Dir.glob sorts "url.rb" before "url/...", so this file loads first and the
# user-facing classes here — including URL::EventLoop, which the internal
# URL::IOSelectLoop subclasses — are defined before the plumbing loads.

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

  class << self
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
