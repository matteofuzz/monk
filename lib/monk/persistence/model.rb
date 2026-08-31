module Monk
  module Persistence
    # Backend-agnostic base for persistence models: tracks subclasses and
    # freezes their db_name/table_name at boot (Seam B), so they're
    # readable from a worker Ractor -- freezing the class itself would do
    # nothing, since Class/Module objects are always Ractor.shareable?
    # regardless of their instance variables. A concrete backend (e.g.
    # Monk::Persistence::Pg::Model, loaded separately) subclasses this and
    # adds the actual CRUD methods; nothing here is CRUD-specific or
    # backend-specific.
    class Model
      class << self
        attr_accessor :db_name, :table_name

        def inherited(subclass)
          super
          Model.subclasses << subclass
        end

        def subclasses
          @subclasses ||= []
        end

        # Called from Base#freeze! (Seam B). Deliberately does NOT check
        # whether db_name is registered with a backend -- that registry is
        # process-global, not scoped to whichever Base subclass happens to
        # be booting, so that check would produce false failures (e.g. a
        # Model used by one app tripping another app's boot before its own
        # db is registered).
        def freeze_all!
          Model.subclasses.each do |subclass|
            subclass.db_name = Ractor.make_shareable(subclass.db_name)
            subclass.table_name = Ractor.make_shareable(subclass.table_name)
          rescue Ractor::Error => e
            raise Monk::UnshareableModelError, "#{subclass} is not Ractor-shareable: #{e.message}"
          end
        end
      end
    end
  end
end
