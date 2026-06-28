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

  def self.strerror(code)
    URL::Libcurl.multi_strerror(code)
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
    @pending_timeout = nil

    # libcurl's socket/timer callbacks call straight back into these blocks (run
    # under mrb_protect_error in C). on_socket replays each fd change to the
    # event loop; on_timer records the timeout that socket_action's drain loop
    # and _flush_pending_timer consume — no C-side buffering.
    @multi.on_socket = lambda do |fd, what|
      _socket_ready(fd, what) if @event_loop
    end
    @multi.on_timer = lambda do |ms|
      @pending_timeout = ms
    end

    # The proc an event loop invokes when a watched fd becomes ready: drive the
    # transfer, reap completions, drop them from the multi. Mirrors the old C
    # action cfunc.
    @_action_block = lambda do |io, cond|
      socket_action(io, cond)
      _reap_done
      true
    end

    # The proc an event loop invokes when the armed timer fires (timeout case).
    # Mirrors the old C timer cfunc.
    @_timer_block = lambda do
      socket_action
      _reap_done
      false
    end

    self
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

    # on_socket fires _socket_ready during the call; on_timer records the new
    # timeout into @pending_timeout. libcurl can ask to be re-driven immediately
    # by reporting a 0ms timeout, so drain that here before arming the timer.
    @pending_timeout = nil
    running = URL::Libcurl.multi_socket_action(@multi, fd, ev)
    timeout = @pending_timeout

    drain_limit = 64
    while timeout == 0 && drain_limit > 0
      drain_limit -= 1
      @pending_timeout = nil
      running = URL::Libcurl.multi_socket_action(@multi, URL::Libcurl::SOCKET_TIMEOUT, nil)
      timeout = @pending_timeout
    end

    _flush_pending_timer(timeout)

    running
  end

  # Yield (or collect) one [request, result_code] pair per completed transfer.
  #
  # The C primitive reports completions as [easy, code]; map each easy back to
  # the owning URL::Request before handing it out, so callers see the same
  # objects they added.
  def info_read(&block)
    if block
      while (pair = URL::Libcurl.multi_info_read(@multi))
        req = @by_easy[pair[0].object_id]
        block.call(req, pair[1]) if req
      end
      self
    else
      done = []
      while (pair = URL::Libcurl.multi_info_read(@multi))
        req = @by_easy[pair[0].object_id]
        done << [req, pair[1]] if req
      end
      done
    end
  end

  # --- internal helpers (were C: flush_pending_*, action/timer cfuncs) -------

  # Reap completed transfers and drop them from the multi. Used by the
  # action/timer procs that drive a platform event loop.
  def _reap_done
    info_read.each do |pair|
      req = pair[0]
      begin
        remove(req)
      rescue StandardError
        # already gone / not attached
      end
    end
  end
  private :_reap_done

  # Arm/cancel the event loop's timer from the timeout libcurl reported.
  #   nil  -> unset: leave any existing timer alone
  #   <= 0 -> cancel only
  #   > 0  -> cancel the old timer and arm a fresh one
  def _flush_pending_timer(timeout_ms)
    return if timeout_ms.nil?
    return if @event_loop.nil?

    if @_timer_handle
      @event_loop.cancel_timer(@_timer_handle)
      @_timer_handle = nil
    end

    return if timeout_ms <= 0

    @_timer_handle = @event_loop.arm_timer(timeout_ms, &@_timer_block)
    nil
  end
  private :_flush_pending_timer
end
