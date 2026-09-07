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

    app_class = app.is_a?(Class) ? app : app.class
    parts = ['', "Monk #{VERSION} plays!", " - env=#{env}", " - routes=#{app_class.routes.size}"]
    parts << " - auth=on" if defined?(Auth) && Auth.config
    backends = persistence_backends
    parts << " - persistence=#{backends.join(",")}" unless backends.empty?
    parts << "\n"

    $stdout.puts parts.join("\n")
    app
  end

  # Backend module name (e.g. "pg") + its registered connection names
  # (e.g. "primary"), for every Persistence::Registry backend actually in
  # use -- Monk.freeze_hooks already lists every such module (each one
  # extends Registry and adds itself there), so this just filters that
  # list down to the ones with something registered, rather than keeping
  # a second registry of backends.
  def self.persistence_backends
    freeze_hooks
      .select { |hook| hook.is_a?(Module) && hook.singleton_class.include?(Persistence::Registry) }
      .filter_map { |hook| "#{hook.name.split("::").last.downcase}:#{hook.names.join(",")}" if hook.names.any? }
  end
  private_class_method :persistence_backends
end
