# mrblib/url/endpoints.rb
#
# Scheme-typed object API. `URL("https://host/path")` returns the right wrapper
# for the scheme — URL::HTTP / URL::Transfer / URL::IMAP / … Each wrapper has
# exactly the verbs that scheme supports, both as instance methods (carry the
# URL on @uri) and as class methods (one-shot — `URL::HTTP.get("https://x")`).
# Plain Ruby, no define_singleton_method, no instance_eval, no method_missing.
#
# Each verb dispatches straight into the engine helpers in dispatch.rb:
# _fire (the multi-driven HTTP path), _run_transfer (one-shot transfers used by
# everything non-HTTP), _imap (IMAP shape), _build_mail_request + _drive_sync
# (SMTP shape), _open_websocket (WS handshake). Nothing is delegated through
# the (now removed) top-level URL.verb methods.

class URL
  # ---- HTTP(S) -----------------------------------------------------------
  class HTTP
    def initialize(uri); @uri = uri.to_s; end

    def get(**o, &b);                URL._fire(:GET,     @uri, nil,  o, &b); end
    def head(**o, &b);               URL._fire(:HEAD,    @uri, nil,  o, &b); end
    def options(**o, &b);            URL._fire(:OPTIONS, @uri, nil,  o, &b); end
    def delete(body = nil, **o, &b); URL._fire(:DELETE,  @uri, body, o, &b); end
    def post(body = nil, **o, &b);   URL._fire(:POST,    @uri, body, o, &b); end
    def put(body = nil, **o, &b);    URL._fire(:PUT,     @uri, body, o, &b); end
    def patch(body = nil, **o, &b);  URL._fire(:PATCH,   @uri, body, o, &b); end

    def self.get(uri, **o, &b);                 new(uri).get(**o, &b); end
    def self.head(uri, **o, &b);                new(uri).head(**o, &b); end
    def self.options(uri, **o, &b);             new(uri).options(**o, &b); end
    def self.delete(uri, body = nil, **o, &b);  new(uri).delete(body, **o, &b); end
    def self.post(uri, body = nil, **o, &b);    new(uri).post(body, **o, &b); end
    def self.put(uri, body = nil, **o, &b);     new(uri).put(body, **o, &b); end
    def self.patch(uri, body = nil, **o, &b);   new(uri).patch(body, **o, &b); end
  end

  # ---- file / ftp(s) / sftp / scp / tftp / telnet -----------------------
  class Transfer
    def initialize(uri); @uri = uri.to_s; end

    def download(**o, &b)
      URL._require_protocol!(@uri)
      URL._run_transfer(@uri, o, b, nil)
    end
    def upload(data, **o)
      URL._require_protocol!(@uri)
      URL._run_transfer(@uri, o, nil, data)
    end
    def list(**o)
      URL._require_protocol!(@uri)
      URL._run_transfer(@uri, o.merge(dirlistonly: true), nil, nil)
    end

    def self.download(uri, **o, &b); new(uri).download(**o, &b); end
    def self.upload(uri, data, **o); new(uri).upload(data, **o); end
    def self.list(uri, **o);         new(uri).list(**o); end
  end

  # ---- gopher(s) --------------------------------------------------------
  class Gopher
    def initialize(uri); @uri = uri.to_s; end

    def get(**o, &b)
      URL._require_protocol!(@uri)
      URL._run_transfer(@uri, o, b, nil)
    end
    alias download get

    def self.get(uri, **o, &b);      new(uri).get(**o, &b); end
    def self.download(uri, **o, &b); new(uri).download(**o, &b); end
  end

  # ---- dict -------------------------------------------------------------
  class Dict
    def initialize(uri); @uri = uri.to_s; end

    def define(word, database: "!", **o)
      URL._require_protocol!(@uri)
      base = @uri
      base = base[0..-2] while base.end_with?("/")
      URL._run_transfer("#{base}/d:#{word}:#{database}", o, nil, nil)
    end

    def self.define(uri, word, database: "!", **o); new(uri).define(word, database: database, **o); end
  end

  # ---- imap(s) ----------------------------------------------------------
  class IMAP
    def initialize(uri); @uri = uri.to_s; end

    def fetch(uid:, **o, &b)
      URL._require_protocol!(@uri)
      URL._imap(@uri, nil, o, ";UID=#{uid}", b)
    end
    def move(uid:, to:, **o)
      URL._require_protocol!(@uri)
      URL._imap(@uri, "UID MOVE #{uid} #{to}", o)
    end
    def store(uid:, flags:, op: "+", **o)
      URL._require_protocol!(@uri)
      URL._imap(@uri, "UID STORE #{uid} #{op}FLAGS (#{flags})", o)
    end
    def expunge(**o)
      URL._require_protocol!(@uri)
      URL._imap(@uri, "EXPUNGE", o)
    end

    def self.fetch(uri, uid:, **o, &b);                    new(uri).fetch(uid: uid, **o, &b); end
    def self.move(uri, uid:, to:, **o);                    new(uri).move(uid: uid, to: to, **o); end
    def self.store(uri, uid:, flags:, op: "+", **o);       new(uri).store(uid: uid, flags: flags, op: op, **o); end
    def self.expunge(uri, **o);                            new(uri).expunge(**o); end
  end

  # ---- pop3(s) ----------------------------------------------------------
  class POP3
    def initialize(uri); @uri = uri.to_s; end

    def list(**o)
      URL._require_protocol!(@uri)
      URL._run_transfer(@uri, o.merge(dirlistonly: true), nil, nil)
    end
    def fetch(n = nil, **o, &b)
      URL._require_protocol!(@uri)
      target = @uri
      if n
        base = @uri
        base = base[0..-2] while base.end_with?("/")
        target = "#{base}/#{n}"
      end
      URL._run_transfer(target, o, b, nil)
    end
    # download is the same idea — POP3 calls it retrieving a message, so we
    # delegate to fetch (with optional message-id n) for symmetry with the
    # other Transfer-shaped wrappers.
    def download(n = nil, **o, &b); fetch(n, **o, &b); end

    def self.list(uri, **o);                  new(uri).list(**o); end
    def self.fetch(uri, n = nil, **o, &b);    new(uri).fetch(n, **o, &b); end
    def self.download(uri, n = nil, **o, &b); new(uri).download(n, **o, &b); end
  end

  # ---- smtp(s) ----------------------------------------------------------
  class SMTP
    def initialize(uri); @uri = uri.to_s; end

    # Replaces the old URL.send — no Object#send clash.
    def deliver(body, from:, to:, **opts)
      URL._require_protocol!(@uri)
      session = URL.shared
      session = URL.open if session._busy?
      recipients = to.is_a?(Array) ? to : [to]
      req, state = URL._build_mail_request(session, @uri, from, recipients, body, opts)
      URL._drive_sync(session, @uri, req, state)
    end

    def self.deliver(uri, body, from:, to:, **o); new(uri).deliver(body, from: from, to: to, **o); end
  end

  # ---- ldap(s) ----------------------------------------------------------
  class LDAP
    def initialize(uri); @uri = uri.to_s; end

    def search(**o)
      URL._require_protocol!(@uri)
      URL._run_transfer(@uri, o, nil, nil)
    end

    def self.search(uri, **o); new(uri).search(**o); end
  end

  # ---- mqtt(s) ----------------------------------------------------------
  class MQTT
    def initialize(uri); @uri = uri.to_s; end

    def publish(payload, **o)
      URL._require_protocol!(@uri)
      URL._run_transfer(@uri, o.merge(post_fields: payload.to_s), nil, nil)
    end

    # Receive one message. libcurl keeps the subscription open, so this blocks
    # until `timeout` (a chrono duration, default 5.s) elapses and returns the
    # message received meanwhile. Curl frames each message as [2-byte topic
    # length][topic][payload]; the payload is extracted and the expected
    # keep-alive timeout is normalised away, so #error is nil on a clean receive.
    def subscribe(timeout: 5.0, **o)
      URL._require_protocol!(@uri)
      resp    = URL._run_transfer(@uri, o.merge(timeout: timeout), nil, nil)
      payload = URL._mqtt_payload(resp.body)
      # CURLE_OPERATION_TIMEDOUT (28) is how a one-shot subscribe ends once the
      # message arrived; clear it when we actually got a payload.
      ecode = (resp.error_code == 28 && payload && !payload.empty?) ? 0 : resp.error_code
      URL::Response.new(
        url: @uri, effective_url: resp.effective_url, code: resp.code,
        body: payload || "", raw_headers: resp.raw_headers,
        total_time: resp.total_time, content_type: resp.content_type,
        error_code: ecode
      )
    end

    def self.publish(uri, payload, **o);  new(uri).publish(payload, **o); end
    def self.subscribe(uri, **o);         new(uri).subscribe(**o); end
  end

  # ---- rtsp -------------------------------------------------------------
  class RTSP
    # CURL_RTSP_REQ_* enum, kept on the class so the verbs map cleanly.
    REQUESTS = {
      options: 1, describe: 2, announce: 3, setup: 4, play: 5, pause: 6,
      teardown: 7, get_parameter: 8, set_parameter: 9, record: 10, receive: 11,
    }.freeze

    def initialize(uri); @uri = uri.to_s; end

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

    private

    def _request(verb, transport, stream_uri, opts)
      URL._require_protocol!(@uri)
      enum = REQUESTS[verb] or raise URL::Error, "unknown RTSP request: #{verb.inspect}"
      opts = opts.merge(rtsp_request: enum)
      opts[:rtsp_stream_uri] = stream_uri if stream_uri
      opts[:rtsp_transport]  = transport  if transport
      URL._run_transfer(@uri, opts, nil, nil)
    end
  end

  # ---- ws(s) ------------------------------------------------------------
  class WS
    def initialize(uri); @uri = uri.to_s; end

    # With a block, the live socket is yielded and closed for you; a socket
    # that failed to connect is not yielded — inspect ws.error on the return.
    def connect(**opts, &block)
      URL._require_protocol!(@uri)
      ws = URL._open_websocket(@uri, opts)
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

  # scheme -> wrapper class
  SCHEME_CLIENTS = {
    "http"   => HTTP,     "https"  => HTTP,
    "ftp"    => Transfer, "ftps"   => Transfer,
    "sftp"   => Transfer, "scp"    => Transfer,
    "file"   => Transfer, "tftp"   => Transfer, "telnet" => Transfer,
    "gopher" => Gopher,   "gophers" => Gopher,
    "dict"   => Dict,
    "imap"   => IMAP,     "imaps"  => IMAP,
    "pop3"   => POP3,     "pop3s"  => POP3,
    "smtp"   => SMTP,     "smtps"  => SMTP,
    "ldap"   => LDAP,     "ldaps"  => LDAP,
    "mqtt"   => MQTT,     "mqtts"  => MQTT,
    "rtsp"   => RTSP,
    "ws"     => WS,       "wss"    => WS,
  }.freeze

  # Build the right wrapper for a URL string. Raises URL::Error for an
  # unknown/unbuilt scheme — that's a usage error.
  def self.call(uri)
    scheme = _scheme_of(uri)
    klass  = SCHEME_CLIENTS[scheme] or
      raise URL::Error, "unsupported scheme: #{scheme.inspect}"
    klass.new(uri)
  end
end

# Kernel-level constructor, mirroring URI(): URL("https://x").get
module Kernel
  def URL(uri)
    URL.call(uri)
  end
  private :URL
end
