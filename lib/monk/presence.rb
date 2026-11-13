require_relative "errors"
require_relative "log"
require_relative "presence/store"
require_relative "presence/counts"
require_relative "presence/tracker"
require_relative "presence/reactor"

module Monk
  # Whether a person is online, from the WebSocket processes' sockets
  # (docs/adr/0019-presence-per-process-rows-in-postgres-settled-once-per-transition.md).
  # Opt-in: require "monk/presence". Only Monk::Auth subjects are tracked.
  #
  #   Monk::Presence.configure(db_name: :primary)
  #   Monk::Presence.status(["user:1", "user:2"])
  #   # => {"user:1" => {status: :online, last_seen_at: nil},
  #   #     "user:2" => {status: :offline, last_seen_at: 2026-11-13 10:02:11 UTC}}
  #   Monk::Presence.on_change(&AppPresence::CHANGED) # bin/server reacts
  #
  # :online is a page open and visible, :away only hidden ones, :offline
  # none, after the grace (20 s by default): a phone switching networks or
  # a deploy reconnecting every page doesn't read as going offline.
  module Presence
    class NotConfiguredError < StandardError
    end

    DEFAULT_GRACE = 20
    PROCESS_TIMEOUT = 30
    # Seconds a web process's reactor waits before trying again for the
    # lock, or after losing its connection.
    REACTOR_RETRY = 5

    class << self
      # The status of each of subjects, from any process, in one query.
      # last_seen_at is when an offline subject was last online or away
      # (nil if never, or if not offline).
      def status(subjects)
        store.status(Array(subjects).map(&:to_s))
      end

      def online?(subject)
        status([subject]).fetch(subject.to_s)[:status] == :online
      end

      # grace: seconds a subject stays as it was after its last socket
      # closed, before it counts as offline.
      def configure(db_name:, grace: DEFAULT_GRACE)
        unless grace.is_a?(Numeric) && grace >= 0
          raise ArgumentError, "grace must be a number of seconds, 0 or more, got #{grace.inspect}"
        end

        @store = Ractor.make_shareable(Store.new(db_name: db_name, grace: grace, process_timeout: PROCESS_TIMEOUT))
      end

      def configured? = !@store.nil?

      # Called in bin/server with the subjects whose status changed, as
      # #status returns them: {subject => {status:, last_seen_at:}}. At
      # most once per change: a change signalled while no web process
      # listens is missed, and a page catches up on its next resync. The
      # block runs in the reactor's own Ractor, so it must be shareable:
      # build it in a module, as Monk::Live.authorize rules are. An error
      # in it is logged.
      #
      # Set in config/presence.rb, which the WebSocket processes load too:
      # with an on_change, they signal each change.
      def on_change(&block)
        raise ArgumentError, "on_change needs a block: { |changes| ... }" unless block

        @on_change = shareable(block)
      end

      # In a WebSocket process: starts counting its sockets and the tick
      # that writes them, signalling changes when there's an on_change.
      # Returns the counts, for Server.new(presence:). start_visible: false
      # for Live, whose sockets count as hidden until their page's first
      # ping.
      def start!(start_visible:)
        counts = Counts.new(start_visible: start_visible)
        @tracker = Tracker.new(store: store, counts: counts, notify: !@on_change.nil?).start.run
        counts
      end

      # In bin/server, after Monk.boot: starts the reactor that calls
      # on_change. Nil, and nothing started, without an on_change.
      def start_reactor!(retry_interval: REACTOR_RETRY)
        return unless @on_change

        return @reactor if @reactor

        @reactor = Reactor.start(Monk::Persistence::Pg.connection_options(store.db_name), @on_change,
          retry_interval: retry_interval,)
      end

      def stop_reactor!
        Reactor.stop(@reactor) if @reactor
        @reactor = nil
      end

      # On TERM: this process's subjects count for the grace while its
      # pages reconnect elsewhere.
      def stop!
        @tracker&.stop
        @tracker = nil
      end

      # Raises unless configured.
      def store
        @store || raise(NotConfiguredError, "Monk::Presence isn't configured -- call Monk::Presence.configure first")
      end

      def shareable(block)
        Ractor.make_shareable(block)
      rescue ArgumentError, Ractor::IsolationError => e
        raise Monk::UnshareableBlockError,
          "Monk::Presence.on_change block is not Ractor-shareable: #{e.message} " \
          "(build it where self is shareable, e.g. in a module body)"
      end
      private :shareable

      # Tests only.
      def reset!
        stop!
        stop_reactor!
        @store = nil
        @on_change = nil
      end
    end
  end
end
