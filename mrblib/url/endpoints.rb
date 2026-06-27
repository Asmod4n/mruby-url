# mrblib/url/endpoints.rb
#
# Scheme-typed object API. `URL("https://host/path")` (or URL.call(...)) returns
# the right wrapper for the scheme — URL::HTTP / URL::Transfer / URL::IMAP / …
# Each wrapper has exactly the verbs that scheme supports, and each verb is
# defined explicitly as both an instance method (carries the URL on @uri) and a
# class method (one-shot — `URL::HTTP.get("https://x", json: …)`). Plain Ruby,
# no `define_singleton_method`, no `instance_eval`, no `method_missing`.
#
#   URL("https://api.example.com/users").get
#   URL::HTTP.get("https://api.example.com/users", params: { limit: 10 })
#   URL("ftp://host/pub/file.txt").download
#   URL("imaps://host/INBOX").fetch(uid: 5)
#   URL("mqtt://host/topic").publish("payload")
#   URL("wss://host/socket").connect { |ws| ws.send_text("hi") }

class URL
  # ---- HTTP(S) -----------------------------------------------------------
  class HTTP
    def initialize(uri);              @uri = uri.to_s; end
    def get(**o, &b);                 URL.get(@uri, **o, &b); end
    def head(**o, &b);                URL.head(@uri, **o, &b); end
    def options(**o, &b);             URL.options(@uri, **o, &b); end
    def delete(body = nil, **o, &b);  URL.delete(@uri, body, **o, &b); end
    def post(body = nil, **o, &b);    URL.post(@uri, body, **o, &b); end
    def put(body = nil, **o, &b);     URL.put(@uri, body, **o, &b); end
    def patch(body = nil, **o, &b);   URL.patch(@uri, body, **o, &b); end

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
    def initialize(uri);   @uri = uri.to_s; end
    def download(**o, &b); URL.download(@uri, **o, &b); end
    def upload(data, **o); URL.upload(@uri, data, **o); end
    def list(**o);         URL.list(@uri, **o); end

    def self.download(uri, **o, &b); new(uri).download(**o, &b); end
    def self.upload(uri, data, **o); new(uri).upload(data, **o); end
    def self.list(uri, **o);         new(uri).list(**o); end
  end
  FTP    = Transfer   # so URL::FTP.download(...) reads naturally
  FTPS   = Transfer
  SFTP   = Transfer
  SCP    = Transfer
  File_  = Transfer   # `File` is taken
  TFTP   = Transfer
  Telnet = Transfer

  # ---- gopher(s) --------------------------------------------------------
  class Gopher
    def initialize(uri); @uri = uri.to_s; end
    def get(**o, &b);    URL.download(@uri, **o, &b); end

    def self.get(uri, **o, &b); new(uri).get(**o, &b); end
  end
  Gophers = Gopher

  # ---- dict -------------------------------------------------------------
  class Dict
    def initialize(uri);                  @uri = uri.to_s; end
    def define(word, database: "!", **o); URL.lookup(@uri, word, database: database, **o); end

    def self.define(uri, word, database: "!", **o); new(uri).define(word, database: database, **o); end
  end

  # ---- imap(s) ----------------------------------------------------------
  class IMAP
    def initialize(uri);                          @uri = uri.to_s; end
    def fetch(uid:, **o, &b);                     URL.fetch(@uri, uid: uid, **o, &b); end
    def move(uid:, to:, **o);                     URL.move(@uri, uid: uid, to: to, **o); end
    def store(uid:, flags:, op: "+", **o);        URL.store(@uri, uid: uid, flags: flags, op: op, **o); end
    def expunge(**o);                             URL.expunge(@uri, **o); end

    def self.fetch(uri, uid:, **o, &b);                    new(uri).fetch(uid: uid, **o, &b); end
    def self.move(uri, uid:, to:, **o);                    new(uri).move(uid: uid, to: to, **o); end
    def self.store(uri, uid:, flags:, op: "+", **o);       new(uri).store(uid: uid, flags: flags, op: op, **o); end
    def self.expunge(uri, **o);                            new(uri).expunge(**o); end
  end
  IMAPS = IMAP

  # ---- pop3(s) ----------------------------------------------------------
  class POP3
    def initialize(uri);   @uri = uri.to_s; end
    def list(**o);         URL.list(@uri, **o); end
    def fetch(n = nil, **o, &b)
      base = @uri
      base = base[0..-2] while base.end_with?("/")
      target = n ? "#{base}/#{n}" : @uri
      URL.download(target, **o, &b)
    end

    def self.list(uri, **o);            new(uri).list(**o); end
    def self.fetch(uri, n = nil, **o, &b); new(uri).fetch(n, **o, &b); end
  end
  POP3S = POP3

  # ---- smtp(s) ----------------------------------------------------------
  class SMTP
    def initialize(uri);                @uri = uri.to_s; end
    def deliver(body, from:, to:, **o); URL.send(@uri, body, from: from, to: to, **o); end

    def self.deliver(uri, body, from:, to:, **o); new(uri).deliver(body, from: from, to: to, **o); end
  end
  SMTPS = SMTP

  # ---- ldap(s) ----------------------------------------------------------
  class LDAP
    def initialize(uri); @uri = uri.to_s; end
    def search(**o);     URL.search(@uri, **o); end

    def self.search(uri, **o); new(uri).search(**o); end
  end
  LDAPS = LDAP

  # ---- mqtt(s) ----------------------------------------------------------
  class MQTT
    def initialize(uri);          @uri = uri.to_s; end
    def publish(payload, **o);    URL.publish(@uri, payload, **o); end
    def subscribe(**o, &b);       URL.subscribe(@uri, **o, &b); end

    def self.publish(uri, payload, **o);  new(uri).publish(payload, **o); end
    def self.subscribe(uri, **o, &b);     new(uri).subscribe(**o, &b); end
  end
  MQTTS = MQTT

  # ---- rtsp -------------------------------------------------------------
  class RTSP
    def initialize(uri);     @uri = uri.to_s; end
    def options(**o);        URL.rtsp(@uri, request: :options, **o); end
    def describe(**o);       URL.rtsp(@uri, request: :describe, **o); end
    def setup(**o);          URL.rtsp(@uri, request: :setup, **o); end
    def play(**o);           URL.rtsp(@uri, request: :play, **o); end
    def pause(**o);          URL.rtsp(@uri, request: :pause, **o); end
    def teardown(**o);       URL.rtsp(@uri, request: :teardown, **o); end
    def get_parameter(**o);  URL.rtsp(@uri, request: :get_parameter, **o); end
    def set_parameter(**o);  URL.rtsp(@uri, request: :set_parameter, **o); end

    def self.options(uri, **o);        new(uri).options(**o); end
    def self.describe(uri, **o);       new(uri).describe(**o); end
    def self.setup(uri, **o);          new(uri).setup(**o); end
    def self.play(uri, **o);           new(uri).play(**o); end
    def self.pause(uri, **o);          new(uri).pause(**o); end
    def self.teardown(uri, **o);       new(uri).teardown(**o); end
    def self.get_parameter(uri, **o);  new(uri).get_parameter(**o); end
    def self.set_parameter(uri, **o);  new(uri).set_parameter(**o); end
  end

  # ---- ws(s) ------------------------------------------------------------
  class WS
    def initialize(uri);  @uri = uri.to_s; end
    def connect(**o, &b); URL.websocket(@uri, **o, &b); end

    def self.connect(uri, **o, &b); new(uri).connect(**o, &b); end
  end
  WSS = WS

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

  # Build the right wrapper for a URL string (or any object with #scheme/#to_s).
  # Raises URL::Error for an unknown/unbuilt scheme — that's a usage error.
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
