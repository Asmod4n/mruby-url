# mrblib/url/socket_glue.rb
#
# Ruby half of the event-loop integration. The C socket callback is store-only
# (it just records fd/readiness changes); after returning from libcurl the C
# side replays each change through #_socket_ready below. Keeping the fd -> IO
# map and the watch/unwatch bookkeeping here means the C side never builds IO
# objects, never pokes mruby-io internals, and never hands a Ruby object
# pointer back to libcurl. Internal plumbing.

class URL
  # Called once per recorded socket change. `what` is :in / :out / :inout, or
  # :remove. @_action_block is the C-provided proc the loop invokes when the
  # fd becomes ready; every EventLoop integration stores and later fires it.
  def _socket_ready(fd, what)
    sockets = (@sockets ||= {})

    loop = event_loop

    if what == :remove
      entry = sockets.delete(fd)
      loop.unwatch(entry[:handle]) if entry && entry[:handle]
      return
    end

    entry = sockets[fd]
    unless entry
      io = IO.for_fd(fd)
      io.autoclose = false           # libcurl owns this fd; never close it
      entry = sockets[fd] = { io: io, handle: nil, readiness: nil }
    end

    return if entry[:readiness] == what && entry[:handle]

    loop.unwatch(entry[:handle]) if entry[:handle]
    entry[:handle]    = loop.watch(entry[:io], what, &@_action_block)
    entry[:readiness] = what
    nil
  end
end
