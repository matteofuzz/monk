# Monk::Auth::Sweep. Loaded at the end of whichever of monk/auth and
# monk/jobs is required second, once both are defined (docs/adr/0017), so
# it requires neither itself.

module Monk
  module Auth
    # Monk::Auth.sweep! as a job: deletes expired login tokens and sessions
    # and old login requests. config/recurring.rb (monk add jobs) runs it
    # nightly when auth is installed (docs/history/plan-auth-housekeeping.md
    # decision 1):
    #
    #   Monk::Jobs.recurring "monk_auth_sweep", Monk::Auth::Sweep, cron: "17 3 * * *" if defined?(Monk::Auth::Sweep)
    class Sweep < Monk::Job
      def self.perform
        counts = Monk::Auth.sweep!
        Monk::Log.info(
          "Monk::Auth::Sweep: deleted #{counts[:sessions]} sessions, #{counts[:login_tokens]} login tokens, " \
          "#{counts[:login_requests]} login requests",
        )
      end
    end
  end
end
