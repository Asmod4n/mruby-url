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
    # With a default_loop set: attach to the platform loop and return nil
    # immediately (the session lives until info_read sees the request
    # complete). Otherwise block: drive on the shared session — or a
    # throwaway one when called re-entrantly from inside its callbacks — and
    # return the Response.
    def _fire(method, url, body, opts, &on_chunk)
      if @default_loop
        session = open
        session.event_loop = @default_loop
        req, _state = _build_request(session, method, url, body, opts, on_chunk)
        session.add(req)
        session.socket_action
        nil
      else
        _blocking(url) { |s| _build_request(s, method, url, body, opts, on_chunk) }
      end
    end

    # Blocking front shared by every synchronous operation: pick the shared
    # session — or a throwaway one when it's mid-flight because we were
    # called from inside one of its callbacks — let the block configure the
    # request on it, then drive to completion.
    def _blocking(url)
      session = shared
      session = open if session._busy?
      req, state = yield session
      _drive_sync(session, url, req, state)
    end

    # Verb-agnostic blocking drive shared by the HTTP verbs, SMTP delivery and
    # the IMAP verbs.
    # Attaches `req` to `session`'s reused blocking SyncDriver, pumps it until the
    # request completes, and wraps the outcome in a URL::Response. The caller
    # supplies a fully configured Request and its TransferState; this only owns
    # the add/run/remove lifecycle and the busy flag, so HTTP and SMTP share
    # exactly the same hybrid shared/fresh-session machinery.
    def _drive_sync(session, url, req, state)
      driver = session._sync_driver

      session.add(req)
      session._busy = true

      begin
        driver.run_until(req) do |r, code|
          state.error_code = code if r.equal?(req) && code != 0
        end
        _response_from(url, req, state)
      ensure
        session._busy = false
        session.remove(req) rescue nil
      end
    end

    # Drive registered entries concurrently on one session, yielding
    # (entry, response) the moment each transfer finishes. Reuses the shared
    # session (so the connection pool, TLS sessions and HTTP/2 multiplexing
    # carry over) unless it's mid-callback, in which case a throwaway one is
    # used — the same hybrid rule the blocking verbs follow. Each entry's
    # `build` proc configures a [Request, TransferState] pair on the session
    # (any of the _build_* helpers, so every protocol rides the same drive);
    # `post`, when set, rewraps the finished Response (MQTT subscribe). Like
    # the verbs, a runtime failure is a Response whose resp.error is set —
    # never a raise.
    def _drive_parallel(entries)
      session = shared
      session = open if session._busy?

      by_req = {}
      entries.each do |e|
        req, state = e[:build].call(session)
        by_req[req.object_id] = [e, req, state]
        session.add(req)
      end

      session._busy = true
      begin
        session._sync_driver.run_n(entries.size) do |req, code|
          entry, r, state = by_req[req.object_id]
          next unless entry
          state.error_code = code if code != 0
          resp = _response_from(entry[:url], r, state)
          resp = entry[:post].call(resp) if entry[:post]
          yield entry, resp
        end
      ensure
        session._busy = false
        by_req.each_value { |(_e, r, _s)| session.remove(r) rescue nil }
      end
      nil
    end

    def _build_request(session, method, url, body, opts, on_chunk)
      params    = opts.delete(:params)
      json_body = opts.delete(:json)
      form_body = opts.delete(:form)
      auth      = opts.delete(:auth)
      bearer    = opts.delete(:bearer)
      user_hdrs = opts.delete(:headers)
      multipart = opts.delete(:multipart)

      auto_hdrs = {}

      if json_body
        body = JSON.dump(json_body)
        auto_hdrs["Content-Type"] = "application/json"
        auto_hdrs["Accept"]       = "application/json"
      elsif form_body
        body = _encode_kv(form_body)
        auto_hdrs["Content-Type"] = "application/x-www-form-urlencoded"
      end

      auto_hdrs["Authorization"] = "Bearer #{bearer}" if bearer

      opts[:timeout]         = DEFAULT_TIMEOUT         unless opts.key?(:timeout)
      opts[:follow_location] = DEFAULT_FOLLOW_LOCATION unless opts.key?(:follow_location)
      opts[:user_agent]      = DEFAULT_USER_AGENT       unless opts.key?(:user_agent)

      if auth
        user, pass = auth.is_a?(Array) ? auth : auth.to_s.split(":", 2)
        opts[:userpwd] = "#{user}:#{pass}"
      end

      url_str = _stringify_url(url, params)
      req     = URL::Request.new(session, url_str)

      case method
      when :GET    then # nothing
      when :HEAD   then req.setopt(:nobody, true)
      else              req.setopt(:custom_request, method.to_s)
      end

      req.setopt(:post_fields, body) if body
      _apply_multipart(req, multipart) if multipart
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
        req.on_data { |chunk| state.body << chunk }
      end
      req.on_header { |line| state.raw_headers << line }

      [req, state]
    end

    # Build the URL::Request for an SMTP/SMTPS send. The envelope (MAIL FROM /
    # RCPT TO) and the upload toggle go through the flat setopt primitives; the
    # message body is streamed through the read callback, chunked entirely in
    # Ruby (String#byteslice + a tracked offset), never relying on C to slice.
    def _build_mail_request(session, server_url, from, recipients, body, opts)
      opts[:timeout] = DEFAULT_TIMEOUT unless opts.key?(:timeout)

      url_str = _stringify_url(server_url, nil)
      req     = URL::Request.new(session, url_str)

      _, reader = _upload_reader(body)
      req.setopt(:upload, true)
      req.setopt(:mail_from, from.to_s)
      req.setopt(:mail_rcpt, recipients.map(&:to_s))
      _apply_opts(req, opts)

      req.on_read(&reader)

      state = URL::TransferState.new
      req.on_data   { |chunk| state.body << chunk }
      req.on_header { |line|  state.raw_headers << line }

      [req, state]
    end

    # Build a URL::Request for an IMAP/IMAPS command. The mailbox is the URL
    # path (imaps://host/INBOX); `command`, when given, is handed to libcurl as
    # CURLOPT_CUSTOMREQUEST and runs after curl's own LOGIN/SELECT — exactly the
    # `curl -X '<command>'` flow. `url_suffix` lets a verb append IMAP URL parts
    # (e.g. ";UID=<n>") so a plain transfer fetches a message via the write
    # callback. on_chunk, when supplied, streams the body instead of buffering.
    def _build_imap_request(session, mailbox_url, command, opts, url_suffix = nil, on_chunk = nil)
      opts[:timeout] = DEFAULT_TIMEOUT unless opts.key?(:timeout)

      url_str = _stringify_url(mailbox_url, nil)
      url_str = "#{url_str}#{url_suffix}" if url_suffix
      req     = URL::Request.new(session, url_str)

      req.setopt(:custom_request, command) if command
      _apply_opts(req, opts)

      state = URL::TransferState.new
      if on_chunk
        req.on_data { |chunk| on_chunk.call(chunk) }
      else
        req.on_data { |chunk| state.body << chunk }
      end
      req.on_header { |line| state.raw_headers << line }

      [req, state]
    end

    # Blocking SMTP/SMTPS delivery.
    def _deliver(server_url, from, recipients, body, opts)
      _blocking(server_url) { |s| _build_mail_request(s, server_url, from, recipients, body, opts) }
    end

    # Shared front of an IMAP verb: pick the shared session (or a fresh one when
    # re-entrant), build the request, drive it. Centralises the session choice
    # so each verb arm is a one-liner that just names its IMAP command. A NO/BAD
    # reply is a runtime error like any other — it comes back as a Response whose
    # error_code is non-zero (so resp.error holds a URL::TransportError), not as
    # a raise.
    def _imap(mailbox_url, command, opts, url_suffix = nil, on_chunk = nil)
      _blocking(mailbox_url) { |s| _build_imap_request(s, mailbox_url, command, opts, url_suffix, on_chunk) }
    end

    # Open a WebSocket: build a CONNECT_ONLY=2 request and run the upgrade
    # handshake, which leaves the live socket on the easy handle for the
    # framing primitives — libcurl's documented ws flow. A failed handshake is
    # a value on the returned socket (ws.error / ws.open?), never a raise —
    # the HTTP verbs' two-tier model.
    #
    # Blocking mode drives the handshake with curl_easy_perform, so the handle
    # is standalone and nothing has to detach it. With URL.default_loop set
    # the handshake rides the loop instead: the request goes onto a fresh
    # session attached to the loop, the socket comes back immediately in the
    # :connecting state, and the session's reap fires Request#on_complete →
    # ws._handshake_done. The easy stays attached to that multi for the
    # socket's lifetime (detaching a CONNECT_ONLY easy severs its connection);
    # the ws watches its own fd and detaches at teardown.
    def _open_websocket(url, opts)
      opts = opts.dup
      opts[:timeout] = DEFAULT_TIMEOUT unless opts.key?(:timeout)
      user_hdrs = opts.delete(:headers)
      params    = opts.delete(:params)

      url_str = _stringify_url(url, params)
      session = @default_loop ? open : shared
      req     = URL::Request.new(session, url_str)
      req.setopt(:connect_only, 2)   # 2 = WebSocket: curl runs the upgrade, then hands back
      _apply_opts(req, opts)
      req.headers = user_hdrs if user_hdrs && !user_hdrs.empty?

      if @default_loop
        session.event_loop = @default_loop
        ws = URL::WebSocket.new(req, 0, event_loop: @default_loop)
        ws._bind_connect_session(session)
        req.on_complete(detach: false) { |code| ws._handshake_done(code) }
        session.add(req)
        session.socket_action   # kick off: registers fds/timers with the loop
        ws
      else
        code = URL::Libcurl.easy_perform(req.handle)
        URL::WebSocket.new(req, code)
      end
    end

    # ----------------------------------------------------------------------
    #  Generic transfer core (the non-HTTP protocols ride this)
    # ----------------------------------------------------------------------

    # Run a plain transfer for any supported scheme and return a URL::Response.
    # `on_chunk` streams the body instead of buffering; `upload_data`, when set,
    # turns it into an upload driven by the read callback. Reuses the same
    # shared/throwaway session + SyncDriver drive as the HTTP verbs, so all
    # protocols share one code path.
    def _run_transfer(url, opts, on_chunk, upload_data)
      _blocking(url) { |s| _build_transfer(s, url, opts, on_chunk, upload_data) }
    end

    def _build_transfer(session, url, opts, on_chunk, upload_data)
      opts = opts.dup
      opts[:timeout] = DEFAULT_TIMEOUT unless opts.key?(:timeout)
      user_hdrs = opts.delete(:headers)
      params    = opts.delete(:params)

      url_str = params ? _stringify_url(url, params) : url.to_s
      req     = URL::Request.new(session, url_str)

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
        req.on_data { |c| state.body << c }
      end
      req.on_header { |l| state.raw_headers << l }

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
      h = req.handle
      URL::Response.new(
        url:           url,
        effective_url: URL::Libcurl.easy_getinfo(h, :effective_url),
        code:          URL::Libcurl.easy_getinfo(h, :response_code),
        body:          state.body,
        raw_headers:   state.raw_headers,
        total_time:    URL::Libcurl.easy_getinfo(h, :total_time),
        content_type:  URL::Libcurl.easy_getinfo(h, :content_type),
        error_code:    state.error_code,
        retry_after:   URL::Libcurl.easy_getinfo(h, :retry_after),
      )
    end

    # Seconds → milliseconds for the Ruby-side waits, the same contract
    # mrb_chrono_convert enforces for setopt(:timeout) in C: a duration is a
    # seconds-denominated Numeric (mruby-chrono's 30.s / 500.ms literals are
    # exactly that), so anything else is rejected up front instead of being
    # silently to_f'd.
    def _duration_ms(value)
      unless value.is_a?(Numeric)
        raise TypeError, "expected a duration/seconds (Numeric), got #{value.class}"
      end
      (value.to_f * 1000).round
    end

    # Block for `seconds` using libcurl's own wait (curl_multi_poll on an
    # idle session — it sleeps the full timeout even with nothing attached,
    # portably, Windows included; IO.select can't do that there). Used
    # between retry rounds on the blocking paths only; event-loop
    # integrations never reach this. A nil/zero wait is a no-op.
    def _wait(seconds)
      return nil if seconds.nil?
      ms = _duration_ms(seconds)
      return nil if ms <= 0
      session = shared
      session = open if session._busy?
      session.poll(ms)
      nil
    end

    # Guard that the embedded libcurl was built with the URL's scheme. Called by
    # the RFC-verb arms after they've matched a scheme they implement, so an
    # unbuilt protocol (e.g. imaps on a libcurl without it) raises a clear error
    # before any connection attempt.
    def _require_protocol!(url)
      scheme = _scheme_of(url)
      return if supports?(scheme)
      raise URL::ProtocolNotAvailable.new(scheme, PROTOS)
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

    # Apply user-supplied curl options to the request. Two ways in, both ending
    # at the same flat setopt pass-through:
    #   * top-level keys (timeout:, verbose:, …) — the curated, named options.
    #   * setopt: { … } — an explicit escape hatch to forward any libcurl option
    #     verbatim, for the long tail we don't surface by name. Its pairs are
    #     merged last so an explicit setopt wins over a named one.
    # Only :netrc needs massaging — its friendly value is mapped to libcurl's
    # enum here so the C setopt stays a flat int pass-through; everything else is
    # verbatim.
    def _apply_opts(req, opts)
      raw = opts.delete(:setopt)
      opts.each do |k, v|
        v = _netrc_level(v) if k == :netrc
        req.setopt(k, v)
      end
      if raw
        raw.each do |k, v|
          v = _netrc_level(v) if k == :netrc
          req.setopt(k, v)
        end
      end
    end

    # Build a multipart/form-data body from a Hash and attach it as the request
    # body (CURLOPT_MIMEPOST). The mime *tree* has to be assembled through the
    # libcurl handles, but which parts/names/files to add is decided here in
    # Ruby; the C side only exposes the thin curl_mime_* primitives.
    #
    #   multipart: {
    #     "field"  => "plain value",
    #     "avatar" => { file: "/path/pic.png", type: "image/png" },
    #     "note"   => { data: bytes, filename: "n.txt", type: "text/plain" },
    #   }
    #
    # A String value is a plain field; a Hash value is a file/blob part —
    # `file:` streams from disk (libcurl reads it, never buffered in Ruby),
    # `data:` is an in-memory blob, and `filename:`/`type:` set the part headers.
    def _apply_multipart(req, parts)
      mime = URL::Libcurl.mime_new(req.handle)
      parts.each do |name, v|
        part = URL::Libcurl.mime_addpart(mime)
        URL::Libcurl.mime_name(part, name.to_s)
        if v.is_a?(Hash)
          if v[:file]
            URL::Libcurl.mime_filedata(part, v[:file].to_s)
          else
            URL::Libcurl.mime_data(part, (v[:data] || "").to_s)
          end
          URL::Libcurl.mime_filename(part, v[:filename].to_s) if v[:filename]
          URL::Libcurl.mime_type(part, v[:type].to_s)         if v[:type]
        else
          URL::Libcurl.mime_data(part, v.to_s)
        end
      end
      req.setopt(:mimepost, mime)
      # No rooting needed here: mime_new already pins the mime to its easy under
      # a hidden (non-'@') ivar the GC traces but Ruby can't reach — so the mime
      # outlives the transfer and can't be freed out from under libcurl.
      req
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
  # verbs notice a re-entrant call (a URL("https://x").get from inside a callback): the
  # session can't drive a second transfer, so a throwaway one is used for
  # that nested fetch instead.
  def _busy?
    @running ? true : false
  end

  def _busy=(flag)
    @running = flag
    flag
  end

  # The blocking SyncDriver bound to this session, created once and reused
  # across calls. It drives via curl_multi_perform/poll, so no event loop is
  # attached on the blocking paths at all.
  def _sync_driver
    @sync_driver ||= SyncDriver.new(self)
  end

  # --- executors ------------------------------------------------------------
  #
  # The scheme-typed endpoint classes (mrblib/url/endpoints.rb) don't run
  # their verbs directly — they hand the operation to an executor. SyncExec is
  # the default and runs it immediately (today's blocking/async behaviour);
  # URL::BatchExec (mrblib/url.rb) registers it for the next
  # URL.parallel_perform instead. Same verb code, two execution modes.

  # Each method hands the _build_* helpers a dup of opts (they strip keys as
  # they consume them) and stamps the Response with a proc that re-invokes the
  # same method — that's what Response#retry calls on a blocking verb's failed
  # Response, re-running up to its `times` budget and stopping early on
  # success. The stamp recurses naturally: a retried Response is stamped too.
  module SyncExec
    class << self
      def fire(method, url, body, opts, &on_chunk)
        resp = URL._fire(method, url, body, opts.dup, &on_chunk)
        _stamp(resp) { fire(method, url, body, opts, &on_chunk) }
      end

      def transfer(url, opts, on_chunk, upload_data, post = nil)
        resp = URL._run_transfer(url, opts.dup, on_chunk, upload_data)
        resp = post.call(resp) if post
        _stamp(resp) { transfer(url, opts, on_chunk, upload_data, post) }
      end

      def imap(mailbox_url, command, opts, url_suffix = nil, on_chunk = nil)
        resp = URL._imap(mailbox_url, command, opts.dup, url_suffix, on_chunk)
        _stamp(resp) { imap(mailbox_url, command, opts, url_suffix, on_chunk) }
      end

      def deliver(server_url, from, recipients, body, opts)
        resp = URL._deliver(server_url, from, recipients, body, opts.dup)
        _stamp(resp) { deliver(server_url, from, recipients, body, opts) }
      end

      def websocket(url, opts)
        URL._open_websocket(url, opts)
      end

      private

      # Blocking retry: redo the request up to `times` times, stop on the
      # first success, hand back the last Response. Before each re-run, wait
      # the explicit `wait`, or the seconds the server asked for in the failed
      # response's Retry-After header, or nothing.
      def _stamp(resp, &redo_request)
        if resp.is_a?(URL::Response)
          resp._retry_with(lambda { |times, wait|
            fresh = resp
            times.times do
              URL._wait(wait || fresh.retry_after || 0)
              fresh = redo_request.call
              break unless fresh.error
            end
            fresh
          })
        end
        resp
      end
    end
  end
end
