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
    # Call loop.run_once until `condition` holds — the one wait in the gem.
    # Every blocking verb, parallel batch, websocket send/receive and retry
    # pause boils down to this: register with a loop, then drive it. While
    # this call waits, every other transfer and open websocket registered on
    # the SAME loop keeps progressing too, since a shared loop's run_once
    # services all of them together, not just the caller's own registration.
    def _drive_until(loop)
      loop.run_once until yield
      nil
    end

    # Drive `entries` (each a { url:, build:, post: } — `build` configures a
    # [Request, TransferState] pair on the session it's given) on `session`
    # through `loop`, yielding (entry, response) the moment each finishes.
    # One method for every shape of drive: a single blocking verb, a
    # `.parallel` batch on the shared session, and the in-C-callback
    # fallback on a throwaway session all just call this with a different
    # session/loop. A runtime failure is a Response whose resp.error is set
    # — never a raise; only a handler itself raising unwinds out of here,
    # which the ensure below turns into "unregister whatever hadn't finished
    # yet" so nothing is left dangling on the session.
    def _drive_entries(entries, session, loop)
      remaining = entries.size
      reqs      = []
      begin
        entries.each do |e|
          req, state = e[:build].call(session)
          reqs << req
          session.add(req) do |code|
            remaining -= 1
            yield e, _finish_response(e[:url], req, state, code, e[:post])
          end
        end
        _drive_until(loop) { remaining <= 0 }
      ensure
        reqs.each { |r| session.remove(r) }   # no-op for ones already reaped
      end
      nil
    end

    # Blocking front shared by every synchronous operation: let the block
    # configure the request, then drive it to completion on URL.default_loop
    # — while this call waits, every other registered transfer and open
    # websocket keeps progressing, because they're driven by the exact same
    # loop. The one place that can't do this is a call made from inside a
    # C-invoked libcurl callback (a user's streaming block runs under
    # multi_socket_action, and a multi must never be re-entered from its own
    # callback — no event loop, built-in or a real platform one, can get
    # around that): that call transparently runs on a throwaway session and
    # a throwaway loop of its own instead — same observable behaviour as
    # ever, and it can never collide with whatever's mid-callback because it
    # shares no state with it.
    def _blocking(url, &build)
      entry = { url: url, build: build, post: nil }
      resp  = nil
      session = _in_c? ? open : shared
      session.event_loop = IOSelectLoop.new if _in_c?
      _drive_entries([entry], session, session.event_loop) { |_e, r| resp = r }
      resp
    end

    # Verb-agnostic single-request drive: given an already-configured
    # [req, state] pair on `session`, run it to completion and wrap the
    # result. _blocking builds and drives in one step via _build_*/_drive_entries;
    # this is the same drive for a request some other caller already built.
    def _drive_sync(session, url, req, state)
      loop = session.event_loop
      code = nil
      session.add(req) { |c| code = c }
      begin
        _drive_until(loop) { !code.nil? }
      ensure
        session.remove(req)   # no-op once reaped normally
      end
      _finish_response(url, req, state, code)
    end

    # Stamp the CURLcode onto the transfer state and wrap the finished request
    # in a Response; `post`, when given, rewraps it (MQTT subscribe). The one
    # completion shape every drive path funnels through.
    def _finish_response(url, req, state, code, post = nil)
      state.error_code = code if code != 0
      resp = _response_from(url, req, state)
      post ? post.call(resp) : resp
    end

    # `.parallel`/`URL.parallel_perform`: drive every registered entry on the
    # shared session (so the connection pool, TLS sessions and HTTP/2
    # multiplexing carry over) concurrently. A handler may itself call
    # blocking verbs — that's a plain nested call to _drive_entries/_blocking
    # on the same loop, one level deeper, ordinary Ruby recursion.
    def _drive_parallel(entries)
      session = _in_c? ? open : shared
      session.event_loop = IOSelectLoop.new if _in_c?
      _drive_entries(entries, session, session.event_loop) { |e, resp| yield e, resp }
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

    # Shared front of an IMAP verb: build the request and drive it through
    # _blocking, so each verb arm is a one-liner that just names its IMAP
    # command. A NO/BAD reply is a runtime error like any other — it comes
    # back as a Response whose error_code is non-zero (so resp.error holds a
    # URL::TransportError), not as a raise.
    def _imap(mailbox_url, command, opts, url_suffix = nil, on_chunk = nil)
      _blocking(mailbox_url) { |s| _build_imap_request(s, mailbox_url, command, opts, url_suffix, on_chunk) }
    end

    # Open a WebSocket: build a CONNECT_ONLY=2 request and drive the upgrade
    # handshake through the multi like any other transfer — libcurl marks a
    # connect-only transfer done the moment the upgrade completes, leaving the
    # live socket on the easy handle for the framing primitives. Driving it
    # through URL.default_loop means the handshake no longer freezes the VM:
    # everything else in flight keeps progressing while it runs. A failed
    # handshake is a value on the returned socket (ws.error / ws.open?),
    # never a raise — the HTTP verbs' two-tier model.
    def _open_websocket(url, opts)
      opts = opts.dup
      opts[:timeout] = DEFAULT_TIMEOUT unless opts.key?(:timeout)
      user_hdrs = opts.delete(:headers)
      params    = opts.delete(:params)

      if _in_c?
        session = open
        session.event_loop = IOSelectLoop.new
      else
        session = shared
      end
      loop = session.event_loop

      url_str = _stringify_url(url, params)
      req     = URL::Request.new(session, url_str)
      req.setopt(:connect_only, 2)   # 2 = WebSocket: curl runs the upgrade, then hands back
      _apply_opts(req, opts)
      req.headers = user_hdrs if user_hdrs && !user_hdrs.empty?

      # The easy must STAY in the multi while the socket lives — removing a
      # completed CONNECT_ONLY easy drops its connection (activesocket goes
      # dead) — so it's added with remove_on_done: false. URL::WebSocket
      # detaches it itself (session.remove) when the socket closes; a failed
      # handshake, or an exception aborting the drive itself, detaches right
      # here.
      code = nil
      session.add(req, remove_on_done: false) { |c| code = c }
      begin
        _drive_until(loop) { !code.nil? }
      ensure
        session.remove(req) if code.nil?
      end

      ws = URL::WebSocket.new(req, code, session)
      session.remove(req) unless ws.open?
      ws
    end

    # ----------------------------------------------------------------------
    #  Generic transfer core (the non-HTTP protocols ride this)
    # ----------------------------------------------------------------------

    # Run a plain transfer for any supported scheme and return a URL::Response.
    # `on_chunk` streams the body instead of buffering; `upload_data`, when set,
    # turns it into an upload driven by the read callback. Reuses the same
    # _blocking drive as the HTTP verbs, so all protocols share one code path.
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

    # Pause for `duration` (chrono seconds: 500.ms, 2.s, …) between retry
    # rounds — by arming a timer on a loop and driving it, so every other
    # transfer and open websocket registered on that same loop keeps
    # progressing while this caller waits. Inside a C callback no multi may
    # be touched, so a private throwaway loop just sleeps (nothing else can
    # be serviced there anyway). A nil/zero wait is a no-op.
    def _wait(duration)
      return nil if duration.nil? || duration.to_f <= 0
      loop = _in_c? ? IOSelectLoop.new : default_loop
      done = false
      loop.arm_timer(duration) { done = true }
      _drive_until(loop) { done }
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
        dup_opts = opts.dup
        resp = URL._blocking(url) { |s| URL._build_request(s, method, url, body, dup_opts, on_chunk) }
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
