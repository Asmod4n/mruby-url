# mrblib/url/io_select_loop.rb
#
# URL::IOSelectLoop — the built-in EventLoop used for blocking requests when
# no platform loop is set. Pull-driven: pumps IO.select until the request of
# interest completes. Internal plumbing; users get it implicitly through the
# high-level verbs.

class URL::IOSelectLoop < URL::EventLoop
  def initialize(session)
    @session    = session
    @watching   = {}   # fd_int => { io:, readiness: }
    @timeout_ms = -1
  end

  def watch(io, readiness, &_block)
    fd = io.fileno
    @watching[fd] = { io: io, readiness: readiness }
    fd
  end

  def unwatch(handle)
    @watching.delete(handle)
  end

  def arm_timer(ms, &_block)
    @timeout_ms = ms
    :timer
  end

  def cancel_timer(_handle)
    @timeout_ms = -1
  end

  def run(&on_complete)
    @session.socket_action
    @session.info_read { |req, code| on_complete&.call(req, code) }

    until @watching.empty? && @timeout_ms < 0
      reads  = []
      writes = []
      @watching.each_value do |w|
        reads  << w[:io] if w[:readiness] == :in  || w[:readiness] == :inout
        writes << w[:io] if w[:readiness] == :out || w[:readiness] == :inout
      end

      sel_timeout = @timeout_ms < 0 ? nil : @timeout_ms / 1000.0
      r, w, _e = IO.select(reads, writes, nil, sel_timeout)

      if r.nil? && w.nil?
        @session.socket_action
      else
        r&.each { |io| @session.socket_action(io, :in)  }
        w&.each { |io| @session.socket_action(io, :out) }
      end

      @session.info_read { |req, code| on_complete&.call(req, code) }
    end
  end

  # Drive the session until `target` completes (or the loop falls idle),
  # rather than until every socket is gone. Required for the reused shared
  # session, whose kept-alive sockets can outlive any single request.
  def run_until(target, &on_complete)
    finished = false
    drain = lambda do |req, code|
      finished = true if req.equal?(target)
      on_complete.call(req, code) if on_complete
    end

    @session.socket_action
    @session.info_read(&drain)

    until finished
      reads  = []
      writes = []
      @watching.each_value do |w|
        reads  << w[:io] if w[:readiness] == :in  || w[:readiness] == :inout
        writes << w[:io] if w[:readiness] == :out || w[:readiness] == :inout
      end

      break if reads.empty? && writes.empty? && @timeout_ms < 0

      sel_timeout = @timeout_ms < 0 ? nil : @timeout_ms / 1000.0
      r, w, _e = IO.select(reads, writes, nil, sel_timeout)

      if r.nil? && w.nil?
        @session.socket_action
      else
        r&.each { |io| @session.socket_action(io, :in)  }
        w&.each { |io| @session.socket_action(io, :out) }
      end

      @session.info_read(&drain)
    end
  end
end
