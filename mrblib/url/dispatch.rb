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

      req, state = _build_request(session, method, url, body, opts, on_chunk)
      _drive_sync(session, url, req, state)
    end

    # Verb-agnostic blocking drive shared by the HTTP verbs, URL.data and the
    # IMAP verbs.
    # Attaches `req` to `session`'s reused IO.select loop, pumps it until the
    # request completes, and wraps the outcome in a URL::Response. The caller
    # supplies a fully configured Request and its TransferState; this only owns
    # the add/run/remove lifecycle and the busy flag, so HTTP and SMTP share
    # exactly the same hybrid shared/fresh-session machinery.
    def _drive_sync(session, url, req, state)
      loop = session._sync_loop
      session.event_loop = loop

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

    # Drive a batch of requests concurrently on one session and collect their
    # responses. Reuses the shared session (so the connection pool, TLS sessions
    # and HTTP/2 multiplexing carry over) unless it's mid-callback, in which case
    # a throwaway one is used — the same hybrid rule the blocking verbs follow.
    # All requests are added up front, then one IO.select loop drives them
    # together; each response is handed to on_complete (key, resp) the moment its
    # transfer finishes, and the full { key => URL::Response } Hash is returned
    # once all are done. Like the verbs, a runtime failure is a Response whose
    # resp.error is set — never a raise.
    def _drive_parallel(entries, on_complete)
      return {} if entries.empty?

      session = shared
      session = open if session._busy?

      loop = session._sync_loop
      session.event_loop = loop

      by_req  = {}
      results = {}

      entries.each do |e|
        req, state = _build_request(session, e[:method], e[:url], e[:body], e[:opts], e[:on_chunk])
        by_req[req.object_id] = [e[:key], e[:url], req, state]
        session.add(req)
      end

      session._busy = true
      begin
        loop.run_n(entries.size) do |req, code|
          entry = by_req[req.object_id]
          next unless entry
          key, url, r, state = entry
          state.error_code = code if code != 0
          resp = _response_from(url, r, state)
          results[key] = resp
          on_complete.call(key, resp) if on_complete
        end
        results
      ensure
        session._busy = false
        by_req.each_value { |(_k, _u, r, _s)| session.remove(r) rescue nil }
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

    # Build the URL::Request for an SMTP/SMTPS send. The envelope (MAIL FROM /
    # RCPT TO) and the upload toggle go through the flat setopt primitives; the
    # message body is streamed through the read callback, chunked entirely in
    # Ruby (String#byteslice + a tracked offset), never relying on C to slice.
    def _build_mail_request(session, server_url, from, recipients, body, opts)
      opts[:timeout_ms] = DEFAULT_TIMEOUT_MS unless opts.key?(:timeout_ms)

      url_str = _stringify_url(server_url, nil)
      req     = URL::Request._open(session, url_str)

      _, reader = _upload_reader(body)
      req.setopt(:upload, true)
      req.setopt(:mail_from, from.to_s)
      req.setopt(:mail_rcpt, recipients.map(&:to_s))
      _apply_opts(req, opts)

      req.on_read(&reader)

      state = URL::TransferState.new
      req.on_data   { |chunk| state.append_body(chunk) }
      req.on_header { |line|  state.append_header(line) }

      [req, state]
    end

    # Build a URL::Request for an IMAP/IMAPS command. The mailbox is the URL
    # path (imaps://host/INBOX); `command`, when given, is handed to libcurl as
    # CURLOPT_CUSTOMREQUEST and runs after curl's own LOGIN/SELECT — exactly the
    # `curl -X '<command>'` flow. `url_suffix` lets a verb append IMAP URL parts
    # (e.g. ";UID=<n>") so a plain transfer fetches a message via the write
    # callback. on_chunk, when supplied, streams the body instead of buffering.
    def _build_imap_request(session, mailbox_url, command, opts, url_suffix = nil, on_chunk = nil)
      opts[:timeout_ms] = DEFAULT_TIMEOUT_MS unless opts.key?(:timeout_ms)

      url_str = _stringify_url(mailbox_url, nil)
      url_str = "#{url_str}#{url_suffix}" if url_suffix
      req     = URL::Request._open(session, url_str)

      req.setopt(:custom_request, command) if command
      _apply_opts(req, opts)

      state = URL::TransferState.new
      if on_chunk
        req.on_data { |chunk| on_chunk.call(chunk) }
      else
        req.on_data { |chunk| state.append_body(chunk) }
      end
      req.on_header { |line| state.append_header(line) }

      [req, state]
    end

    # Shared front of an IMAP verb: pick the shared session (or a fresh one when
    # re-entrant), build the request, drive it. Centralises the session choice
    # so each verb arm is a one-liner that just names its IMAP command. A NO/BAD
    # reply is a runtime error like any other — it comes back as a Response whose
    # error_code is non-zero (so resp.error holds a URL::TransportError), not as
    # a raise.
    def _imap(mailbox_url, command, opts, url_suffix = nil, on_chunk = nil)
      session = shared
      session = open if session._busy?
      req, state = _build_imap_request(session, mailbox_url, command, opts, url_suffix, on_chunk)
      _drive_sync(session, mailbox_url, req, state)
    end

    # Open a WebSocket: build a CONNECT_ONLY=2 request and run the upgrade
    # handshake with a blocking curl_easy_perform, which leaves the live socket
    # on the easy handle for the framing primitives — libcurl's documented ws
    # flow. The handle is standalone (never added to a multi), so nothing has to
    # detach it afterwards. A failed handshake is a value on the returned socket
    # (ws.error / ws.open?), never a raise — the HTTP verbs' two-tier model.
    def _open_websocket(url, opts)
      opts = opts.dup
      opts[:timeout_ms] = DEFAULT_TIMEOUT_MS unless opts.key?(:timeout_ms)
      user_hdrs = opts.delete(:headers)
      params    = opts.delete(:params)

      url_str = _stringify_url(url, params)
      req     = URL::Request._open(shared, url_str)
      req.setopt(:connect_only, 2)   # 2 = WebSocket: curl runs the upgrade, then hands back
      _apply_opts(req, opts)
      req.headers = user_hdrs if user_hdrs && !user_hdrs.empty?

      code = req.perform
      URL::WebSocket.new(req, code)
    end

    # ----------------------------------------------------------------------
    #  Generic transfer core (the non-HTTP protocols ride this)
    # ----------------------------------------------------------------------

    # Run a plain transfer for any supported scheme and return a URL::Response.
    # `on_chunk` streams the body instead of buffering; `upload_data`, when set,
    # turns it into an upload driven by the read callback. Reuses the same
    # shared/throwaway session + IO.select drive as the HTTP verbs, so all
    # protocols share one code path.
    def _run_transfer(url, opts, on_chunk, upload_data)
      session = shared
      session = open if session._busy?
      req, state = _build_transfer(session, url, opts, on_chunk, upload_data)
      _drive_sync(session, url, req, state)
    end

    def _build_transfer(session, url, opts, on_chunk, upload_data)
      opts = opts.dup
      opts[:timeout_ms] = DEFAULT_TIMEOUT_MS unless opts.key?(:timeout_ms)
      user_hdrs = opts.delete(:headers)
      params    = opts.delete(:params)

      url_str = params ? _stringify_url(url, params) : url.to_s
      req     = URL::Request._open(session, url_str)

      if upload_data
        size, reader = _upload_reader(upload_data)
        req.setopt(:upload, true)
        req.setopt(:infilesize, size) if size
      end
      _apply_opts(req, opts)
      req.headers = user_hdrs if user_hdrs && !user_hdrs.empty?

      state = URL::TransferState.new

      req.on_read(&reader) if upload_data

      if on_chunk
        req.on_data { |c| on_chunk.call(c) }
      else
        req.on_data { |c| state.append_body(c) }
      end
      req.on_header { |l| state.append_header(l) }

      [req, state]
    end

    # Extract the application payload from a libcurl MQTT message body, which is
    # framed as [2-byte big-endian topic length][topic][payload]. Returns the
    # payload bytes (or the body unchanged if it is too short to be framed).
    def _mqtt_payload(body)
      return body if body.nil? || body.bytesize < 2
      tlen = (body.getbyte(0) << 8) | body.getbyte(1)
      return body if body.bytesize < 2 + tlen
      body.byteslice(2 + tlen, body.bytesize - 2 - tlen)
    end

    # Turn an upload body into a [size, reader] pair the read callback can drive.
    # `body` is duck-typed (most specific wins):
    #   1. responds_to?(:read)   — IO-like (File / StringIO / Socket / Tempfile)
    #                              — chunks pulled from body.read(max). Size from
    #                              #size or #stat when available; otherwise libcurl
    #                              uploads as a stream and stops on "".
    #   2. responds_to?(:resume) — Fiber-like — each resume(max) yields the next
    #                              chunk (String). Stop when alive? is false or it
    #                              returns nil / non-String.
    #   3. responds_to?(:call)   — Proc/Lambda/Method — call(max) returns chunk.
    #   4. responds_to?(:each)   — Enumerable — chunks come via to_enum.next; we
    #                              buffer and slice to honour max.
    #   5. fallback              — String (via to_s) — byteslice + offset.
    # In the streaming variants size is unknown up front, so CURLOPT_INFILESIZE
    # is skipped; libcurl will use chunked encoding where the protocol allows it.
    # The body is NOT closed for the caller — opening/closing stays your job,
    # just like every other Ruby IO.
    def _upload_reader(body)
      if body.respond_to?(:read)
        size = begin
                 body.respond_to?(:size) ? body.size :
                 body.respond_to?(:stat) ? body.stat.size : nil
               rescue StandardError
                 nil
               end
        reader = lambda do |max|
          chunk = body.read(max)
          chunk.nil? ? "" : chunk        # nil = EOF
        end
        [size, reader]

      elsif body.respond_to?(:resume)
        reader = lambda do |max|
          break "" if body.respond_to?(:alive?) && !body.alive?
          chunk = body.resume(max) rescue nil
          chunk.is_a?(String) ? chunk : ""
        end
        [nil, reader]

      elsif body.respond_to?(:call)
        reader = lambda do |max|
          chunk = body.call(max)
          chunk.is_a?(String) ? chunk : ""
        end
        [nil, reader]

      elsif body.respond_to?(:each)
        en  = body.to_enum
        buf = String.new
        eof = false
        reader = lambda do |max|
          while buf.bytesize < max && !eof
            begin
              buf << en.next.to_s
            rescue StopIteration
              eof = true
            end
          end
          if buf.empty?
            ""
          else
            take = buf.byteslice(0, max)
            buf  = buf.byteslice(take.bytesize, buf.bytesize - take.bytesize) || String.new
            take
          end
        end
        [nil, reader]

      else
        payload = body.to_s
        offset  = 0
        reader  = lambda do |max|
          if offset >= payload.bytesize
            ""
          else
            chunk   = payload.byteslice(offset, max)
            offset += chunk.bytesize
            chunk
          end
        end
        [payload.bytesize, reader]
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

    # Guard that the embedded libcurl was built with the URL's scheme. Called by
    # the RFC-verb arms after they've matched a scheme they implement, so an
    # unbuilt protocol (e.g. imaps on a libcurl without it) raises a clear error
    # before any connection attempt.
    def _require_protocol!(url)
      scheme = _scheme_of(url)
      return if supports?(scheme)
      raise URL::Error, "protocol not available: #{scheme}"
    end

    # Lowercased scheme of a URL given as a String or a URI-like object (one
    # responding to #scheme). Used to gate the RFC verbs against the
    # compiled-in protocol list.
    def _scheme_of(url)
      s = if url.respond_to?(:scheme)
            url.scheme
          else
            URI.parse(url.to_s).scheme
          end
      s.to_s.downcase
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

    # Apply user-supplied curl options to the request. Only :netrc needs
    # massaging — its friendly value is mapped to libcurl's enum here so the C
    # setopt stays a flat int pass-through; everything else is verbatim.
    def _apply_opts(req, opts)
      opts.each do |k, v|
        v = _netrc_level(v) if k == :netrc
        req.setopt(k, v)
      end
    end

    # CURLOPT_NETRC enum: ignored(0) / optional(1) / required(2).
    def _netrc_level(v)
      case v
      when true, :optional then 1
      when :required       then 2
      else                      0   # false / nil / anything else => ignored
      end
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
