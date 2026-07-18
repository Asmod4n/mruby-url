# mrblib/url/reactor.rb
#
# URL::Reactor — the one event loop everything in this gem runs through.
#
# Internal machinery: there is no public accessor, no public run method and no
# run_until. Every blocking-looking call (a verb, WebSocket#receive/#send, a
# retry pause) registers a completion block here and pumps until its own block
# has fired — so while any one call waits, every other registered transfer,
# websocket and deadline keeps progressing through the same loop. Async code
# looks sync; nothing else in the gem waits on its own.
#
# What it owns:
#   * in-flight transfers  — easy => completion block, reaped via info_read
#   * websocket watches    — every open ws socket rides each wait as an extra
#                            poll fd and is serviced (frames drained, PINGs
#                            answered) whenever the loop wakes, so a long
#                            parallel batch can no longer starve a socket
#   * kept easies          — completed CONNECT_ONLY handles that must stay
#                            attached to their multi (removal is what kills a
#                            ws connection); they detach when the socket closes
#   * the wait itself      — one curl_multi_poll per iteration on the driven
#                            session's multi (its fds + libcurl's own next
#                            timeout) with the ws fds as extras; a bare multi
#                            stands in when nothing is in flight
#
# The one exception, inherited from libcurl's rules: a call made from inside a
# C-invoked callback (a user's streaming block runs under curl_multi_perform)
# must not re-enter a multi, so it cannot pump this loop. Those calls fall
# back to `isolated_drive` — a contained perform/poll loop on a throwaway
# session — preserving the same observable behaviour the gem always had.
# `_in_c?` is how dispatch tells the two situations apart, and every multi
# mutation in here routes through `_remove`, which defers itself when a C
# frame is live above us.

class URL::Reactor
  # Ceiling for one wait. curl_multi_poll returns earlier on socket activity
  # or when libcurl's next internal timeout is nearer, so this only bounds how
  # long a spurious idle wait could last.
  POLL_INTERVAL = 1.s

  def initialize
    @transfers  = {}   # req.object_id => { session:, on_done:, keep: }
    @kept       = {}   # req.object_id => session — done CONNECT_ONLY easies
    @ws_watches = {}   # fd => URL::WebSocket, serviced on every wake
    @extras     = []   # cached [fd, :in] pairs mirroring @ws_watches
    @performed  = {}   # scratch: sessions already driven this pass
    @detaches   = []   # [session, req] removals deferred out of C frames
    @in_c       = 0    # depth of C frames live above us (curl_multi_perform)
    @wait_multi = nil  # bare multi: the portable sleep when nothing is driven
  end

  # --- registration ---------------------------------------------------------

  # Attach `req` to `session` and remember the completion block. The reactor
  # removes the easy from the multi the moment it completes, *then* fires the
  # block — so a block may freely re-register (retry) or pump re-entrantly.
  # With `remove_on_done: false` the easy stays attached after completion and
  # is remembered in @kept until #detach releases it.
  def add_transfer(session, req, remove_on_done: true, &on_done)
    session.add(req)
    @transfers[req.object_id] =
      { session: session, on_done: on_done, keep: !remove_on_done }
    req
  end

  # Register a transfer, pump until it completes, and return its CURLcode —
  # the whole lifecycle of one blocking drive, including the abandon-on-unwind
  # safety net for exceptions crossing the pump.
  def drive_one(session, req, remove_on_done: true)
    code = nil
    add_transfer(session, req, remove_on_done: remove_on_done) { |_r, c| code = c }
    begin
      pump_until { code }
    ensure
      abandon(req) unless code
    end
    code
  end

  # Forget a transfer that will not be waited on any further (an exception
  # unwound past its pump). No-op if it already completed.
  def abandon(req)
    t = @transfers.delete(req.object_id)
    _remove(t[:session], req) if t
    nil
  end

  # Remember a completed easy that must stay attached to `session`'s multi
  # (the isolated ws-connect path registers here; the reactor path lands in
  # @kept via add_transfer's remove_on_done: false).
  def keep(session, req)
    @kept[req.object_id] = session
    nil
  end

  # Release a kept easy — the CONNECT_ONLY handle leaves its multi now that
  # its socket is done. No-op unless `req` was kept.
  def detach(req)
    session = @kept.delete(req.object_id)
    _remove(session, req) if session
    nil
  end

  def watch_ws(fd, ws)
    @ws_watches[fd] = ws
    @extras << [fd, :in]
    nil
  end

  def unwatch_ws(fd)
    @ws_watches.delete(fd)
    @extras.delete_if { |pair| pair[0] == fd }
    nil
  end

  # True while a libcurl C frame is live above us — i.e. we are inside a
  # write/header/read callback fired by curl_multi_perform. Pumping is
  # forbidden there (a multi must not be re-entered from its own callbacks).
  def _in_c?
    @in_c > 0
  end

  # --- pumping ----------------------------------------------------------------

  # Drive everything until the caller's condition holds (or `deadline`, a
  # Chrono::Steady instant, passes).
  def pump_until(deadline: nil)
    loop do
      _drive_and_reap
      _service_ws
      return if yield
      return if deadline && Chrono::Steady.now >= deadline
      _poll(deadline, nil, nil)
    end
  end

  # Pump for `duration` — the loop's replacement for sleeping: every other
  # registered transfer and websocket keeps moving while the caller pauses.
  # From inside a C-invoked callback nothing can be driven, so the pause
  # degrades to libcurl's plain portable sleep on the bare multi.
  def sleep(duration)
    deadline = Chrono::Steady.now + duration
    if _in_c?
      loop do
        remaining = deadline - Chrono::Steady.now
        break if remaining <= 0
        URL::Libcurl.multi_poll(_wait_multi, remaining)
      end
    else
      pump_until(deadline: deadline) { false }
    end
    nil
  end

  # One bounded wait for readiness on `fd`, driving everything else meanwhile.
  # From inside a C-invoked callback the sessions cannot be re-entered, so the
  # wait degrades to a plain poll on the bare multi — exactly the private wait
  # URL::WebSocket used to own, now shared.
  def wait_fd(fd, ev, deadline = nil)
    timeout = _timeout_for(deadline)
    return nil unless timeout
    if _in_c?
      URL::Libcurl.multi_poll_fds(_wait_multi, timeout, [[fd, ev]])
    else
      _drive_and_reap
      _service_ws
      _poll(deadline, fd, ev)
    end
    nil
  end

  # The contained fallback drive for calls made from inside a C-invoked
  # callback: a plain perform/reap/poll loop on `session` (always a throwaway
  # one), yielding [req, code] per completion until `count` transfers land.
  # This is the one loop in the gem beside pump_until, and it exists because
  # libcurl forbids re-entering a multi from its own callbacks — the reactor
  # cannot be pumped there.
  def isolated_drive(session, count)
    pending = count
    loop do
      running = _perform(session)
      session.info_read do |req, code|
        pending -= 1
        yield req, code
      end
      break if pending <= 0
      break if running == 0   # nothing in flight can complete the wait
      session.poll(POLL_INTERVAL)
    end
    nil
  end

  private

  # curl_multi_perform with the in-C depth counter held — the invariant every
  # `_in_c?` decision in the gem rests on. All perform calls go through here.
  def _perform(session)
    @in_c += 1
    session.perform
  ensure
    @in_c -= 1
  end

  # Remove an easy from its multi — now, in a pure-Ruby frame, or deferred to
  # the next drive pass when a C frame is live above us (removing an easy is
  # a multi re-entry like any other). Every removal in the reactor routes
  # through here, so no future path can re-enter by accident.
  def _remove(session, req)
    if _in_c?
      @detaches << [session, req]
    else
      session.remove(req) rescue nil
    end
    nil
  end

  # One drive pass: flush deferred removals, curl_multi_perform every session
  # that has reactor transfers, then reap completions. Completions are
  # buffered and fired *after* the drive so a completion block may add
  # transfers, retry, or pump re-entrantly without mutating the tables
  # mid-iteration. Each completed easy leaves its multi (or moves to @kept)
  # before its block runs.
  def _drive_and_reap
    until @detaches.empty?
      pair = @detaches.shift
      pair[0].remove(pair[1]) rescue nil
    end
    return if @transfers.empty?

    completions = nil
    @performed.clear
    @transfers.each_value do |t|
      session = t[:session]
      next if @performed[session.object_id]
      @performed[session.object_id] = true
      _perform(session)
      session.info_read do |req, code|
        completions = [] unless completions
        completions << [req, code]
      end
    end
    return unless completions

    completions.each do |pair|
      req  = pair[0]
      code = pair[1]
      t = @transfers.delete(req.object_id)
      next unless t   # abandoned by a nested pump
      if t[:keep]
        @kept[req.object_id] = t[:session]
      else
        _remove(t[:session], req)
      end
      t[:on_done].call(req, code)
    end
    nil
  end

  # Give every open websocket a service pass: drain readable frames into its
  # inbox, answer PINGs, flush the pending PONG. ws_recv/ws_send never touch
  # a multi, so this is safe at any point in the loop. (`values` snapshots
  # the hash — a service pass may close a socket and unwatch it mid-walk.)
  def _service_ws
    return if @ws_watches.empty?
    @ws_watches.values.each { |ws| ws._service }
    nil
  end

  # The wait timeout for one poll: the time to `deadline` capped at
  # POLL_INTERVAL, POLL_INTERVAL alone without one, nil when already expired.
  def _timeout_for(deadline)
    return POLL_INTERVAL unless deadline
    remaining = deadline - Chrono::Steady.now
    return nil if remaining <= 0
    remaining < POLL_INTERVAL ? remaining : POLL_INTERVAL
  end

  # The one wait. Polls the driven session's multi — waking on its fds and
  # capping at libcurl's own next timeout — with every websocket fd (plus the
  # caller's extra) riding along as curl_waitfd extras. With several driven
  # sessions the first is polled and the rest are picked up by the next drive
  # pass; with none, the bare multi turns curl_multi_poll into a plain
  # portable sleep. The common no-websocket case allocates nothing.
  def _poll(deadline, fd, ev)
    timeout = _timeout_for(deadline)
    return nil unless timeout

    entry = nil
    @transfers.each_value { |t| entry = t; break }
    session = entry && entry[:session]

    # Nothing driven, nothing watched, no extra fd: a pure sleep — take the
    # whole remaining time in one poll instead of 1s slices.
    if session.nil? && @ws_watches.empty? && fd.nil?
      timeout = deadline - Chrono::Steady.now if deadline
      URL::Libcurl.multi_poll(_wait_multi, timeout) if timeout > 0
      return nil
    end

    # The caller's fd rides along unless the watch set already covers it.
    extra = nil
    if fd && !(ev == :in && @ws_watches.key?(fd))
      extra = [fd, ev]
      @extras.push(extra)
    end
    begin
      if session && @extras.empty?
        session.poll(timeout)
      elsif session
        session.poll_fds(timeout, @extras)
      else
        URL::Libcurl.multi_poll_fds(_wait_multi, timeout, @extras)
      end
    ensure
      @extras.pop if extra
    end
    nil
  end

  def _wait_multi
    @wait_multi ||= URL::Libcurl.multi_init
  end
end

class URL
  # Internal: the process' one reactor, created on first use. Not public API —
  # users never drive it; the blocking calls pump it for them, and
  # bring-your-own-loop integrations (URL.default_loop=) bypass it entirely.
  def self._reactor
    @_reactor ||= URL::Reactor.new
  end
end
