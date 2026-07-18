# mrblib/url/io_select_loop.rb
#
# URL::IOSelectLoop — a reference EventLoop implementation kept as the
# example for platform-loop integrators. It implements ONLY the four
# EventLoop primitives, using nothing but the blocks the session hands it —
# exactly what any real integration (libuv, EventMachine, a game loop) has
# to provide, no more.
#
# The gem's own blocking drive does not live here: every synchronous call
# pumps the one internal URL::Reactor (mrblib/url/reactor.rb).

# Example EventLoop: pumps IO.select over the fds the session asks it to
# watch and fires the session-provided blocks — the same two things any
# external loop integration does. The heavy lifting (socket_action, reaping,
# timeout bookkeeping) lives in the session; a loop only supplies readiness
# and timer callbacks.
class URL::IOSelectLoop < URL::EventLoop
  def initialize
    @watching = {}    # fd => { io:, readiness:, block: }
    @timer    = nil   # { deadline:, block: }
  end

  def watch(io, readiness, &block)
    fd = io.fileno
    @watching[fd] = { io: io, readiness: readiness, block: block }
    fd
  end

  def unwatch(handle)
    @watching.delete(handle)
  end

  # `delay` is a chrono duration (500.ms, 2.s, …). Stored as a monotonic
  # deadline so a slow select round can't stretch the timer.
  def arm_timer(delay, &block)
    @timer = { deadline: Chrono::Steady.now + delay, block: block }
    :timer
  end

  def cancel_timer(_handle)
    @timer = nil
  end

  # Pump until nothing is watched and no timer is armed. A real platform loop
  # wouldn't have this method — its own run loop plays this role.
  def run
    until @watching.empty? && @timer.nil?
      reads  = []
      writes = []
      @watching.each_value do |w|
        reads  << w[:io] if w[:readiness] == :in  || w[:readiness] == :inout
        writes << w[:io] if w[:readiness] == :out || w[:readiness] == :inout
      end

      sel_timeout = @timer ? [@timer[:deadline] - Chrono::Steady.now, 0].max : nil
      break if reads.empty? && writes.empty? && sel_timeout.nil?

      r, w, _e = IO.select(reads, writes, nil, sel_timeout)

      if r.nil? && w.nil?
        t = @timer
        @timer = nil
        t[:block].call if t
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
