require_relative "monk/version"
require_relative "monk/context"
require_relative "monk/unshareable_route_error"
require_relative "monk/unshareable_block_error"
require_relative "monk/unknown_persistence_error"
require_relative "monk/persistence_timeout_error"
require_relative "monk/state_ractor"
require_relative "monk/persistence"
require_relative "monk/base"

module Monk
  def self.boot(app)
    app.freeze!
    app
  end
end
