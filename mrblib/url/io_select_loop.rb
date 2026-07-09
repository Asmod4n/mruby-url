# mrblib/url/io_select_loop.rb
#
# URL::SyncDriver — the built-in blocking driver behind the synchronous verbs
# and URL.parallel_perform. It is NOT an EventLoop: it rides libcurl's
# event-less multi API (curl_multi_perform + curl_multi_poll), where libcurl
# tracks every fd and timeout internally. Nothing here watches sockets or
# arms timers — curl already knows how; Ruby only decides when to stop.
#
# URL::IOSelectLoop — a reference EventLoop implementation kept as the
# example for platform-loop integrators. It implements ONLY the four
# EventLoop primitives, using nothing but the blocks the session hands it —
# exactly what any real integration (libuv, EventMachine, a game loop) has
# to provide, no more.

class URL::SyncDriver
  # Cap for one poll. curl_multi_poll returns earlier on socket activity or
  # when libcurl's own next timeout is nearer, so this is a ceiling, not a
  # latency — it only bounds how long a spurious idle wait could last.
  POLL_MS = 1000

  def initialize(session)
    @session = session
  end

  # Drive until `target` completes (or nothing is left running). Yields
  # [request, code] per completion, each the moment it is reaped.
  def run_until(target, &on_complete)
    finished = false
    _pump(-> { finished }) do |req, code|
      finished = true if req.equal?(target)
      on_complete&.call(req, code)
    end
  end

  # Drive until `count` transfers have completed — the basis for
  # URL.parallel_perform's "answers as they arrive".
  def run_n(count, &on_complete)
    remaining = count
    _pump(-> { remaining <= 0 }) do |req, code|
      remaining -= 1
      on_complete&.call(req, code)
    end
  end

  private

  # perform -> reap -> poll, until `stop` says done or curl runs dry. All
  # readiness/timeout knowledge stays inside libcurl.
  def _pump(stop, &on_complete)
    loop do
      running = @session.perform
      @session.info_read { |req, code| on_complete&.call(req, code) }
      break if stop.call
      break if running == 0   # nothing in flight can complete the stop condition
      @session.poll(POLL_MS)
    end
  end
end

# Example EventLoop: pumps IO.select over the fds the session asks it to
# watch and fires the session-provided blocks — the same two things any
# external loop integration does. The heavy lifting (socket_action, reaping,
# timeout bookkeeping) lives in the session; a loop only supplies readiness
# and timer callbacks.
class URL::IOSelectLoop < URL::EventLoop
  def initialize
    @watching   = {}   # fd => { io:, readiness:, block: }
    @timers     = {}   # handle => { ms:, block: } — one per arm_timer caller
    @next_timer = 0    # monotonically increasing timer handle
  end

  def watch(io, readiness, &block)
    fd = io.fileno
    @watching[fd] = { io: io, readiness: readiness, block: block }
    fd
  end

  def unwatch(handle)
    @watching.delete(handle)
  end

  def arm_timer(ms, &block)
    handle = (@next_timer += 1)
    @timers[handle] = { ms: ms, block: block }
    handle
  end

  def cancel_timer(handle)
    @timers.delete(handle)
  end

  # Pump until nothing is watched and no timer is armed. A real platform loop
  # wouldn't have this method — its own run loop plays this role.
  #
  # Timer precision is deliberately crude (this is the reference loop, not a
  # scheduler): the nearest timeout bounds the select, and when select expires
  # with no fd activity every armed timer fires. Firing a curl timer early is
  # harmless — its block just drives socket_action, which consults libcurl's
  # real timing state and re-arms as needed.
  def run
    until @watching.empty? && @timers.empty?
      reads  = []
      writes = []
      @watching.each_value do |w|
        reads  << w[:io] if w[:readiness] == :in  || w[:readiness] == :inout
        writes << w[:io] if w[:readiness] == :out || w[:readiness] == :inout
      end

      soonest = nil
      @timers.each_value do |t|
        soonest = t[:ms] if t[:ms] >= 0 && (soonest.nil? || t[:ms] < soonest)
      end
      sel_timeout = soonest ? soonest / 1000.0 : nil
      break if reads.empty? && writes.empty? && sel_timeout.nil?

      r, w, _e = IO.select(reads, writes, nil, sel_timeout)

      if r.nil? && w.nil?
        due = @timers
        @timers = {}
        due.each_value { |t| t[:block].call }
      else
        r&.each { |io| _fire(io, :in)  }
        w&.each { |io| _fire(io, :out) }
      end
    end
  end

  private

  def _fire(io, cond)
    w = @watching[io.fileno]
    w[:block].call(io, cond) if w && w[:block]
  end
end
