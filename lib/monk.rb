require_relative "monk/version"
require_relative "monk/settings"
require_relative "monk/environment"
require_relative "monk/errors"
require_relative "monk/views"
require_relative "monk/assets"
require_relative "monk/log"
require_relative "monk/context"
require_relative "monk/persistence/errors"
require_relative "monk/state_ractor"
require_relative "monk/persistence"
require_relative "monk/persistence/model"
require_relative "monk/base"

# Persistence backends (Monk::Persistence::Pg, and any future adapter) are
# opt-in -- require them explicitly, e.g. `require "monk/persistence/pg"`.

module Monk
  def self.boot(app)
    app.freeze!
    app
  end
end
