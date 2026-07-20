# mrblib/url/endpoints.rb
#
# Scheme-typed object API. `URL("https://host/path")` returns the right
# per-protocol class — URL::HTTPS, URL::FTP, URL::SFTP, URL::IMAP, … Protocols
# that share an operation shape share a parent they subclass off of:
#
#   URL::Transfer  (download/upload/list)  <- FTP FTPS SFTP SCP FILE TFTP TELNET
#   URL::HTTP      (get/post/…)            <- HTTPS
#   URL::GOPHER / DICT / IMAP / POP3 / SMTP / LDAP / MQTT / RTSP / WS
#                  each its own family, with the TLS variant subclassing it.
#
# A per-protocol class exists ONLY when this libcurl was built with that
# protocol (gated on URL.supports?) — mirroring libcurl, where an unbuilt
# scheme has no handler at all. So URL::SFTP simply doesn't exist without an
# SSH backend; referencing it is a NameError, and URL("sftp://…") raises from
# URL(uri). URL::Transfer is the one always-defined abstract base (the ftp/ssh
# /file family has no single primary scheme); the parents that *are* their own
# primary protocol (HTTP, IMAP, …) are gated like any other.
#
# Each verb hands its operation to an executor (@exec) instead of calling the
# engine helpers in dispatch.rb directly. URL::SyncExec — the default — runs
# it immediately (via _fire, _run_transfer, _imap, _deliver,
# _open_websocket); URL::BatchExec registers the same operation for the
# next URL.parallel_perform, which is what SchemeKwargs#parallel builds its
# queueing copy with. Plain Ruby — no define_singleton_method, no
# method_missing.
#
# Kwargs are owned per scheme. Each class lists in KWARGS the *high-level*
# convenience kwargs it handles; _ck rejects a high-level kwarg owned by another
# scheme up front. Raw curl options are not high-level kwargs — pass them as
# top-level keys (validated by setopt) or, explicitly, via `setopt: { … }`.

class URL
  HIGH_LEVEL_KWARGS = %i[params json form multipart auth bearer headers].freeze

  def self._reject_foreign_kwargs!(opts, allowed, where)
    foreign = opts.keys & (HIGH_LEVEL_KWARGS - allowed)
    return opts if foreign.empty?
    raise ArgumentError,
          "#{where} does not accept #{foreign.map(&:inspect).join(', ')} — " \
          "that option belongs to another scheme"
  end

  module SchemeKwargs
    # Register this URL's `verb` for the next URL.parallel_perform instead of
    # running it now. Takes the verb's normal arguments and kwargs; the block
    # is called with the resolved URL::Response once the transfer completes
    # during parallel_perform (it is NOT the sync verbs' streaming block —
    # inside a batch the body is buffered into the Response). Argument errors
    # raise here, at registration, before any I/O; the transfer itself starts
    # only inside URL.parallel_perform. Returns self, so several
    # registrations on one URL can chain.
    #
    #   URL("ftp://h/a.txt").parallel(:download) { |resp| save(resp.body) }
    #   URL("https://h/b").parallel(:get)        { |resp| use(resp.json) }
    #   URL.parallel_perform
    def parallel(verb, *args, **opts, &on_response)
      if verb == :parallel || !respond_to?(verb)
        raise ArgumentError, "#{self.class} has no verb #{verb.inspect}"
      end
      queued = self.class.new(@uri, URL::BatchExec.new(URL._pending, on_response))
      if opts.empty?
        queued.__send__(verb, *args)
      else
        queued.__send__(verb, *args, **opts)
      end
      self
    end

    private

    def _ck(opts)
      URL._reject_foreign_kwargs!(opts, self.class::KWARGS, self.class)
    end
  end

  # ---- HTTP(S) -----------------------------------------------------------
  if supports?("http")
    class HTTP
      include URL::SchemeKwargs
      KWARGS = %i[params json form multipart auth bearer headers].freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def get(**o, &b);                @exec.fire(:GET,     @uri, nil,  _ck(o), &b); end
      def head(**o, &b);               @exec.fire(:HEAD,    @uri, nil,  _ck(o), &b); end
      def options(**o, &b);            @exec.fire(:OPTIONS, @uri, nil,  _ck(o), &b); end
      def delete(body = nil, **o, &b); @exec.fire(:DELETE,  @uri, body, _ck(o), &b); end
      def post(body = nil, **o, &b);   @exec.fire(:POST,    @uri, body, _ck(o), &b); end
      def put(body = nil, **o, &b);    @exec.fire(:PUT,     @uri, body, _ck(o), &b); end
      def patch(body = nil, **o, &b);  @exec.fire(:PATCH,   @uri, body, _ck(o), &b); end

      def self.get(uri, **o, &b);                 new(uri).get(**o, &b); end
      def self.head(uri, **o, &b);                new(uri).head(**o, &b); end
      def self.options(uri, **o, &b);             new(uri).options(**o, &b); end
      def self.delete(uri, body = nil, **o, &b);  new(uri).delete(body, **o, &b); end
      def self.post(uri, body = nil, **o, &b);    new(uri).post(body, **o, &b); end
      def self.put(uri, body = nil, **o, &b);     new(uri).put(body, **o, &b); end
      def self.patch(uri, body = nil, **o, &b);   new(uri).patch(body, **o, &b); end
      def self.parallel(uri, verb, *a, **o, &b);  new(uri).parallel(verb, *a, **o, &b); end
    end
    class HTTPS < HTTP; end if supports?("https")
  end

  # ---- file / ftp(s) / sftp / scp / tftp / telnet -----------------------
  # Transfer is the always-defined abstract base; the concrete protocols below
  # subclass it and exist only when built.
  class Transfer
    include URL::SchemeKwargs
    KWARGS = %i[params headers].freeze

    def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

    def download(**o, &b)
      @exec.transfer(@uri, _ck(o), b, nil)
    end
    def upload(data, **o)
      @exec.transfer(@uri, _ck(o), nil, data)
    end
    def list(**o)
      @exec.transfer(@uri, _ck(o).merge(dirlistonly: true), nil, nil)
    end

    def self.download(uri, **o, &b); new(uri).download(**o, &b); end
    def self.upload(uri, data, **o); new(uri).upload(data, **o); end
    def self.list(uri, **o);         new(uri).list(**o); end
    def self.parallel(uri, verb, *a, **o, &b); new(uri).parallel(verb, *a, **o, &b); end
  end
  class FTP    < Transfer; end if supports?("ftp")
  class FTPS   < Transfer; end if supports?("ftps")
  class SFTP   < Transfer; end if supports?("sftp")
  class SCP    < Transfer; end if supports?("scp")
  class FILE   < Transfer; end if supports?("file")
  class TFTP   < Transfer; end if supports?("tftp")
  class TELNET < Transfer; end if supports?("telnet")

  # ---- gopher(s) --------------------------------------------------------
  if supports?("gopher")
    class GOPHER
      include URL::SchemeKwargs
      KWARGS = %i[params headers].freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def get(**o, &b)
        @exec.transfer(@uri, _ck(o), b, nil)
      end
      alias download get

      def self.get(uri, **o, &b);      new(uri).get(**o, &b); end
      def self.download(uri, **o, &b); new(uri).download(**o, &b); end
      def self.parallel(uri, verb, *a, **o, &b); new(uri).parallel(verb, *a, **o, &b); end
    end
    class GOPHERS < GOPHER; end if supports?("gophers")
  end

  # ---- dict -------------------------------------------------------------
  if supports?("dict")
    class DICT
      include URL::SchemeKwargs
      KWARGS = %i[params headers].freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def define(word, database: "!", **o)
        base = @uri
        base = base[0..-2] while base.end_with?("/")
        @exec.transfer("#{base}/d:#{word}:#{database}", _ck(o), nil, nil)
      end

      def self.define(uri, word, database: "!", **o); new(uri).define(word, database: database, **o); end
      def self.parallel(uri, verb, *a, **o, &b);       new(uri).parallel(verb, *a, **o, &b); end
    end
  end

  # ---- imap(s) ----------------------------------------------------------
  if supports?("imap")
    class IMAP
      include URL::SchemeKwargs
      KWARGS = [].freeze   # mailbox/uid/flags are explicit verb args

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def fetch(uid:, **o, &b)
        @exec.imap(@uri, nil, _ck(o), ";UID=#{uid}", b)
      end
      def move(uid:, to:, **o)
        @exec.imap(@uri, "UID MOVE #{uid} #{to}", _ck(o))
      end
      def store(uid:, flags:, op: "+", **o)
        @exec.imap(@uri, "UID STORE #{uid} #{op}FLAGS (#{flags})", _ck(o))
      end
      def expunge(**o)
        @exec.imap(@uri, "EXPUNGE", _ck(o))
      end
      # UID SEARCH — curl's own recommended way to list a mailbox's messages
      # by persistent UID (its docs note the plain "?CRITERIA" URL-query form
      # returns transient sequence numbers instead). criteria is any IMAP
      # SEARCH key — "ALL" (default), "UNSEEN", "SUBJECT foo", etc. The
      # response body is the raw "* SEARCH 1 2 3" untagged line; parsing it
      # into UIDs is the caller's job, same as every other IMAP verb here
      # hands back an unparsed protocol response.
      def search(criteria = "ALL", **o)
        @exec.imap(@uri, "UID SEARCH #{criteria}", _ck(o))
      end

      def self.fetch(uri, uid:, **o, &b);              new(uri).fetch(uid: uid, **o, &b); end
      def self.move(uri, uid:, to:, **o);              new(uri).move(uid: uid, to: to, **o); end
      def self.store(uri, uid:, flags:, op: "+", **o); new(uri).store(uid: uid, flags: flags, op: op, **o); end
      def self.expunge(uri, **o);                      new(uri).expunge(**o); end
      def self.search(uri, criteria = "ALL", **o);     new(uri).search(criteria, **o); end
      def self.parallel(uri, verb, *a, **o, &b);       new(uri).parallel(verb, *a, **o, &b); end
    end
    class IMAPS < IMAP; end if supports?("imaps")
  end

  # ---- pop3(s) ----------------------------------------------------------
  if supports?("pop3")
    class POP3
      include URL::SchemeKwargs
      KWARGS = %i[params headers].freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def list(**o)
        @exec.transfer(@uri, _ck(o).merge(dirlistonly: true), nil, nil)
      end
      def fetch(n = nil, **o, &b)
        target = @uri
        if n
          base = @uri
          base = base[0..-2] while base.end_with?("/")
          target = "#{base}/#{n}"
        end
        @exec.transfer(target, _ck(o), b, nil)
      end
      def download(n = nil, **o, &b); fetch(n, **o, &b); end

      def self.list(uri, **o);                  new(uri).list(**o); end
      def self.fetch(uri, n = nil, **o, &b);    new(uri).fetch(n, **o, &b); end
      def self.download(uri, n = nil, **o, &b); new(uri).download(n, **o, &b); end
      def self.parallel(uri, verb, *a, **o, &b); new(uri).parallel(verb, *a, **o, &b); end
    end
    class POP3S < POP3; end if supports?("pop3s")
  end

  # ---- smtp(s) ----------------------------------------------------------
  if supports?("smtp")
    class SMTP
      include URL::SchemeKwargs
      KWARGS = [].freeze   # from:/to:/body are explicit

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def deliver(body, from:, to:, **opts)
        _ck(opts)
        recipients = to.is_a?(Array) ? to : [to]
        @exec.deliver(@uri, from, recipients, body, opts)
      end

      def self.deliver(uri, body, from:, to:, **o); new(uri).deliver(body, from: from, to: to, **o); end
      def self.parallel(uri, verb, *a, **o, &b);    new(uri).parallel(verb, *a, **o, &b); end
    end
    class SMTPS < SMTP; end if supports?("smtps")
  end

  # ---- ldap(s) ----------------------------------------------------------
  if supports?("ldap")
    class LDAP
      include URL::SchemeKwargs
      KWARGS = %i[params headers].freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def search(**o)
        @exec.transfer(@uri, _ck(o), nil, nil)
      end

      def self.search(uri, **o); new(uri).search(**o); end
      def self.parallel(uri, verb, *a, **o, &b); new(uri).parallel(verb, *a, **o, &b); end
    end
    class LDAPS < LDAP; end if supports?("ldaps")
  end

  # ---- mqtt(s) ----------------------------------------------------------
  if supports?("mqtt")
    class MQTT
      include URL::SchemeKwargs
      KWARGS = %i[params headers].freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def publish(payload, **o)
        @exec.transfer(@uri, _ck(o).merge(post_fields: payload.to_s), nil, nil)
      end

      def subscribe(timeout: 5.0, **o)
        # The payload rewrap rides along as a post-processing step so it runs
        # after the transfer completes in both execution modes (sync and
        # parallel).
        uri  = @uri
        post = lambda do |resp|
          payload = URL._mqtt_payload(resp.body)
          ecode = (resp.error_code == 28 && payload && !payload.empty?) ? 0 : resp.error_code
          URL::Response.new(
            url: uri, effective_url: resp.effective_url, code: resp.code,
            body: payload || "", raw_headers: resp.raw_headers,
            total_time: resp.total_time, content_type: resp.content_type,
            error_code: ecode, retry_after: resp.retry_after
          )
        end
        @exec.transfer(@uri, _ck(o).merge(timeout: timeout), nil, nil, post)
      end

      def self.publish(uri, payload, **o);  new(uri).publish(payload, **o); end
      def self.subscribe(uri, **o);         new(uri).subscribe(**o); end
      def self.parallel(uri, verb, *a, **o, &b); new(uri).parallel(verb, *a, **o, &b); end
    end
    class MQTTS < MQTT; end if supports?("mqtts")
  end

  # ---- rtsp -------------------------------------------------------------
  if supports?("rtsp")
    class RTSP
      include URL::SchemeKwargs
      KWARGS = %i[params headers].freeze

      REQUESTS = {
        options: 1, describe: 2, announce: 3, setup: 4, play: 5, pause: 6,
        teardown: 7, get_parameter: 8, set_parameter: 9, record: 10, receive: 11,
      }.freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def options(transport: nil, stream_uri: nil, **o);         _request(:options,         transport, stream_uri, o); end
      def describe(transport: nil, stream_uri: nil, **o);        _request(:describe,        transport, stream_uri, o); end
      def setup(transport: nil, stream_uri: nil, **o);           _request(:setup,           transport, stream_uri, o); end
      def play(transport: nil, stream_uri: nil, **o);            _request(:play,            transport, stream_uri, o); end
      def pause(transport: nil, stream_uri: nil, **o);           _request(:pause,           transport, stream_uri, o); end
      def teardown(transport: nil, stream_uri: nil, **o);        _request(:teardown,        transport, stream_uri, o); end
      def get_parameter(transport: nil, stream_uri: nil, **o);   _request(:get_parameter,   transport, stream_uri, o); end
      def set_parameter(transport: nil, stream_uri: nil, **o);   _request(:set_parameter,   transport, stream_uri, o); end
      def announce(transport: nil, stream_uri: nil, **o);        _request(:announce,        transport, stream_uri, o); end
      def record(transport: nil, stream_uri: nil, **o);          _request(:record,          transport, stream_uri, o); end

      def self.options(uri, **o);        new(uri).options(**o); end
      def self.describe(uri, **o);       new(uri).describe(**o); end
      def self.setup(uri, **o);          new(uri).setup(**o); end
      def self.play(uri, **o);           new(uri).play(**o); end
      def self.pause(uri, **o);          new(uri).pause(**o); end
      def self.teardown(uri, **o);       new(uri).teardown(**o); end
      def self.get_parameter(uri, **o);  new(uri).get_parameter(**o); end
      def self.set_parameter(uri, **o);  new(uri).set_parameter(**o); end
      def self.announce(uri, **o);       new(uri).announce(**o); end
      def self.record(uri, **o);         new(uri).record(**o); end
      def self.parallel(uri, verb, *a, **o, &b); new(uri).parallel(verb, *a, **o, &b); end

      private

      def _request(verb, transport, stream_uri, opts)
        enum = REQUESTS[verb] or raise URL::UnknownRTSPRequest.new(verb, REQUESTS.keys)
        opts = _ck(opts).merge(rtsp_request: enum)
        opts[:rtsp_stream_uri] = stream_uri if stream_uri
        opts[:rtsp_transport]  = transport  if transport
        @exec.transfer(@uri, opts, nil, nil)
      end
    end
  end

  # ---- ws(s) ------------------------------------------------------------
  if supports?("ws")
    class WS
      include URL::SchemeKwargs
      KWARGS = %i[params headers].freeze

      def initialize(uri, exec = URL::SyncExec); @uri = uri.to_s; @exec = exec; URL._require_protocol!(@uri); end

      def connect(**opts, &block)
        ws = @exec.websocket(@uri, _ck(opts))
        if block && ws.open?
          begin
            block.call(ws)
          ensure
            ws.close
          end
        end
        ws
      end

      def self.connect(uri, **o, &b); new(uri).connect(**o, &b); end
    end
    class WSS < WS; end if supports?("wss")
  end

  # scheme -> per-protocol class, built from only the schemes this libcurl has.
  # Referencing a class is safe here because each key is guarded by the same
  # supports? that gated the class's definition.
  m = {}
  m["http"]    = HTTP    if supports?("http")
  m["https"]   = HTTPS   if supports?("https")
  m["ftp"]     = FTP     if supports?("ftp")
  m["ftps"]    = FTPS    if supports?("ftps")
  m["sftp"]    = SFTP    if supports?("sftp")
  m["scp"]     = SCP     if supports?("scp")
  m["file"]    = FILE    if supports?("file")
  m["tftp"]    = TFTP    if supports?("tftp")
  m["telnet"]  = TELNET  if supports?("telnet")
  m["gopher"]  = GOPHER  if supports?("gopher")
  m["gophers"] = GOPHERS if supports?("gophers")
  m["dict"]    = DICT    if supports?("dict")
  m["imap"]    = IMAP    if supports?("imap")
  m["imaps"]   = IMAPS   if supports?("imaps")
  m["pop3"]    = POP3    if supports?("pop3")
  m["pop3s"]   = POP3S   if supports?("pop3s")
  m["smtp"]    = SMTP    if supports?("smtp")
  m["smtps"]   = SMTPS   if supports?("smtps")
  m["ldap"]    = LDAP    if supports?("ldap")
  m["ldaps"]   = LDAPS   if supports?("ldaps")
  m["mqtt"]    = MQTT    if supports?("mqtt")
  m["mqtts"]   = MQTTS   if supports?("mqtts")
  m["rtsp"]    = RTSP    if supports?("rtsp")
  m["ws"]      = WS      if supports?("ws")
  m["wss"]     = WSS     if supports?("wss")
  SCHEME_CLIENTS = m.freeze

  # Every scheme this gem has a per-protocol class for — the union of built and
  # not-built. Used to tell two failures apart in `call`: a scheme in here but
  # absent from SCHEME_CLIENTS is a real protocol this libcurl wasn't compiled
  # with ("protocol not available"); a scheme not in here at all is simply not a
  # URL scheme the gem knows ("unsupported scheme").
  KNOWN_SCHEMES = %w[
    http https ftp ftps sftp scp file tftp telnet gopher gophers dict
    imap imaps pop3 pop3s smtp smtps ldap ldaps mqtt mqtts rtsp ws wss
  ].freeze

  # Build the right per-protocol wrapper for a URL string. Raises URL::Error
  # before any I/O for a scheme this libcurl can't speak: "protocol not
  # available" when it's a real protocol just not compiled in, "unsupported
  # scheme" when it isn't a scheme the gem knows at all. `exec` is internal:
  # SchemeKwargs#parallel builds its queueing copy with a BatchExec so the
  # verb registers instead of runs.
  def self.call(uri, exec = URL::SyncExec)
    scheme = _scheme_of(uri)
    klass  = SCHEME_CLIENTS[scheme]
    return klass.new(uri, exec) if klass
    if KNOWN_SCHEMES.include?(scheme)
      raise URL::ProtocolNotAvailable.new(scheme, PROTOS)
    else
      raise URL::UnsupportedScheme.new(scheme, PROTOS)
    end
  end
end

# Kernel-level constructor, mirroring URI(): URL("https://x").get
module Kernel
  def URL(uri)
    URL.call(uri)
  end
  private :URL
end
