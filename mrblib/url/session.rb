# mrblib/url/session.rb
#
# URL (the session) — a thin Ruby wrapper around a URL::Libcurl::Multi handle.
#
# Everything the C layer used to do for a multi handle now lives here in Ruby:
# add/remove bookkeeping, the socket_action drain loop, replaying socket
# changes to the event loop, arming/cancelling the loop timer, and the
# action/timer procs the event loop invokes. C only exposes the flat per-call
# Libcurl primitives (multi_init/multi_add/multi_socket_action/…); the
# orchestration below is all Ruby.

# The Multi handle carries libcurl's socket/timer callbacks as Ruby blocks; the
# C trampolines read @on_socket / @on_timer off it (mirrors Easy#on_data).
class URL::Libcurl::Multi
  attr_writer :on_socket, :on_timer
end

class URL
  # Allocate a session wrapping a fresh CURLM. The multi handle's GC frees the
  # underlying CURLM*; its socket/timer callbacks are wired by multi_init.
  def self.open
    new
  end

  def initialize
    @multi           = URL::Libcurl.multi_init
    # easy.object_id => URL::Request: maps a completed easy back to its Request
    # in info_read. The GC-safety root that keeps the in-flight easy alive while
    # curl_multi references it lives in C (multi_add pins it under a hidden ivar
    # on the multi), so tampering with this Ruby map can't cause a use-after-free.
    @by_easy         = {}
    @event_loop      = nil
    @_timer_handle   = nil
    @pending_timeout = :unset

    # libcurl's socket/timer callbacks call straight back into these blocks (run
    # under mrb_protect_error in C). on_socket replays each fd change to the
    # event loop; on_timer records the timeout that socket_action's drain loop
    # and the timer re-arm at the end of socket_action consume — no C-side
    # buffering. The timeout arrives as a chrono duration (Float seconds,
    # converted from libcurl's ms at the C boundary), or nil for libcurl's
    # "delete the timer".
    @multi.on_socket = lambda do |fd, what|
      _socket_ready(fd, what) if @event_loop
    end
    @multi.on_timer = lambda do |timeout|
      @pending_timeout = timeout
    end

    # The procs an event loop invokes on fd readiness / timer expiry: drive
    # the transfer, then reap completions off the multi. Mirror the old C
    # action/timer cfuncs.
    @_action_block = lambda do |io, cond|
      socket_action(io, cond)
      _reap
      true
    end

    @_timer_block = lambda do
      socket_action
      _reap
      false
    end

    self
  end

  # A session owns a libcurl multi handle, which has no curl_multi_duphandle —
  # a dup/clone would share the one CURLM (and its in-flight transfers) unsafely.
  # Refuse it; open an independent session with URL.open instead.
  def initialize_copy(orig)
    raise NotImplementedError,
          "can't dup/clone #{self.class}: a session owns a libcurl multi handle " \
          "that can't be duplicated — use URL.open for a new session"
  end

  def setopt(opt, val)
    URL::Libcurl.multi_setopt(@multi, opt, val)
    self
  end

  def add(req)
    URL::Libcurl.multi_add(@multi, req.handle)   # C pins the easy as a GC root
    @by_easy[req.handle.object_id] = req
    self
  end

  def remove(req)
    URL::Libcurl.multi_remove(@multi, req.handle)  # C drops the GC root
    @by_easy.delete(req.handle.object_id)
    self
  end

  # Drive libcurl on a socket event (or a timeout when called with no args),
  # then replay the resulting socket/timer changes to the event loop.
  #
  # libcurl can ask to be called again immediately by reporting a 0ms timeout;
  # we drain that here (loop while the taken timeout is 0) before flushing.
  # Any exception a write/header/read callback stashed surfaces out of
  # multi_socket_action, so the flush below is skipped while one is pending and
  # the buffered events carry over to the next call — exactly as before.
  def socket_action(fd = URL::Libcurl::SOCKET_TIMEOUT, ev = nil)
    fd = fd.fileno if fd.respond_to?(:fileno)

    # on_socket fires _socket_ready during the call; on_timer records the
    # new timeout (a chrono duration in seconds, or nil for "delete the
    # timer") into @pending_timeout. libcurl can ask to be re-driven
    # immediately by reporting a zero timeout — drained below before arming.
    @pending_timeout = :unset
    running = URL::Libcurl.multi_socket_action(@multi, fd, ev)
    timeout = @pending_timeout

    drain_limit = 64
    while timeout == 0 && drain_limit > 0
      drain_limit -= 1
      @pending_timeout = :unset
      running = URL::Libcurl.multi_socket_action(@multi, URL::Libcurl::SOCKET_TIMEOUT, nil)
      timeout = @pending_timeout
    end

    # Arm/cancel the event loop's timer from what libcurl reported:
    # :unset (callback never fired) leaves any existing timer alone,
    # nil / zero cancels, a positive duration re-arms.
    if timeout != :unset && @event_loop
      if @_timer_handle
        @event_loop.cancel_timer(@_timer_handle)
        @_timer_handle = nil
      end
      @_timer_handle = @event_loop.arm_timer(timeout, &@_timer_block) if timeout && timeout > 0
    end

    running
  end

  # Event-less drive: one curl_multi_perform pass. libcurl checks all its own
  # fds and timers internally — no socket/timer callbacks, no event loop.
  # Returns the number of still-running transfers. The blocking SyncDriver is
  # built on perform + poll; the EventLoop interface is only for external
  # loop integrations.
  def perform
    URL::Libcurl.multi_perform(@multi)
  end

  # Wait up to `timeout` (a chrono duration — 500.ms, 2.s, any Numeric
  # seconds) for activity on any of libcurl's own fds, or just sleep the full
  # timeout when nothing is attached — curl_multi_poll, libcurl's portable
  # wait. Caps at libcurl's next internal timeout automatically. The
  # seconds→ms conversion happens in C via mruby-chrono, never here.
  def poll(timeout)
    URL::Libcurl.multi_poll(@multi, timeout)
  end

  # Yield one [request, result_code] pair per completed transfer. The C
  # primitive reports completions as [easy, code]; map each easy back to the
  # owning URL::Request so callers see the same objects they added.
  def info_read
    while (pair = URL::Libcurl.multi_info_read(@multi))
      req = @by_easy[pair[0].object_id]
      yield req, pair[1] if req
    end
    self
  end

  # Event-loop reap: detach each finished transfer, then fire its Request's
  # completion callback (Request#on_complete) with the CURLcode. This is how
  # evented callers learn a transfer finished — e.g. the WebSocket upgrade
  # handshake. The blocking SyncDriver paths deliver completions through
  # their own run_until/run_n blocks and never come through here.
  #
  # A request registered with on_complete(detach: false) stays attached: a
  # completed CONNECT_ONLY easy loses its established connection the moment
  # it leaves the multi, so the WebSocket detaches itself at teardown instead.
  def _reap
    info_read do |req, code|
      (remove(req) rescue nil) if req._detach_on_complete?
      req._complete(code)
    end
  end

end
