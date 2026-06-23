# mrblib/url/dispatch.rb
#
# Internal request dispatch behind the high-level verbs: turn
# (verb, url, body, opts) into a configured URL::Request, drive it to
# completion, and wrap the result in a URL::Response. Not part of the
# public API — see mrblib/url.rb for what users call.

# simdjson zero-copy parsing for URL::Response#json / #json_lazy.
JSON.zero_copy_parsing = true

class URL
  class << self
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
      _apply_opts(req, opts)

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

    # Pass option pairs through to libcurl. Most map straight to a CURLOPT_*;
    # :netrc is the exception — we translate the friendly Ruby value to the
    # CURL_NETRC_* level integer here so the C side stays a flat pass-through.
    def _apply_opts(req, opts)
      opts.each do |k, v|
        v = _netrc_level(v) if k == :netrc
        req.setopt(k, v)
      end
    end

    # Map a :netrc option value to libcurl's CURL_NETRC_* level:
    #   true / :optional -> 1 (use .netrc, fall back to the request),
    #   :required        -> 2 (use .netrc only),
    #   anything else    -> 0 (ignore .netrc).
    def _netrc_level(v)
      case v
      when true, :optional then 1
      when :required       then 2
      else                      0
      end
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

  # --- per-session bookkeeping used by the blocking dispatch ---

  # True while this session's blocking loop is driving a transfer. Lets the
  # verbs notice a re-entrant call (a URL.get from inside a callback): the
  # session can't drive a second transfer, so a throwaway one is used for
  # that nested fetch instead.
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
