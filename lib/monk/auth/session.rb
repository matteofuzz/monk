require_relative "../persistence/pg/model"

module Monk
  module Auth
    # Internal storage for session tokens -- not part of Monk::Auth's public
    # API (docs/auth-sessions.md's "Two tokens, not one").
    class Session < Monk::Persistence::Pg::Model
      self.table_name = "sessions"
    end
  end
end
