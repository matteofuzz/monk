require_relative "../persistence/pg/model"

module Monk
  module Auth
    # Internal storage for magic-link tokens -- not part of Monk::Auth's
    # public API (docs/auth-sessions.md's "Two tokens, not one").
    class LoginToken < Monk::Persistence::Pg::Model
      self.table_name = "login_tokens"
    end
  end
end
