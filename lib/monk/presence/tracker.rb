require "socket"

module Monk
  module Presence
    # A WebSocket process's presence tick, once a second on a thread of the
    # main Ractor (ADR 0019): take what changed from the counts, write it
    # as this process's rows, and settle transitions, signalling them with
    # notify: for bin/server's reactor. The heartbeat rides the same tick.
    # No app code runs here.
    #
    # Errors are logged and never end the process. A tick that failed may
    # have lost the counts' changes it took, so the next one writes this
    # process's whole state again instead.
    class Tracker
      TICK = 1
      HEARTBEAT_INTERVAL = 5
      RECONCILE_INTERVAL = 60

      attr_reader :process_id

      def initialize(store:, counts:, notify: false, hostname: Socket.gethostname, pid: Process.pid)
        @store = store
        @counts = counts
        @notify = notify
        @hostname = hostname
        @pid = pid
        @rewrite = false
      end

      # Registers this process. Raises if the database can't be reached,
      # so a WS process with presence fails at boot, not silently.
      def start
        @process_id = @store.register_process(hostname: @hostname, pid: @pid)
        @last_heartbeat = @last_reconcile = monotonic
        self
      end

      def run
        @thread = Thread.new do
          loop do
            sleep TICK
            tick
          end
        end
        self
      end

      # A stop (TERM): this process's rows count for the grace, while its
      # pages reconnect to another process, so a deploy changes nobody's
      # status.
      def stop
        @thread&.kill
        @store.mark_all_gone(@process_id) if @process_id
      rescue StandardError => e
        Monk::Log.error("Monk::Presence: couldn't mark this process's rows gone: #{describe(e)}")
      end

      # Returns the transitions this tick settled (none after an error).
      def tick
        heartbeat if @rewrite || monotonic - @last_heartbeat >= HEARTBEAT_INTERVAL
        subjects = @rewrite ? rewrite : flush
        @rewrite = false
        settle(subjects)
      rescue StandardError => e
        @rewrite = true
        Monk::Log.error("Monk::Presence: tick failed, writing all of this process's rows next time: #{describe(e)}")
        []
      end

      # The next tick heartbeats whatever the interval: for tests.
      def heartbeat_now!
        @last_heartbeat = -Float::INFINITY
      end

      private

      def heartbeat
        @rewrite = true if @store.heartbeat(@process_id, hostname: @hostname, pid: @pid)
        @last_heartbeat = monotonic
      end

      def flush
        diff = @counts.take
        return [] if diff.values.all?(&:empty?)

        @store.flush(@process_id, **diff)
        diff.values.flatten
      end

      # take before all: a change between the two is in all's state and
      # still marked changed, so the next take writes it again, harmlessly.
      def rewrite
        diff = @counts.take
        state = @counts.all
        @store.rewrite(@process_id, **state)
        (state.values + [diff[:gone]]).flatten.uniq
      end

      def settle(subjects)
        reconcile = monotonic - @last_reconcile >= RECONCILE_INTERVAL
        transitions = @store.settle(subjects, reconcile: reconcile, notify: @notify)
        @last_reconcile = monotonic if reconcile
        transitions
      end

      def describe(error) = "#{error.class}: #{error.message.lines.first&.chomp}"

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
