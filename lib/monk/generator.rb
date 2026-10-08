require_relative "generator/definition"
require_relative "generator/run"
require_relative "generator/result"

module Monk
  # `monk add`: one generator per module, run on any app, new or existing
  # (docs/adr/0017, docs/plan-scaffold.md). A generator only creates files
  # and appends lines; Run plans and checks everything before writing.
  module Generator
    TEMPLATES_DIR = File.expand_path("templates", __dir__)

    # The modules `monk add` knows, by name. Monk's own live in
    # lib/monk/generators/; tests build their own registry, over their own
    # templates.
    class Registry
      attr_reader :templates_dir

      def initialize(templates_dir:)
        @templates_dir = templates_dir
        @definitions = {}
      end

      def define(name, &)
        definition = Definition.new(name)
        definition.instance_eval(&)
        @definitions[definition.name] = definition
      end

      def fetch(name) = @definitions.fetch(name.to_sym)
      def names = @definitions.keys
      def definitions = @definitions.values

      # Adds `modules` (names) to the app in `dir`. Returns a Result, never
      # raises for a usage error, a missing choice or a conflict.
      def add(dir, modules, **)
        Run.new(registry: self, dir: dir, requested: modules, **).call
      end
    end

    class << self
      def registry
        @registry ||= Registry.new(templates_dir: TEMPLATES_DIR)
      end

      def define(name, &) = registry.define(name, &)
    end
  end
end
