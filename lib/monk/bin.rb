module Monk
  # What a scaffolded app's bin/ scripts run their work in:
  #
  #   Monk::Bin.run(__FILE__) do
  #     require_relative "../config/persistence"
  #     ...
  #   end
  #
  # An unreachable Postgres or Redis, a missing database, refused
  # credentials or an unset setting end the script with what failed, which
  # setting decides it, and the commands that fix it (the same as SETUP.md),
  # on stderr, exit 1 -- not a backtrace. Anything else is re-raised as it
  # is. Errors are recognized by class name, so this file loads neither pg
  # nor redis (docs/adr/0017).
  module Bin
    class << self
      def run(script)
        yield
      rescue StandardError => e
        message = explain(e, script)
        raise unless message

        # Not warn: it prints nothing when $VERBOSE is nil (ruby -W0), and
        # this message is the whole point of the failure.
        $stderr.puts message # rubocop:disable Style/StderrPuts
        exit 1
      end

      # The explanation for an error, or nil when it's not one of the above.
      def explain(error, script)
        context = Context.for(script)

        case error.class.name
        when "PG::ConnectionBad" then postgres(error, context)
        when "Redis::CannotConnectError" then redis(context)
        when "Monk::WebSocket::ListenError" then fanout(error, context)
        when "Monk::MissingSettingError" then missing_setting(error.message[/ENV\["([^"]+)"\]/, 1], context)
        when "KeyError" then missing_setting(error.key, context) if error.receiver.equal?(ENV)
        end
      end

      private

      def postgres(error, context)
        host = error.message[/server at "([^"]+)"/, 1] || ENV.fetch("DB_HOST", "127.0.0.1")
        port = error.message[/port (\d+)/, 1] || ENV.fetch("DB_PORT", "5432")
        at = "Postgres at #{host}:#{port}"

        if (database = error.message[/database "([^"]+)" does not exist/, 1])
          context.message("database \"#{database}\" doesn't exist on #{at} (DB_NAME in .env).",
            "Create it (it asks for DB_PASSWORD), then run #{context.name} again -- SETUP.md:",
            "createdb -h #{host} -p #{port} -U #{ENV.fetch("DB_USER", "postgres")} #{database}",)
        elsif (user = error.message[/authentication failed for user "([^"]+)"/, 1])
          context.message("#{at} refused user \"#{user}\" (DB_USER/DB_PASSWORD in .env).",
            "Check them, then run #{context.name} again.",)
        elsif error.message.include?("Connection refused")
          context.message("can't connect to #{at} (DB_HOST/DB_PORT in .env).",
            "Start it, then run #{context.name} again -- SETUP.md:",
            "docker run --rm -d -p #{port}:5432 -e POSTGRES_PASSWORD=postgres --name #{context.app}_pg postgres:16",)
        else
          context.message("can't connect to #{at} (DB_* in .env): #{error.message.lines.first.strip}")
        end
      end

      # The WS process's subscriber connection, opened by listen! at boot.
      def fanout(error, context)
        if error.message.include?("RedisFanout")
          redis(context)
        elsif error.message.include?("PgFanout")
          postgres(error, context)
        end
      end

      def redis(context)
        url = ENV.fetch("REDIS_URL", "redis://localhost:6379/0")
        port = url[%r{//[^/]*:(\d+)}, 1] || "6379"
        shown = url.sub(%r{//([^@/]*):[^@/]*@}, '//\1:***@') # never the password
        context.message("can't connect to Redis at #{shown} (REDIS_URL in .env).",
          "Start it, then run #{context.name} again -- SETUP.md:",
          "docker run --rm -d -p #{port}:6379 --name #{context.app}_redis redis:7",)
      end

      def missing_setting(name, context)
        return unless name

        context.message("#{name} is not set.",
          "Set it in .env (development) or the environment, then run #{context.name} again.",)
      end
    end

    # The script being run: its name as typed from the app's root
    # (bin/setup_db), and the app's directory name, which SETUP.md's
    # container names use.
    Context = Data.define(:name, :app) do
      def self.for(script)
        path = File.expand_path(script)
        new(name: "bin/#{File.basename(path)}", app: File.basename(File.dirname(path, 2)))
      end

      # The first line says what failed; the next, what to do; the last,
      # if there's one, is the command to run.
      def message(what, todo = nil, command = nil)
        ["#{name}: #{what}", todo, ("  #{command}" if command)].compact.join("\n")
      end
    end
  end
end
