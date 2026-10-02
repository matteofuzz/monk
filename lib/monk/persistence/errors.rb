module Monk
  class PersistenceTimeoutError < StandardError
  end

  class UnknownPersistenceError < StandardError
  end

  # Monk::Persistence::Pg.pool(name) for a pool never declared.
  class UnknownPoolError < StandardError
  end

  # Monk::Persistence::Pg.pool(name) for a pool declared but not started
  # in this process (start_pools!).
  class PoolNotStartedError < StandardError
  end

  # start_pools! couldn't connect a pool's workers.
  class PoolStartError < StandardError
  end
end
