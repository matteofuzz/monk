require "fileutils"

require_relative "freeze_hooks"
require_relative "environment"

module Monk
  # One line per request, appended to log/<env>.log -- log/development.log,
  # log/test.log, log/production.log, log/staging.log, Rails-style. Runs
  # alongside Base#log_request's $stdout line, not instead of it: stdout
  # stays development-only (a human tailing a dev console), but the file
  # is unconditional -- every environment gets one, including production
  # and test.
  #
  # A File isn't Ractor-shareable the way $stdout is: Ruby special-cases
  # $stdout/$stderr/$stdin for cross-Ractor use, but a File this module
  # opens itself gets no such treatment. So unlike Assets' one frozen
  # manifest every worker reads, there's no single handle every worker can
  # share, and a class ivar won't do either -- routes freezes solid at
  # Boot, and a plain File isn't shareable enough to freeze into one.
  # Instead, each worker Ractor opens its own append-mode handle to the
  # same path, lazily, on its first write, and keeps it for the rest of
  # its life in Ractor-local storage. Concurrent O_APPEND writers to the
  # same path need no extra locking -- the same guarantee #log_request
  # already relies on for several worker Ractors sharing $stdout.
  module Log
    DEFAULT_ROOT = "log".freeze

    class << self
      attr_reader :root
      attr_writer :root

      # Called from Base#freeze! via Monk.freeze_hooks, the same seam
      # Assets/Settings use. Creates log/ once, in the main Ractor, and
      # freezes the path a worker will later append to -- unfrozen, a
      # worker reading it back would raise Ractor::IsolationError before
      # ever opening a handle.
      def freeze_registry!
        FileUtils.mkdir_p(root)
        @path = File.join(root, "#{Monk.env}.log").freeze
      end

      # Test-only. Also drops *this* Ractor's memoized handle -- tests
      # all run in the main Ractor, so without this a second #with_log
      # in the same process would keep writing into the first one's
      # (by then torn-down) tmpdir instead of picking up the new @path.
      def reset!
        @root = DEFAULT_ROOT
        @path = nil
        if (handle = Ractor.current[:monk_log_handle])
          handle.close
          Ractor.current[:monk_log_handle] = nil
        end
      end

      def write(line)
        handle.write(line)
        handle.flush
      end

      private

      def handle
        Ractor.current[:monk_log_handle] ||= File.open(@path, "a")
      end
    end

    @root = DEFAULT_ROOT

    Monk.freeze_hooks << self
  end
end
