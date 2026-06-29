# mrblib/url/request.rb
#
# URL::Request — a thin Ruby wrapper around a URL::Libcurl::Easy handle.
#
# All the work the C layer used to do for a request now lives here: option
# mapping, header-string construction, getinfo and the callback setters. C
# only exposes the flat per-call Libcurl primitives; everything below is plain
# Ruby orchestration over them.
#
# The callback setters store the block as an ivar (@on_data / @on_header /
# @on_read) directly on the Easy handle, because the C write/header/read
# trampolines read those ivars off the Easy object when libcurl fires them.

# The Easy handle carries the user callbacks as ivars. The C write/header/read
# trampolines read @on_data / @on_header / @on_read off this object, so define
# plain writers here (attr_writer assigns exactly those ivars).
class URL::Libcurl::Easy
  attr_writer :on_data, :on_header, :on_read
end

class URL::Request
  attr_reader :handle

  # Mirrors the old C URL::Request._open: make a fresh easy handle, optionally
  # set its URL, and remember the owning session. The easy handle's GC frees
  # the underlying CURL*; the write/header/read callbacks are already wired by
  # Libcurl.easy_init.
  def self._open(session, url = nil)
    new(session, url)
  end

  # Delegate the libcurl-error helper to the flat primitive.
  def self.strerror(code)
    URL::Libcurl.easy_strerror(code)
  end

  def initialize(session, url = nil)
    @session = session
    @handle  = URL::Libcurl.easy_init
    URL::Libcurl.easy_setopt(@handle, :url, url) if url
  end

  # dup / clone: give the copy its OWN libcurl handle. Object#initialize_copy
  # would leave the two Requests sharing one Easy; instead dup the handle (the
  # Easy's own initialize_copy duplicates the underlying CURL* via
  # curl_easy_duphandle), so the copy is independent and usable. The session is
  # shared on purpose — the copy belongs to the same session.
  def initialize_copy(orig)
    super
    @handle = orig.handle.dup
    self
  end

  def setopt(opt, val)
    URL::Libcurl.easy_setopt(@handle, opt, val)
    self
  end

  # Accepts a Hash of header name => value(s). Builds the "Key: Value" lines in
  # Ruby and hands the resulting Array to the easy_setopt :httpheader primitive,
  # which (re)builds the libcurl slist in C.
  def headers=(hash)
    lines = []
    hash.each do |key, val|
      lines << "#{key}: #{val}"
    end
    URL::Libcurl.easy_setopt(@handle, :httpheader, lines)
    hash
  end

  def response_code; URL::Libcurl.easy_getinfo(@handle, :response_code); end
  def effective_url; URL::Libcurl.easy_getinfo(@handle, :effective_url); end
  def total_time;    URL::Libcurl.easy_getinfo(@handle, :total_time);    end
  def content_type;  URL::Libcurl.easy_getinfo(@handle, :content_type);  end

  # The live socket fd of an established connection (CURLINFO_ACTIVESOCKET), or
  # nil if there isn't one. Used by URL::WebSocket to IO.select between the
  # ws_send / ws_recv framing primitives.
  def activesocket; URL::Libcurl.easy_getinfo(@handle, :activesocket); end

  # WebSocket framing primitives — thin pass-throughs to the C glue. ws_recv
  # returns [bytes, flags, bytesleft] or nil on CURLE_AGAIN; ws_send returns the
  # byte count sent or nil on CURLE_AGAIN. All message-level logic (reassembly,
  # frame dispatch, the send loop) lives in URL::WebSocket.
  def ws_recv(buflen);                    URL::Libcurl.easy_ws_recv(@handle, buflen);                 end
  def ws_send(data, flags, fragsize = 0); URL::Libcurl.easy_ws_send(@handle, data, flags, fragsize); end

  # Blocking single-transfer drive (curl_easy_perform). Returns the CURLcode as
  # a value (0 == success). Used by the WebSocket connect path: with
  # :connect_only => 2 it runs the upgrade handshake and leaves the live socket
  # on the handle for ws_recv / ws_send.
  def perform; URL::Libcurl.easy_perform(@handle); end

  # Callback setters. The block is stashed as an ivar on the Easy handle so the
  # C trampoline can pick it up; the write/header callbacks yield a String of
  # received bytes, the read callback yields the max byte count and expects a
  # String back.
  def on_data(&block)
    @handle.on_data = block
    self
  end

  def on_header(&block)
    @handle.on_header = block
    self
  end

  def on_read(&block)
    @handle.on_read = block
    self
  end
end
