require "json"
require_relative "../log"
require_relative "../persistence/pg"

module Monk
  module Presence
    # One subject's change of status, as settling returned it: status is
    # :online, :away or :offline, last_seen_at a Time when :offline.
    Transition = Data.define(:subject, :status, :last_seen_at)

    # Presence's statements on Postgres: monk_presence_processes,
    # monk_presence and monk_presence_status
    # (docs/adr/0019-presence-per-process-rows-in-postgres-settled-once-per-transition.md).
    # Holds only settings and freezes itself, so one instance is shareable
    # with every Ractor; each Ractor reaches the database through its own
    # connection, via Monk::Persistence::Pg, as Monk::Jobs' adapter does.
    #
    # Every time is the database's now(), so hosts' clocks don't matter.
    class Store
      ARRAY = Ractor.make_shareable(PG::TextEncoder::Array.new)

      # Whether a row counts toward its subject's status: an open one
      # while its process heartbeats, a gone one for the grace after it
      # went, whatever its process does since (a stopping process's rows
      # carry its subjects through a deploy). A row whose process row is
      # gone counts only if it's inside the grace. $grace and $timeout are
      # replaced with each statement's own parameter numbers.
      COUNTING = <<~SQL.freeze
        CASE WHEN r.gone_at IS NULL
          THEN COALESCE(p.heartbeat_at >= now() - $timeout::float8 * interval '1 second', false)
          ELSE r.gone_at >= now() - $grace::float8 * interval '1 second'
        END
      SQL

      # The best of the counting rows: online over away, offline without.
      BEST = <<~SQL.freeze
        CASE WHEN bool_or(r.counting AND r.status = 'online') THEN 'online'
          WHEN bool_or(r.counting) THEN 'away'
          ELSE 'offline'
        END
      SQL

      REGISTER_PROCESS_SQL = <<~SQL.freeze
        INSERT INTO monk_presence_processes (hostname, pid) VALUES ($1, $2) RETURNING id
      SQL

      # An upsert, as Monk::Jobs': a process that stalled long enough to be
      # pruned gets its row back under the same id. Says whether it had to
      # (xmax is 0 on a freshly inserted row): its own rows went with it,
      # so it writes them all again.
      HEARTBEAT_SQL = <<~SQL.freeze
        INSERT INTO monk_presence_processes (id, hostname, pid) OVERRIDING SYSTEM VALUE VALUES ($1, $2, $3)
        ON CONFLICT (id) DO UPDATE SET heartbeat_at = now()
        RETURNING xmax = 0 AS restored
      SQL

      # One process's changes since its last flush, in one statement:
      # subjects with sockets ($2, their statuses in $3) upserted back to
      # open, subjects down to none ($4) marked gone. The lists never share
      # a subject.
      FLUSH_SQL = <<~SQL.freeze
        WITH open AS (
          INSERT INTO monk_presence (process_id, subject, status)
          SELECT $1, subject, status FROM unnest($2::text[], $3::text[]) AS u(subject, status)
          ON CONFLICT (process_id, subject) DO UPDATE SET status = excluded.status, gone_at = NULL
        )
        UPDATE monk_presence SET gone_at = now()
        WHERE process_id = $1 AND subject = ANY($4::text[]) AND gone_at IS NULL
      SQL

      # This process's rows written again from its whole state ($2, $3):
      # after an error lost a flush, or after its rows were pruned. A row
      # not in the state is marked gone, so a close the lost flush carried
      # isn't left open.
      REWRITE_SQL = <<~SQL.freeze
        WITH open AS (
          INSERT INTO monk_presence (process_id, subject, status)
          SELECT $1, subject, status FROM unnest($2::text[], $3::text[]) AS u(subject, status)
          ON CONFLICT (process_id, subject) DO UPDATE SET status = excluded.status, gone_at = NULL
        )
        UPDATE monk_presence SET gone_at = now()
        WHERE process_id = $1 AND gone_at IS NULL AND subject <> ALL($2::text[])
      SQL

      # A stopping process (TERM): its rows count for the grace instead of
      # vanishing, while its pages reconnect elsewhere.
      MARK_ALL_GONE_SQL = <<~SQL.freeze
        UPDATE monk_presence SET gone_at = now() WHERE process_id = $1 AND gone_at IS NULL
      SQL

      # last_seen_at: rows that stopped counting but aren't settled yet
      # (up to a tick) say it, as settling will; else the stored one.
      STATUS_SQL = <<~SQL.freeze
        WITH r AS (
          SELECT r.subject, r.status, r.gone_at, p.heartbeat_at,
            #{COUNTING.gsub("$timeout", "$3").gsub("$grace", "$2")} AS counting
          FROM monk_presence r LEFT JOIN monk_presence_processes p ON p.id = r.process_id
          WHERE r.subject = ANY($1::text[])
        )
        SELECT s.subject, #{BEST} AS status,
          extract(epoch FROM COALESCE(
            max(COALESCE(r.gone_at, r.heartbeat_at)) FILTER (WHERE NOT r.counting), st.last_seen_at
          ))::float8 AS last_seen_at
        FROM unnest($1::text[]) AS s(subject)
        LEFT JOIN r ON r.subject = s.subject
        LEFT JOIN monk_presence_status st ON st.subject = s.subject
        GROUP BY s.subject, st.last_seen_at
      SQL

      # The subjects given ($1), those with rows that stopped counting, and
      # with $4 every subject stored as not offline (the minute's full
      # reconcile), each settled into monk_presence_status where its status
      # changed; the expired rows and dead processes deleted, all in one
      # statement. The upsert's WHERE makes a second settling of the same
      # change find nothing to write, so each transition is returned once.
      # A subject never stored isn't stored as offline: there's nothing to
      # announce. Going offline, last seen is when its last rows stopped:
      # the latest gone_at, or a dead process's last heartbeat.
      SETTLE_SQL = <<~SQL.freeze
        WITH r AS (
          SELECT r.process_id, r.subject, r.status, r.gone_at, p.heartbeat_at,
            #{COUNTING.gsub("$timeout", "$3").gsub("$grace", "$2")} AS counting
          FROM monk_presence r LEFT JOIN monk_presence_processes p ON p.id = r.process_id
        ), candidates AS (
          SELECT unnest($1::text[]) AS subject
          UNION SELECT subject FROM r WHERE NOT counting
          UNION SELECT subject FROM monk_presence_status WHERE $4::boolean AND status <> 'offline'
        ), computed AS (
          SELECT c.subject, #{BEST} AS status,
            max(COALESCE(r.gone_at, r.heartbeat_at)) FILTER (WHERE NOT r.counting) AS last_seen_at
          FROM candidates c LEFT JOIN r ON r.subject = c.subject
          GROUP BY c.subject
        ), expired AS (
          DELETE FROM monk_presence m USING r
          WHERE NOT r.counting AND m.process_id = r.process_id AND m.subject = r.subject
        ), dead AS (
          DELETE FROM monk_presence_processes WHERE heartbeat_at < now() - $3::float8 * interval '1 second'
        )
        INSERT INTO monk_presence_status AS s (subject, status, changed_at, last_seen_at)
        SELECT c.subject, c.status, now(), CASE WHEN c.status = 'offline' THEN COALESCE(c.last_seen_at, now()) END
        FROM computed c
        WHERE c.status <> 'offline' OR EXISTS (SELECT 1 FROM monk_presence_status x WHERE x.subject = c.subject)
        ON CONFLICT (subject) DO UPDATE SET
          status = excluded.status, changed_at = excluded.changed_at,
          last_seen_at = COALESCE(excluded.last_seen_at, s.last_seen_at)
        WHERE s.status IS DISTINCT FROM excluded.status
        RETURNING s.subject, s.status,
          CASE WHEN s.status = 'offline' THEN extract(epoch FROM s.last_seen_at)::float8 END AS last_seen_at
      SQL

      # Settling processes take turns: each statement then sees what the
      # one before it committed, so two can't settle one subject from
      # snapshots taken before each other's flush.
      SETTLE_LOCK_SQL = "SELECT pg_advisory_xact_lock(hashtext('monk_presence_settle'))".freeze

      # The channel bin/server's reactor LISTENs on (Reactor). A payload is
      # a JSON array of subjects, under Postgres's 8000-byte NOTIFY limit.
      CHANNEL = "monk_presence".freeze
      NOTIFY_SQL = "SELECT pg_notify('#{CHANNEL}', $1)".freeze
      MAX_SIGNAL_BYTES = 7999

      # subjects as JSON arrays that each fit one notify. A subject too
      # long to fit even alone is left out, and logged: sending it would
      # fail the settle, every tick.
      def self.signals(subjects)
        chunks = []
        current = []
        size = 2 # "[]"
        subjects.each do |subject|
          json = JSON.generate(subject)
          if json.bytesize + 2 > MAX_SIGNAL_BYTES
            Monk::Log.error("Monk::Presence: subject too long to signal (#{json.bytesize} bytes), left out")
            next
          end
          added = json.bytesize + (current.empty? ? 0 : 1)
          if size + added > MAX_SIGNAL_BYTES
            chunks << current
            current = []
            size = 2
            added = json.bytesize
          end
          current << json
          size += added
        end
        chunks << current unless current.empty?
        chunks.map { |jsons| "[#{jsons.join(",")}]" }
      end

      attr_reader :db_name, :grace, :process_timeout

      def initialize(db_name:, grace:, process_timeout:)
        @db_name = db_name
        @grace = grace
        @process_timeout = process_timeout
        freeze
      end

      # This process's own row; returns its id.
      def register_process(hostname:, pid:)
        with_connection { |c| Integer(c.exec_params(REGISTER_PROCESS_SQL, [hostname, pid]).getvalue(0, 0)) }
      end

      # True when the row was gone and had to be written again: the
      # process's presence rows were pruned with it.
      def heartbeat(process_id, hostname:, pid:)
        with_connection { |c| c.exec_params(HEARTBEAT_SQL, [process_id, hostname, pid]).getvalue(0, 0) == true }
      end

      # online:/away: the subjects with sockets in this process, by status;
      # gone: those down to none.
      def flush(process_id, online: [], away: [], gone: [])
        params = [process_id, *subjects_and_statuses(online, away), ARRAY.encode(gone)]
        with_connection { |c| c.exec_params(FLUSH_SQL, params) }
        nil
      end

      # online:/away: every subject with a socket in this process.
      def rewrite(process_id, online:, away:)
        params = [process_id, *subjects_and_statuses(online, away)]
        with_connection { |c| c.exec_params(REWRITE_SQL, params) }
        nil
      end

      def mark_all_gone(process_id)
        with_connection { |c| c.exec_params(MARK_ALL_GONE_SQL, [process_id]) }
        nil
      end

      # {subject => {status:, last_seen_at:}} for each of subjects, from
      # the rows: right even with every WebSocket process down.
      # last_seen_at is a Time for an offline subject seen before, else nil.
      def status(subjects)
        rows = with_connection { |c| c.exec_params(STATUS_SQL, [ARRAY.encode(subjects), @grace, @process_timeout]) }
        rows.to_h do |row|
          status = row["status"].to_sym
          seen = row["last_seen_at"] if status == :offline
          [row["subject"], { status: status, last_seen_at: seen && Time.at(seen) }]
        end
      end

      # The transitions this call recorded, each one only ever returned to
      # one caller. reconcile: also checks every subject stored as not
      # offline. notify: also signals the changed subjects on CHANNEL, in
      # the same transaction, so the signal is delivered with the commit.
      def settle(subjects, reconcile: false, notify: false)
        params = [ARRAY.encode(subjects), @grace, @process_timeout, reconcile]
        rows = with_connection do |c|
          c.transaction do
            c.exec(SETTLE_LOCK_SQL)
            settled = c.exec_params(SETTLE_SQL, params).to_a
            Store.signals(settled.map { |row| row["subject"] }).each { |p| c.exec_params(NOTIFY_SQL, [p]) } if notify
            settled
          end
        end
        rows.map do |row|
          seen = row["last_seen_at"]
          Transition.new(subject: row["subject"], status: row["status"].to_sym, last_seen_at: seen && Time.at(seen))
        end
      end

      private

      def with_connection(&) = Monk::Persistence::Pg.checkout(@db_name, &)

      def subjects_and_statuses(online, away)
        statuses = Array.new(online.size, "online") + Array.new(away.size, "away")
        [ARRAY.encode(online + away), ARRAY.encode(statuses)]
      end
    end
  end
end
