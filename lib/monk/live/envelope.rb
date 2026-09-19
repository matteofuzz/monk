require "json"

module Monk
  module Live
    # The server -> client wire shape (PLAN-LIVE.md "Wire protocol"): a
    # `patch` (one DOM operation: a CSS target, a mode, some html) or a
    # `batch` of them. Built as frozen Hashes and encoded to one frozen JSON
    # String, so a publisher can hand the same object to every subscriber
    # (ADR 0010). No `seq` here: it is per connection, so it can only be
    # stamped at the edge, where the connection writes the frame.
    module Envelope
      MODES = %i[morph replace append prepend remove].freeze

      def self.patch(target:, mode:, html: nil)
        check_target!(target)
        check_mode!(mode)
        if mode == :remove
          raise ArgumentError, "a remove patch carries no html" if html
        elsif html.nil?
          raise ArgumentError, "a #{mode} patch needs html"
        end

        envelope = { "op" => "patch", "target" => target, "mode" => mode.to_s }
        envelope["html"] = html if html
        envelope.freeze
      end

      def self.batch(ops)
        raise ArgumentError, "a batch needs at least one op" if ops.empty?

        { "op" => "batch", "ops" => ops.dup.freeze }.freeze
      end

      def self.encode(envelope)
        JSON.generate(envelope).freeze
      end

      def self.check_mode!(mode)
        return if MODES.include?(mode)

        raise ArgumentError, "unknown mode #{mode.inspect} (known: #{MODES.inspect})"
      end

      def self.check_target!(target)
        return if target.is_a?(String) && !target.strip.empty?

        raise ArgumentError, "target must be a non-blank CSS selector String, got #{target.inspect}"
      end
    end
  end
end
