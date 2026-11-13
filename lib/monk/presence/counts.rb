module Monk
  module Presence
    # One WebSocket process's sockets, per subject (ADR 0019, "Counting, no
    # query per connect"): a Ractor holding them, told by each socket's own
    # Ractor when it opens, closes, or turns visible or hidden, with a
    # send, never an ask, so a connect never waits on it. The flusher reads
    # what changed with #take, once a second.
    #
    # A socket is reported under a key of its own (Server.serve uses its
    # connection's Ractor), so a late or repeated report changes nothing.
    # start_visible: is what an opened socket counts as until told: true
    # for app/sockets clients, which have no Away; false for Live, whose
    # client pings at once when its page is visible.
    class Counts
      def initialize(start_visible:)
        @ractor = Ractor.new(start_visible) { |visible_at_open| Counts.run(visible_at_open) }
        freeze
      end

      # The Ractor's loop. sockets: key => [subject, visible];
      # subjects: subject => [open sockets, visible sockets]; changed:
      # subjects to report at the next take.
      def self.run(visible_at_open)
        sockets = {}
        subjects = Hash.new { |h, k| h[k] = [0, 0] }
        changed = {}
        loop do
          op, key, arg = Ractor.receive
          case op
          when :open
            next if sockets.key?(key)

            sockets[key] = [arg, visible_at_open]
            counts = subjects[arg]
            counts[0] += 1
            counts[1] += 1 if visible_at_open
            changed[arg] = true
          when :close
            subject, visible = sockets.delete(key)
            next unless subject

            counts = subjects[subject]
            counts[0] -= 1
            counts[1] -= 1 if visible
            changed[subject] = true
          when :visible
            socket = sockets[key]
            next if socket.nil? || socket[1] == arg

            socket[1] = arg
            subjects[socket[0]][1] += arg ? 1 : -1
            changed[socket[0]] = true
          when :take
            arg.send(take(subjects, changed))
          when :all
            arg.send(all(subjects))
          end
        end
      end

      def self.take(subjects, changed)
        result = { online: [], away: [], gone: [] }
        changed.each_key do |subject|
          open, visible = subjects[subject]
          if open.zero?
            subjects.delete(subject)
            result[:gone] << subject
          else
            result[visible.positive? ? :online : :away] << subject
          end
        end
        changed.clear
        Ractor.make_shareable(result)
      end

      def self.all(subjects)
        result = { online: [], away: [] }
        subjects.each do |subject, (open, visible)|
          result[visible.positive? ? :online : :away] << subject if open.positive?
        end
        Ractor.make_shareable(result)
      end

      def open(key, subject) = tell(:open, key, subject)

      def close(key) = tell(:close, key, nil)

      def visible(key, visible) = tell(:visible, key, visible)

      # {online:, away:, gone:}: the subjects that changed since the last
      # take, by where they are now. A subject can open and close between
      # two takes and be reported gone without ever having been reported.
      def take = ask(:take)

      # {online:, away:}: every subject with a socket, for writing this
      # process's rows again from scratch.
      def all = ask(:all)

      private

      def tell(message, key, arg)
        @ractor.send([message, key, arg])
        nil
      rescue Ractor::ClosedError
        # The process is stopping: nothing left to count for.
        nil
      end

      def ask(message)
        port = Ractor::Port.new
        @ractor.send([message, nil, port])
        port.receive
      ensure
        port&.close
      end
    end
  end
end
