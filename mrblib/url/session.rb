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
    @multi         = URL::Libcurl.multi_init
    @handles       = {}        # request.object_id => URL::Request (keeps it alive)
    @by_easy       = {}        # easy.object_id    => URL::Request (info_read map)
    @event_loop    = nil
    @_timer_handle = nil

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
    URL::Libcurl.multi_add(@multi, req.handle)
    @handles[req.object_id]         = req
    @by_easy[req.handle.object_id]  = req
    self
  end

  def remove(req)
    URL::Libcurl.multi_remove(@multi, req.handle)
    @handles.delete(req.object_id)
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

    running = URL::Libcurl.multi_socket_action(@multi, fd, ev)
    timeout = URL::Libcurl.multi_take_timeout(@multi)

    drain_limit = 64
    while timeout == 0 && drain_limit > 0
      drain_limit -= 1
      running = URL::Libcurl.multi_socket_action(@multi, URL::Libcurl::SOCKET_TIMEOUT, nil)
      timeout = URL::Libcurl.multi_take_timeout(@multi)
    end

    _flush_pending_sockets
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

  # Replay each recorded socket change to the event loop. URL#_socket_ready
  # (socket_glue.rb) owns the fd -> IO map and calls watch/unwatch.
  def _flush_pending_sockets
    events = URL::Libcurl.multi_take_events(@multi)
    return if events.empty?
    return if @event_loop.nil?

    events.each do |pair|
      _socket_ready(pair[0], pair[1])
    end
  end
  private :_flush_pending_sockets

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
