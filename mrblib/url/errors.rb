# mrblib/url/errors.rb
#
# The gem's two-tier error model.
#
#   * Usage errors — calling a verb wrong, handing it an unbuilt scheme — RAISE
#     a URL::Error the moment you make the mistake. They are bugs in the calling
#     code, so they behave like every other Ruby usage error.
#
#   * Transfer errors — anything that goes wrong once libcurl is driving the
#     request/response — are returned as VALUES. `resp.error` is nil when the
#     transfer reached the server and came back, or holds an exception object
#     describing libcurl's failure otherwise. Nothing is raised unless you ask,
#     via `resp.raise_for_status!` or by raising `resp.error` yourself.
#
# Every libcurl CURLcode maps to exactly one exception class:
#
#   * By default a URL::<Name> subclass of URL::TransferError, named after the
#     CURLE_ enum in CamelCase — CURLE_COULDNT_CONNECT => URL::CouldntConnect,
#     CURLE_OPERATION_TIMEDOUT => URL::OperationTimedout. `rescue
#     URL::TransferError` catches the whole family.
#
#   * Where libcurl's failure is the *same concept* as an exception mruby already
#     ships, we reuse the built-in so it feels native to rescue. A DNS failure is
#     the SocketError mruby-socket itself raises for the identical thing; rescuing
#     SocketError just works. We only do this where the match is exact — libcurl
#     hands us its own coarse CURLcode, never a system errno, so we deliberately
#     do NOT fabricate Errno::* classes we cannot actually identify from a single
#     CURLcode.
#
#   * The flip side of that rule: where a CURLcode's CamelCase name would collide
#     with a built-in that means something *different*, we rename the curl class
#     so the two are never confused. CURLE_RANGE_ERROR (a failed range request)
#     becomes URL::CurlRangeError, never URL::RangeError — Ruby's RangeError is
#     about numeric values out of range, an unrelated thing.
#
#   * CURLE_OUT_OF_MEMORY is special and never appears here: out of memory cannot
#     safely be turned into a returned value (building one may itself allocate),
#     so the C extension raises mruby's preallocated NoMemoryError directly the
#     moment libcurl reports it, before the code ever reaches Ruby.
#
# An HTTP error status is surfaced as a value too, right alongside the CURLcodes:
# when the transfer itself succeeded (CURLE_OK) but the HTTP status is >= 400,
# resp.error holds a URL::HttpReturnedError — libcurl's own name for that case,
# CURLE_HTTP_RETURNED_ERROR. Like every other error here it is a value, not a
# raise; resp.raise_for_status! is the opt-in that raises whatever resp.error
# holds.

class URL
  # Base for everything this gem raises directly. Usage mistakes and the
  # value-returned transfer errors both descend from it, so `rescue URL::Error`
  # catches anything gem-specific.
  class Error < StandardError; end

  # Base for the value-returned transfer errors (what `resp.error` hands back).
  # Carries libcurl's numeric code, libcurl's own message, and the Response it
  # came from, so a handler that caught one far from the call site can still get
  # at the details.
  class TransferError < Error
    attr_reader :response, :curl_code, :curl_message

    def initialize(message = nil, response: nil, curl_code: nil, curl_message: nil)
      @response     = response
      @curl_code    = curl_code
      @curl_message = curl_message
      super(message || curl_message || "libcurl transfer failed (#{curl_code})")
    end
  end

  # CURLcode => CamelCase class name, for every code we mint a URL:: class for.
  # Reused built-ins (CURL_BUILTIN_ERROR) and the C-raised CURLE_OUT_OF_MEMORY
  # are intentionally absent. Generated from curl.h's CURLcode enum.
  CURL_ERROR_NAMES = {
    1   => :UnsupportedProtocol,
    2   => :FailedInit,
    3   => :UrlMalformat,
    4   => :NotBuiltIn,
    7   => :CouldntConnect,
    8   => :WeirdServerReply,
    9   => :RemoteAccessDenied,
    10  => :FtpAcceptFailed,
    11  => :FtpWeirdPassReply,
    12  => :FtpAcceptTimeout,
    13  => :FtpWeirdPasvReply,
    14  => :FtpWeird227Format,
    15  => :FtpCantGetHost,
    16  => :Http2,
    17  => :FtpCouldntSetType,
    18  => :PartialFile,
    19  => :FtpCouldntRetrFile,
    21  => :QuoteError,
    22  => :HttpReturnedError,
    23  => :WriteError,
    25  => :UploadFailed,
    26  => :ReadError,
    28  => :OperationTimedout,
    30  => :FtpPortFailed,
    31  => :FtpCouldntUseRest,
    33  => :CurlRangeError,   # see "same name, different meaning" in the header
    34  => :HttpPostError,
    35  => :SslConnectError,
    36  => :BadDownloadResume,
    37  => :FileCouldntReadFile,
    38  => :LdapCannotBind,
    39  => :LdapSearchFailed,
    41  => :FunctionNotFound,
    42  => :AbortedByCallback,
    43  => :BadFunctionArgument,
    45  => :InterfaceFailed,
    47  => :TooManyRedirects,
    48  => :UnknownOption,
    49  => :SetoptOptionSyntax,
    52  => :GotNothing,
    53  => :SslEngineNotfound,
    54  => :SslEngineSetfailed,
    55  => :SendError,
    56  => :RecvError,
    58  => :SslCertproblem,
    59  => :SslCipher,
    60  => :PeerFailedVerification,
    61  => :BadContentEncoding,
    63  => :FilesizeExceeded,
    64  => :UseSslFailed,
    65  => :SendFailRewind,
    66  => :SslEngineInitfailed,
    67  => :LoginDenied,
    68  => :TftpNotfound,
    69  => :TftpPerm,
    70  => :RemoteDiskFull,
    71  => :TftpIllegal,
    72  => :TftpUnknownid,
    73  => :RemoteFileExists,
    74  => :TftpNosuchuser,
    77  => :SslCacertBadfile,
    78  => :RemoteFileNotFound,
    79  => :Ssh,
    80  => :SslShutdownFailed,
    81  => :Again,
    82  => :SslCrlBadfile,
    83  => :SslIssuerError,
    84  => :FtpPretFailed,
    85  => :RtspCseqError,
    86  => :RtspSessionError,
    87  => :FtpBadFileList,
    88  => :ChunkFailed,
    89  => :NoConnectionAvailable,
    90  => :SslPinnedpubkeynotmatch,
    91  => :SslInvalidcertstatus,
    92  => :Http2Stream,
    93  => :RecursiveApiCall,
    94  => :AuthError,
    95  => :Http3,
    96  => :QuicConnectError,
    97  => :Proxy,
    98  => :SslClientcert,
    99  => :UnrecoverablePoll,
  }.freeze

  # CURLcode => an exception mruby already ships, used instead of minting a
  # URL:: class because the concept is identical and rescuing the built-in is
  # what a Ruby user expects. libcurl reports a name-resolution failure exactly
  # where mruby-socket would raise SocketError, so we hand back the same class.
  CURL_BUILTIN_ERROR = {
    5 => SocketError,   # CURLE_COULDNT_RESOLVE_PROXY
    6 => SocketError,   # CURLE_COULDNT_RESOLVE_HOST
  }.freeze

  # Mint one URL::<Name> class per CURLcode (all under URL::TransferError) and
  # record code => class. The inherit=false on the existence check is essential:
  # a few enum names (RangeError) collide with a core exception, and the default
  # constant lookup walks ancestors — it would find ::RangeError and alias the
  # curl error to the core class instead of minting URL's own. Built-ins win
  # over a minted class.
  CURL_ERROR_CLASS = {}
  CURL_BUILTIN_ERROR.each { |code, klass| CURL_ERROR_CLASS[code] = klass }
  CURL_ERROR_NAMES.each do |code, name|
    next if CURL_ERROR_CLASS.key?(code)
    klass = const_defined?(name, false) ? const_get(name) : const_set(name, Class.new(TransferError))
    CURL_ERROR_CLASS[code] = klass
  end
  CURL_ERROR_CLASS.freeze

  class << self
    # Build the exception object for a finished transfer, or nil when libcurl
    # reported success (CURLE_OK). `code` is the CURLcode from
    # curl_multi_info_read; `message` is libcurl's decorated strerror text.
    # Reused built-ins get a plain instance — the Response is already in the
    # caller's hand — while URL::TransferError subclasses carry the full context.
    def _transfer_error(response, code, message = nil)
      return nil if code.nil? || code == 0
      klass = CURL_ERROR_CLASS[code] || TransferError
      if klass.ancestors.include?(TransferError)
        klass.new(message, response: response, curl_code: code, curl_message: message)
      else
        klass.new(message || "libcurl error #{code}")
      end
    end
  end
end
