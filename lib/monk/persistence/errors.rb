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

  # A pool call's method returned a value that can't be copied to the
  # caller's Ractor (a PG::Result, say).
  class PoolReturnError < StandardError
  end

  # A pool's queue is full: as many calls as its queue: option allows are
  # already waiting for a worker.
  class PoolFullError < StandardError
  end

  # start_pools! couldn't connect a pool's workers.
  class PoolStartError < StandardError
  end
end
