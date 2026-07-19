# mrblib/url/io_select_loop.rb
#
# URL::IOSelectLoop — the default URL::EventLoop, and the reference anyone
# writing their own reads. It implements the five EventLoop primitives using
# nothing but IO.select and the blocks the caller hands it; a real
# integration (a GUI toolkit's loop, an io_uring/kqueue wrapper) implements
# the same five however its own loop actually waits.
#
# It is not special-cased anywhere else in the gem. URL.default_loop is one
# of these until you set your own, and every verb, parallel batch, websocket
# and retry pause drives through whatever URL.default_loop currently is by
# calling run_once — this class has no extra internal-only capability that a
# real integration couldn't also provide.

class URL::IOSelectLoop < URL::EventLoop
  def initialize
    @watching   = {}   # fd => [ { handle:, io:, readiness:, block: }, … ]
    @timers     = {}   # handle => { deadline:, block: }
    @next_timer = 0
  end

  # A single Object identifies this registration across watch/unwatch even
  # though several callers may watch the same fd for different reasons at
  # once (a websocket watches :in for the life of the connection and, only
  # while a send is draining, briefly adds a second :out registration).
  def watch(io, readiness, &block)
    handle = Object.new
    (@watching[io.fileno] ||= []) << { handle: handle, io: io, readiness: readiness, block: block }
    handle
  end

  def unwatch(handle)
    @watching.each_value { |regs| regs.delete_if { |r| r[:handle] == handle } }
    @watching.delete_if { |_, regs| regs.empty? }
    nil
  end

  # `delay` is a chrono duration (500.ms, 2.s, …). Stored as a monotonic
  # deadline so a slow round can't stretch the timer.
  def arm_timer(delay, &block)
    handle = (@next_timer += 1)
    @timers[handle] = { deadline: Chrono::Steady.now + delay, block: block }
    handle
  end

  def cancel_timer(handle)
    @timers.delete(handle)
    nil
  end

  # One round: wait for a watched fd to become ready or a timer to expire,
  # then fire whatever's due. `timeout` (a chrono duration) caps the wait;
  # nil waits for the nearest armed timer (or forever with none watched and
  # none armed — a caller asking for that has a bug, so just return);
  # 0 polls without blocking. Returns true if anything fired, false if the
  # wait elapsed with nothing ready.
  def run_once(timeout = nil)
    reads  = []
    writes = []
    @watching.each_value do |regs|
      regs.each do |r|
        reads  << r[:io] if r[:readiness] == :in  || r[:readiness] == :inout
        writes << r[:io] if r[:readiness] == :out || r[:readiness] == :inout
      end
    end

    nearest = @timers.empty? ? nil : @timers.values.map { |t| t[:deadline] }.min
    wait    = _wait_for(timeout, nearest)
    return false if reads.empty? && writes.empty? && wait.nil?

    r, w, _e = IO.select(reads, writes, nil, wait)

    fired = false
    r&.each { |io| fired |= _fire_io(io, :in) }
    w&.each { |io| fired |= _fire_io(io, :out) }
    fired |= _fire_expired_timers
    fired
  end

  private

  def _wait_for(timeout, nearest_deadline)
    remaining = nearest_deadline && [nearest_deadline - Chrono::Steady.now, 0].max
    if timeout && remaining
      timeout < remaining ? timeout : remaining
    else
      timeout || remaining   # nil when neither is set
    end
  end

  def _fire_io(io, cond)
    regs = @watching[io.fileno]
    return false unless regs
    fired = false
    # Snapshot: a fired block may itself unwatch (even this fd), which would
    # otherwise mutate regs mid-each.
    regs.dup.each do |r|
      next unless r[:readiness] == cond || r[:readiness] == :inout
      r[:block].call(io, cond)
      fired = true
    end
    fired
  end

  def _fire_expired_timers
    return false if @timers.empty?
    now = Chrono::Steady.now
    due = @timers.select { |_, t| t[:deadline] <= now }
    return false if due.empty?
    due.each_key { |handle| @timers.delete(handle) }
    due.each_value { |t| t[:block].call }
    true
  end
end
