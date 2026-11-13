require "pg"
require_relative "../persistence/pg"

module Monk
  module Push
    # Push's statements on push_subscriptions (and, read-only, auth's
    # sessions). A subscription counts -- gets notifications, makes its
    # subject subscribed -- only while its session is neither revoked nor
    # expired, and while the browser's own expirationTime hasn't passed
    # (docs/plan-pwa-push.md decision 1). Module functions over a db_name,
    # each reaching Postgres through Monk::Persistence::Pg in whatever
    # Ractor calls it, as the job workers do.
    module Store
      ARRAY = Ractor.make_shareable(PG::TextEncoder::Array.new)

      LIVE = <<~SQL.freeze
        s.revoked_at IS NULL AND s.expires_at > now() AND (p.expires_at IS NULL OR p.expires_at > now())
      SQL

      # Only for a valid session: no row when the cookie's session is
      # unknown, revoked or expired. An endpoint already stored (the same
      # browser) moves to this session and subject, with its new keys.
      SUBSCRIBE_SQL = <<~SQL.freeze
        INSERT INTO push_subscriptions (session_id, subject, endpoint, p256dh, auth, user_agent, expires_at)
        SELECT s.id, s.subject, $2, $3, $4, $5, $6::timestamptz FROM sessions s
        WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now()
        ON CONFLICT (endpoint) DO UPDATE SET session_id = excluded.session_id, subject = excluded.subject,
          p256dh = excluded.p256dh, auth = excluded.auth, user_agent = excluded.user_agent,
          expires_at = excluded.expires_at
        RETURNING id, subject
      SQL

      COLUMNS = "p.id, p.subject, p.endpoint, p.p256dh, p.auth".freeze

      FOR_SUBJECT_SQL = <<~SQL.freeze
        SELECT #{COLUMNS} FROM push_subscriptions p JOIN sessions s ON s.id = p.session_id
        WHERE p.subject = $1 AND #{LIVE} ORDER BY p.id
      SQL

      BY_ID_SQL = <<~SQL.freeze
        SELECT #{COLUMNS} FROM push_subscriptions p JOIN sessions s ON s.id = p.session_id
        WHERE p.id = $1 AND #{LIVE}
      SQL

      SUBSCRIBED_SQL = <<~SQL.freeze
        SELECT DISTINCT p.subject FROM push_subscriptions p JOIN sessions s ON s.id = p.session_id
        WHERE p.subject = ANY($1::text[]) AND #{LIVE}
      SQL

      UNSUBSCRIBE_SQL = "DELETE FROM push_subscriptions WHERE endpoint = $1".freeze
      DELETE_SQL = "DELETE FROM push_subscriptions WHERE id = $1".freeze
      SUCCEEDED_SQL = "UPDATE push_subscriptions SET last_success_at = now() WHERE id = $1".freeze

      # What no longer counts: a revoked session's rows, an expired
      # session's (if Monk::Auth.sweep! hasn't taken the session yet), and
      # those past the browser's expirationTime. $1 is the batch size.
      SWEEP_SQL = <<~SQL.freeze
        DELETE FROM push_subscriptions WHERE id IN (
          SELECT p.id FROM push_subscriptions p JOIN sessions s ON s.id = p.session_id
          WHERE NOT (#{LIVE}) LIMIT $1
        )
      SQL

      module_function

      # { id:, subject: }, or nil when the session doesn't count.
      def subscribe(db_name, session_hash, subscription, user_agent)
        expires_at = subscription.expires_at&.iso8601(3)
        params = [session_hash, subscription.endpoint, subscription.p256dh, subscription.auth, user_agent, expires_at]
        row = checkout(db_name) { |conn| conn.exec_params(SUBSCRIBE_SQL, params).first }
        row && { id: Integer(row["id"]), subject: row["subject"] }
      end

      def unsubscribe(db_name, endpoint)
        checkout(db_name) { |conn| conn.exec_params(UNSUBSCRIBE_SQL, [endpoint]).cmd_tuples.positive? }
      end

      def for_subject(db_name, subject)
        checkout(db_name) { |conn| conn.exec_params(FOR_SUBJECT_SQL, [subject]).map { |row| record(row) } }
      end

      def find(db_name, id)
        checkout(db_name) { |conn| conn.exec_params(BY_ID_SQL, [id]).map { |row| record(row) }.first }
      end

      # { subject => true/false } for every subject given.
      def subscribed(db_name, subjects)
        subjects = subjects.map(&:to_s).uniq
        found = checkout(db_name) do |conn|
          conn.exec_params(SUBSCRIBED_SQL, [ARRAY.encode(subjects)]).map { |row| row["subject"] }
        end
        subjects.to_h { |subject| [subject, found.include?(subject)] }
      end

      def delete(db_name, id)
        checkout(db_name) { |conn| conn.exec_params(DELETE_SQL, [id]).cmd_tuples.positive? }
      end

      def succeeded(db_name, id)
        checkout(db_name) { |conn| conn.exec_params(SUCCEEDED_SQL, [id]) }
        nil
      end

      def sweep(db_name, batch_size)
        checkout(db_name) do |conn|
          total = 0
          loop do
            deleted = conn.exec_params(SWEEP_SQL, [batch_size]).cmd_tuples
            total += deleted
            break total if deleted < batch_size
          end
        end
      end

      def record(row)
        { id: Integer(row["id"]), subject: row["subject"], endpoint: row["endpoint"], p256dh: row["p256dh"],
          auth: row["auth"], }
      end

      def checkout(db_name, &) = Monk::Persistence::Pg.checkout(db_name, &)
    end
  end
end
