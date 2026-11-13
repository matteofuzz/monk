# A stand-alone web process's presence reactor, for
# test/presence_reactor_process_test.rb: what bin/server starts after
# Monk.boot, with a short retry so a takeover shows within a test. Its
# on_change records "pid subjects" into presence_reactor_results.
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "monk"
require "monk/presence"
require "monk/persistence/pg"

module PresenceReactorProcess
  DB = :presence_reactor_process_test_db

  RECORD = proc do |changes|
    Monk::Persistence::Pg.checkout(DB) do |conn|
      conn.exec_params("INSERT INTO presence_reactor_results (value) VALUES ($1)",
        ["#{Process.pid} #{changes.keys.sort.join(",")}"],)
    end
  end
end

Monk::Persistence::Pg.register(
  PresenceReactorProcess::DB,
  host: ENV.fetch("MONK_TEST_PG_HOST"),
  port: ENV.fetch("MONK_TEST_PG_PORT").to_i,
  user: ENV.fetch("MONK_TEST_PG_USER"),
  password: ENV.fetch("MONK_TEST_PG_PASSWORD"),
  dbname: ENV.fetch("MONK_TEST_PG_DATABASE"),
)
Monk::Presence.configure(db_name: PresenceReactorProcess::DB)
Monk::Presence.on_change(&PresenceReactorProcess::RECORD)
Monk.freeze!
Monk::Presence.start_reactor!(retry_interval: 0.2)
sleep
