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
# @on_read / @on_open_socket) directly on the Easy handle, because the C
# write/header/read/opensocket trampolines read those ivars off the Easy
# object when libcurl fires them.

# The Easy handle carries the user callbacks as ivars. The C
# write/header/read/opensocket trampolines read @on_data / @on_header /
# @on_read / @on_open_socket off this object, so define plain writers here
# (attr_writer assigns exactly those ivars).
class URL::Libcurl::Easy
  attr_writer :on_data, :on_header, :on_read, :on_open_socket
end

class URL::Request
  attr_reader :handle

  # Make a fresh easy handle, optionally set its URL, and remember the owning
  # session. The easy handle's GC frees the underlying CURL*; the
  # write/header/read callbacks are already wired by Libcurl.easy_init.
  # The session's on_open_socket default (if any) is applied here, through
  # the same #on_open_socket below, so it gets the identical Addrinfo-wrapping
  # treatment as an explicit per-request override — the request can still
  # replace it with its own by calling #on_open_socket again afterward.
  def initialize(session, url = nil)
    @session = session
    @handle  = URL::Libcurl.easy_init
    URL::Libcurl.easy_setopt(@handle, :url, url) if url
    on_open_socket(&session.on_open_socket) if session.on_open_socket
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

  # Fires once per resolved address libcurl is about to connect to, before
  # it opens the socket — the hook for refusing SSRF-style targets (loopback,
  # RFC1918, link-local, cloud metadata IPs, ...) before any connection is
  # made. The C trampoline yields the raw resolved sockaddr bytes; wrap them
  # in an Addrinfo here (mruby-socket is already a hard dependency of this
  # gem) so the block gets a real object — addr.ip_address, addr.ipv4?/ipv6?
  # — instead of bytes it would have to unpack itself. purpose is :connect
  # for a normal outbound connection, or :accept for the rare FTP
  # active-mode data connection.
  #
  # Return truthy from the block to allow the connection, falsy/nil to
  # refuse just that candidate address (libcurl tries the next resolved
  # address, if any). No block set: every address is allowed, same as
  # before this callback existed.
  def on_open_socket(&block)
    @handle.on_open_socket = lambda { |sockaddr, purpose| block.call(Addrinfo.new(sockaddr), purpose) }
    self
  end
end
