require_relative "monk/version"
require_relative "monk/settings"
require_relative "monk/environment"
require_relative "monk/invalid_monk_env_error"
require_relative "monk/views"
require_relative "monk/assets"
require_relative "monk/log"
require_relative "monk/context"
require_relative "monk/unshareable_route_error"
require_relative "monk/unshareable_block_error"
require_relative "monk/unknown_persistence_error"
require_relative "monk/unshareable_model_error"
require_relative "monk/persistence_timeout_error"
require_relative "monk/template_not_found_error"
require_relative "monk/template_syntax_error"
require_relative "monk/unknown_setting_error"
require_relative "monk/duplicate_setting_error"
require_relative "monk/missing_setting_error"
require_relative "monk/settings_frozen_error"
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
