module Monk
  module Persistence
    # Named connection pools for short-lived Ractors
    # (docs/history/plan-pg-pool.md). A PG::Connection can't be moved or
    # shared across Ractors, so a pool lends nothing: a few worker Ractors
    # own connections, and other Ractors send them calls to run.
    module Pool
      # A pool as declared with Registry#pool(name, ...). Frozen, so any
      # Ractor can read it once boot has frozen the registry.
      Config = Data.define(:name, :db, :size, :timeout, :queue)

      # What #pool fills in for options a declaration leaves out. timeout:
      # is the same 5 s as checkout's. queue: is how many calls may wait
      # for a worker before #call refuses more: 4 workers clear 1000 in
      # well under a second, so a full queue means a stalled database.
      DEFAULTS = { db: :primary, size: 4, timeout: 5, queue: 1000 }.freeze
    end
  end
end
