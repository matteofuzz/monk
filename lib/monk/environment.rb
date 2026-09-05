require_relative "settings"

module Monk
  # The tier an app is running under -- CONTEXT.md's MONK_ENV entry.
  # A small, frozen value object wrapping Settings[:monk_env] (never
  # cached across calls itself: each Monk.env call builds a fresh, local
  # instance, cheap since it never crosses a Ractor boundary -- only the
  # String it wraps, read from Settings' already-frozen values, does).
  #
  # Predicates are four plain, hand-written methods, not one
  # define_method(&block) per MONK_ENV_VALUES entry: a method backed by a
  # Proc closure raises "defined with an un-shareable Proc in a different
  # Ractor" the first time a *different* Ractor than the one that defined
  # it calls it -- discovered by this class's own real-Ractor test.
  # Ordinary `def` methods compile to plain bytecode with no Proc
  # involved, so they carry no such restriction (the same reason View's
  # compiled templates -- ADR 0004 -- are real methods, not blocks).
  class Environment
    attr_reader :value

    def initialize(value)
      @value = value
      freeze
    end

    def development?
      value == "development"
    end

    def test?
      value == "test"
    end

    def staging?
      value == "staging"
    end

    def production?
      value == "production"
    end

    def to_s
      value
    end
  end

  def self.env
    Environment.new(Settings[:monk_env])
  end
end
