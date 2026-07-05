# mrblib/url.rb
#
# Public surface of mruby-url. Everything a user is meant to call lives here:
#
#   URL("https://x").get / .head / .delete / .options / .post / .put / .patch
#   URL("ftp://h/p").download / .upload / .list
#   URL("imaps://h/INBOX").fetch / .move / .store / .expunge
#   URL("smtps://h").deliver(body, from:, to:)
#   URL("wss://h/sock").connect           — see mrblib/url/endpoints.rb
#   URL("https://x").parallel(:get) { |r| ... }; URL.parallel_perform — fan-out
#   URL.shared          - the reused per-state session (tune its pool)
#   URL.default_loop=   - plug in a platform event loop once at startup
#   URL::Response       - what the verbs return
#   URL::EventLoop      - subclass to integrate a native event loop
#   URL::Error          - usage errors raise it; the per-CURLcode transfer-error
#                         family (Response#error) descends from it — see
#                         mrblib/url/errors.rb
#
# The internal plumbing (request dispatch, the built-in blocking driver,
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
              :total_time, :content_type, :error_code, :retry_after

  def initialize(url:, effective_url:, code:, body:, raw_headers:,
                 total_time:, content_type:, error_code:, retry_after: nil)
    @url           = url
    @effective_url = effective_url
    @code          = code
    @body          = body
    @raw_headers   = raw_headers
    @total_time    = total_time
    @content_type  = content_type
    @error_code    = error_code
    @retry_after   = retry_after
  end

  def headers
    @headers ||= _parse_headers
  end

  # The body split into non-empty lines — handy for directory/message listings
  # from URL("ftp://h/").list and other line-oriented protocol responses.
  # Regex-free so it never depends on the regexp mrbgem being built in.
  def lines
    (@body || "").split("\n").map { |l| l.chomp("\r") }.reject(&:empty?)
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

  # Redo the request that produced this failed Response — same URL, verb and
  # arguments — at most `times` times. Failures only: on a Response whose
  # #error is nil there is nothing to redo and this raises URL::Error.
  #
  # What "redo" means depends on where the Response came from:
  #   * a blocking verb's Response re-runs the request right here, up to
  #     `times` times, stopping early on success, and returns the last
  #     Response:
  #       r = URL("https://x").get
  #       r = r.retry(3) if r.error
  #   * a Response delivered to a parallel handler block resubmits its
  #     transfer (with the same handler); the resubmission runs as the running
  #     URL.parallel_perform's next round — one perform call finishes the job,
  #     retries included. `times` is the budget of the whole registration
  #     lineage: once the transfer has been retried that often, further retry
  #     calls return false instead of resubmitting, so the perform drains by
  #     itself — no hand-rolled attempt counter:
  #       URL("https://x").parallel(:get) { |r| r.retry(3) if r.error }
  #       URL.parallel_perform            # at most 4 attempts, then done
  #     This works ONLY while the handler runs — it is the one place a
  #     parallel Response exists; afterwards retry raises URL::Error.
  #
  # `wait:` is how long to pause before each re-run — any chrono duration or
  # seconds (500.ms, 2.s, 1.5). When omitted, the server decides: if the
  # failed response carried a Retry-After header (as 429/503 replies often
  # do — libcurl parses it, see #retry_after), that many seconds are waited;
  # otherwise the retry starts immediately.
  #
  # Caveat: an upload whose body is an IO / Enumerator resumes from wherever
  # the failed attempt left it — String bodies re-upload from the start.
  def retry(times = 1, wait: nil)
    unless times.is_a?(Integer) && times >= 1
      raise ArgumentError, "retry times must be an Integer >= 1, got #{times.inspect}"
    end
    unless wait.nil? || (wait.respond_to?(:to_f) && wait.to_f >= 0)
      raise ArgumentError, "retry wait must be a duration/seconds >= 0, got #{wait.inspect}"
    end
    if error.nil?
      raise URL::Error, "nothing to retry — the transfer succeeded (#{@effective_url})"
    end
    unless @retry_proc
      raise URL::Error,
            "this Response can no longer be retried — a parallel Response only retries inside its handler block"
    end
    @retry_proc.call(times, wait)
  end

  # Internal: how to redo the request that produced this Response. Stamped by
  # URL::SyncExec (re-run now, return the new Response) and, only for the
  # duration of the handler call, by URL.parallel_perform (re-register for the
  # next perform, return self).
  def _retry_with(prc)
    @retry_proc = prc
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
#  URL::Batch — internal collector behind URL(uri).parallel
#
#  URL(uri).parallel(:verb, ...) registers a transfer here instead of running
#  it; URL.parallel_perform drives everything registered and resolves each
#  transfer's Response into the block it was registered with. Users never see
#  this class. Each entry is { key:, url:, build:, post: } where `build`
#  configures the Request on the batch session at drive time and `post`, when
#  set, rewraps the finished Response (MQTT subscribe); keys are registration
#  indices, used internally to route each Response to its handler.
# ============================================================================

class URL::Batch
  def initialize
    @entries  = []
    @handlers = {}
  end

  # Internal: consumed by URL._drive_parallel / URL.parallel_perform.
  attr_reader :entries

  # Internal: append one registered transfer; returns its key. `attempts`
  # counts how often this registration lineage has been retried and `wait`
  # is the pause this entry asked for before running — both ride along so
  # Response#retry(times, wait:) works across rounds.
  def _push(url, key, post, build, attempts = 0, wait = 0)
    key = @entries.size if key.nil?
    @entries << { key: key, url: url, build: build, post: post, attempts: attempts, wait: wait }
    key
  end

  def _handler(key, block)
    @handlers[key] = block if block
    key
  end

  def _handler_for(key)
    @handlers[key]
  end
end

# The executor SchemeKwargs#parallel hands to the queueing copy of its
# wrapper: the verb's operation is stored as a batch entry (a _build_* call
# deferred until URL._drive_parallel has picked the session) instead of
# running immediately. Mirror image of URL::SyncExec (mrblib/url/dispatch.rb)
# — same interface, registering instead of driving. Every method returns the
# entry's key.
class URL::Batch::Exec
  def initialize(batch, key)
    @batch = batch
    @key   = key
  end

  # Each build lambda dups the opts before handing them to the _build_* helper
  # (the helpers strip keys as they consume them), so the same entry can be
  # built again — that's what makes Response#retry re-registration safe.
  def fire(method, url, body, opts, &on_chunk)
    @batch._push(url, @key, nil,
                 lambda { |s| URL._build_request(s, method, url, body, opts.dup, on_chunk) })
  end

  def transfer(url, opts, on_chunk, upload_data, post = nil)
    @batch._push(url, @key, post,
                 lambda { |s| URL._build_transfer(s, url, opts.dup, on_chunk, upload_data) })
  end

  def imap(mailbox_url, command, opts, url_suffix = nil, on_chunk = nil)
    @batch._push(mailbox_url, @key, nil,
                 lambda { |s| URL._build_imap_request(s, mailbox_url, command, opts.dup, url_suffix, on_chunk) })
  end

  def deliver(server_url, from, recipients, body, opts)
    @batch._push(server_url, @key, nil,
                 lambda { |s| URL._build_mail_request(s, server_url, from, recipients, body, opts.dup) })
  end

  def websocket(url, _opts)
    raise ArgumentError,
          "WebSocket connect cannot be registered for URL.parallel_perform — " \
          "it returns a live socket, not a Response (#{url})"
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
  DEFAULT_TIMEOUT         = 30.0   # seconds; a chrono duration, same as 30.s
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

    # ----------------------------------------------------------------------
    #  Parallel fan-out
    # ----------------------------------------------------------------------

    # Internal: the batch URL(uri).parallel registers into, created lazily on
    # the first registration and consumed (and cleared) by parallel_perform.
    def _pending_batch
      @_pending_batch ||= Batch.new
    end

    # Drive every transfer registered with URL(uri).parallel since the last
    # perform — all concurrently on one session. This is ONLY a driver: it
    # returns nil. Each transfer's resolved URL::Response is passed to the
    # block it was registered with, in completion order — the handler block
    # is the one place a parallel Response exists (a block-less registration
    # resolves silently). Registrations are pending process-wide until
    # performed.
    #
    #   URL("https://a.example/feed").parallel(:get)  { |r| feed = r.json }
    #   URL("https://b.example/login").parallel(:post, json: creds) { |r| token = r }
    #   URL("ftp://h/manifest.txt").parallel(:download) { |r| manifest = r.body }
    #   URL.parallel_perform
    #
    # Inside its handler a failed Response can resubmit itself with
    # #retry(times) — the resubmission is picked up by THIS perform: after
    # each round, anything the handlers registered (retries or fresh parallel
    # registrations) is driven as the next round, until nothing is pending.
    # One parallel_perform call therefore finishes the whole job, retries
    # included; the `times` budget rides with each registration, so even an
    # unconditional `r.retry(3) if r.error` drains by itself (see
    # URL::Response#retry). Once its handler returns, a Response can no
    # longer be retried.
    #
    # Runs on URL.shared by default — so the connection pool, TLS sessions and
    # HTTP/2 multiplexing carry over — falling back to a throwaway session
    # when called re-entrantly from inside a callback. Runtime failures are
    # values like everywhere else: each Response's #error is set, nothing is
    # raised; usage errors raise at registration time, before any I/O.
    def parallel_perform
      while (batch = @_pending_batch)
        @_pending_batch = nil
        return nil if batch.entries.empty?

        # Retried entries may have asked to wait (explicit wait: or the
        # server's Retry-After). Rounds are driven together, so pause for the
        # longest ask — every retry waits at least as long as it wanted.
        _wait(batch.entries.map { |e| e[:wait].to_f }.max)

        by_key = {}
        batch.entries.each { |e| by_key[e[:key]] = e }

        _drive_parallel(batch.entries, lambda { |key, resp|
          handler = batch._handler_for(key)
          if handler
            entry = by_key[key]
            resp._retry_with(lambda { |times, wait|
              if entry[:attempts] >= times
                false               # budget spent: don't resubmit, let the perform drain
              else
                b = _pending_batch
                b._handler(b._push(entry[:url], nil, entry[:post], entry[:build],
                                   entry[:attempts] + 1, wait || resp.retry_after || 0),
                           handler)
                resp
              end
            })
            begin
              handler.call(resp)
            ensure
              resp._retry_with(nil)   # a parallel Response only retries inside its handler
            end
          end
        })
      end
      nil
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
