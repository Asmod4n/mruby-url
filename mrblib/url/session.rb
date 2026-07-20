# mrblib/url/session.rb
#
# URL (the session) — a thin Ruby wrapper around a URL::Libcurl::Multi handle.
#
# Everything the C layer used to do for a multi handle now lives here in Ruby:
# add/remove bookkeeping, the socket_action drain loop, replaying socket
# changes to the event loop, arming/cancelling the loop timer, reaping and
# dispatching completions, and deferring multi mutation while a libcurl
# callback for this multi is still on the C stack. C only exposes the flat
# per-call Libcurl primitives (multi_init/multi_add/multi_socket_action/…);
# the orchestration below is all Ruby.
#
# A session always drives through an event loop — URL.default_loop unless
# session.event_loop= pins a specific one. There is no other way anything in
# this gem waits: every drive is "register with the loop, let its run_once be
# called until done."

# The Multi handle carries libcurl's socket/timer callbacks as Ruby blocks; the
# C trampolines read @on_socket / @on_timer off it (mirrors Easy#on_data).
class URL::Libcurl::Multi
  attr_writer :on_socket, :on_timer
end

class URL
  # True while a libcurl callback for SOME multi is still on the C call
  # stack (a write/header/read/socket/timer trampoline invoked from inside
  # multi_socket_action). libcurl forbids mutating or re-driving a multi
  # while one of its own callbacks hasn't returned yet; conservatively, no
  # multi is touched at all while this is true — every drive started in that
  # window uses its own private, throwaway loop and session instead (see
  # dispatch.rb's isolated-drive fallback). A single process-wide depth
  # counter, not one per multi: simpler, and the isolated fallback never
  # shares state with whatever's mid-callback anyway.
  def self._in_c?
    (@_in_c_depth ||= 0) > 0
  end

  def self._with_c_frame
    @_in_c_depth = (@_in_c_depth || 0) + 1
    yield
  ensure
    @_in_c_depth -= 1
  end

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
    @on_done         = {}   # req.object_id => completion block (from #add)
    @keep_on_done    = {}   # req.object_id => true for remove_on_done: false
    @event_loop      = nil  # resolved (and pinned) lazily — see #event_loop
    @_timer_handle   = nil
    @pending_timeout = nil
    @timer_fired     = false
    @deferred_removes = []  # requests whose removal was deferred (see #remove)

    # libcurl's socket/timer callbacks call straight back into these blocks (run
    # under mrb_protect_error in C). on_socket replays each fd change to the
    # event loop; on_timer records the timeout — a chrono duration (0.0 = drive
    # again now) or nil (cancel the timer) — that socket_action's drain loop and
    # the timer re-arm at the end of socket_action consume; @timer_fired tells
    # "the callback asked for nil" apart from "the callback never ran".
    @multi.on_socket = lambda { |fd, what| _socket_ready(fd, what) }
    @multi.on_timer = lambda do |timeout|
      @pending_timeout = timeout
      @timer_fired     = true
    end

    # The blocks the event loop invokes on fd readiness / timer expiry: just
    # re-enter socket_action, which drains, reaps and re-arms.
    @_action_block = lambda { |io, cond| socket_action(io, cond) }
    @_timer_block  = lambda { socket_action }

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

  # The loop this session drives through: whatever URL.default_loop was the
  # first time this session needed one, pinned for the session's life (a
  # long-lived session, e.g. URL.shared, doesn't want its in-flight fd/timer
  # registrations silently migrating to a different loop instance mid-flight).
  # Set explicitly to pin a specific session to a specific loop instead.
  def event_loop
    @event_loop ||= URL.default_loop
  end

  def event_loop=(loop)
    unless loop.nil? || loop.is_a?(EventLoop)
      raise TypeError, "expected a URL::EventLoop, got #{loop.class}"
    end
    @event_loop = loop
  end

  def setopt(opt, val)
    URL::Libcurl.multi_setopt(@multi, opt, val)
    self
  end

  # Session-wide default for Request#on_open_socket — the SSRF-style connect
  # filter. Every Request built against this session (every verb funnels
  # through Request#initialize, so this covers HTTP/mail/IMAP/... uniformly)
  # picks this up automatically unless the request sets its own, so a policy
  # set once here — e.g. URL.shared.on_open_socket { |addr, purpose| ... } —
  # can't be forgotten on an individual call the way a per-call option could.
  #
  # Call with a block to set it; call with no block to read the current
  # value back (Request#initialize needs exactly that to copy the default
  # onto each new handle).
  def on_open_socket(&block)
    if block
      @on_open_socket = block
      self
    else
      @on_open_socket
    end
  end

  # Attach `req` and kick off its first drive pass — nothing happens to a
  # newly-added easy until the multi is driven at least once. `on_done`, when
  # given, is called with the CURLcode once this transfer completes (from
  # inside socket_action's reap). With `remove_on_done: false` the easy
  # stays attached to the multi after completion instead of being removed —
  # a WebSocket's CONNECT_ONLY easy needs its connection to survive past the
  # handshake; the caller removes it explicitly (#remove) when done with it.
  def add(req, remove_on_done: true, &on_done)
    URL::Libcurl.multi_add(@multi, req.handle)   # C pins the easy as a GC root
    @by_easy[req.handle.object_id] = req
    @on_done[req.object_id] = on_done if on_done
    @keep_on_done[req.object_id] = true unless remove_on_done
    socket_action
    self
  end

  # Remove `req` from the multi — now, or deferred to the next socket_action
  # pass if a libcurl callback is currently on the C stack (removal is a
  # multi mutation like any other, forbidden mid-callback). Idempotent: a
  # no-op if `req` was never added or already removed (reaped normally, or
  # by an earlier call here), so callers never need to guard it themselves.
  def remove(req)
    return self unless @by_easy.key?(req.handle.object_id)
    if URL._in_c?
      @deferred_removes << req
    else
      URL::Libcurl.multi_remove(@multi, req.handle)  # C drops the GC root
      @by_easy.delete(req.handle.object_id)
      @on_done.delete(req.object_id)
      @keep_on_done.delete(req.object_id)
    end
    self
  end

  # Drive libcurl on a socket event (or a timeout when called with no args),
  # reap and dispatch whatever completed, then replay the resulting
  # socket/timer changes to the event loop.
  #
  # libcurl can ask to be called again immediately by reporting a zero
  # timeout; we drain that here (loop while the taken timeout is 0) before
  # reaping. Any exception a write/header/read callback stashed surfaces out
  # of multi_socket_action, so reaping below is skipped while one is pending
  # and the buffered events carry over to the next call — exactly as before.
  def socket_action(fd = URL::Libcurl::SOCKET_TIMEOUT, ev = nil)
    fd = fd.fileno if fd.respond_to?(:fileno)
    _flush_deferred_removes

    @timer_fired     = false
    @pending_timeout = nil
    running = nil
    URL._with_c_frame do
      running = URL::Libcurl.multi_socket_action(@multi, fd, ev)
      timeout = @pending_timeout

      drain_limit = 64
      while timeout == 0 && drain_limit > 0
        drain_limit -= 1
        @pending_timeout = nil
        running = URL::Libcurl.multi_socket_action(@multi, URL::Libcurl::SOCKET_TIMEOUT, nil)
        timeout = @pending_timeout
      end
    end

    # Arm/cancel the loop's timer from what libcurl reported: no callback
    # leaves any existing timer alone, nil cancels, a positive duration
    # re-arms.
    if @timer_fired
      loop = event_loop
      if @_timer_handle
        loop.cancel_timer(@_timer_handle)
        @_timer_handle = nil
      end
      @_timer_handle = loop.arm_timer(@pending_timeout, &@_timer_block) if @pending_timeout && @pending_timeout > 0
    end

    _reap
    running
  end

  # Yield one [request, result_code] pair per completed transfer. The C
  # primitive reports completions as [easy, code]; map each easy back to the
  # owning URL::Request so callers see the same objects they added. Used by
  # #_reap; public in case a caller ever needs to drain completions without
  # the on_done dispatch (none currently does — every drive path in the gem
  # goes through #add's on_done, including the in-C-callback fallback, which
  # just uses its own throwaway session and loop).
  def info_read
    while (pair = URL::Libcurl.multi_info_read(@multi))
      req = @by_easy[pair[0].object_id]
      yield req, pair[1] if req
    end
    self
  end

  private

  def _flush_deferred_removes
    return if @deferred_removes.empty?
    pending = @deferred_removes
    @deferred_removes = []
    pending.each { |req| remove(req) }
  end

  # Reap every completion off the multi and fire its registered on_done
  # block, if any. A normal transfer has already left the multi (and its GC
  # root) by the time the block runs, so a handler may freely re-register
  # (retry) or drive further without mutating tables mid-reap. A
  # remove_on_done: false easy (a websocket's CONNECT_ONLY handshake) stays
  # attached — only the completion bookkeeping is cleared; #remove is the
  # caller's job once it's actually done with the connection.
  def _reap
    info_read do |req, code|
      cb = @on_done.delete(req.object_id)   # fetch before remove clears it
      remove(req) unless @keep_on_done.delete(req.object_id)
      cb&.call(code)
    end
  end
end
