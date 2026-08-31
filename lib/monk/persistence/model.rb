module Monk
  module Persistence
    # Deliberately not an ORM: no associations, no validations, no
    # callbacks, no dirty-tracking, no live row objects. Every method takes
    # or returns plain Hashes (Symbol-keyed), so nothing here has to cross
    # a Ractor boundary as anything but copyable data.
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

        # Called from Base#freeze! (Seam B). Freezes each known subclass's
        # db_name/table_name *values* -- freezing the subclass itself would
        # do nothing: Class/Module objects are always Ractor.shareable?
        # regardless of their instance variables, so reading an ivar
        # holding an unfrozen value from a worker Ractor raises
        # Ractor::IsolationError whether or not the class was "frozen".
        # Deliberately does NOT check whether db_name is registered with
        # Monk::Persistence -- this registry is process-global, not scoped
        # to whichever Base subclass happens to be booting, so that check
        # would produce false failures (e.g. a Model used by one app
        # tripping another app's boot before its own db is registered).
        def freeze_all!
          Model.subclasses.each do |subclass|
            subclass.db_name = Ractor.make_shareable(subclass.db_name)
            subclass.table_name = Ractor.make_shareable(subclass.table_name)
          rescue Ractor::Error => e
            raise Monk::UnshareableModelError, "#{subclass} is not Ractor-shareable: #{e.message}"
          end
        end

        def create(data)
          Monk::Persistence.checkout(db_name) do |conn|
            columns = data.keys.map { |c| conn.quote_ident(c.to_s) }
            placeholders = (1..data.size).map { |i| "$#{i}" }
            sql = "INSERT INTO #{conn.quote_ident(table_name)} (#{columns.join(", ")}) " \
              "VALUES (#{placeholders.join(", ")}) RETURNING *"
            to_row(conn.exec_params(sql, data.values))
          end
        end

        def find(id)
          Monk::Persistence.checkout(db_name) do |conn|
            sql = "SELECT * FROM #{conn.quote_ident(table_name)} WHERE id = $1"
            to_row(conn.exec_params(sql, [id]))
          end
        end

        # Equality + AND only -- no >, IN, LIKE, OR. An empty Hash means no
        # filter (all rows), not an error: the natural degenerate case of
        # zero AND'd conditions.
        def where(conditions)
          Monk::Persistence.checkout(db_name) do |conn|
            if conditions.empty?
              to_rows(conn.exec("SELECT * FROM #{conn.quote_ident(table_name)}"))
            else
              clause = conditions.keys.each_with_index
                .map { |c, i| "#{conn.quote_ident(c.to_s)} = $#{i + 1}" }.join(" AND ")
              sql = "SELECT * FROM #{conn.quote_ident(table_name)} WHERE #{clause}"
              to_rows(conn.exec_params(sql, conditions.values))
            end
          end
        end

        def update(id, data)
          Monk::Persistence.checkout(db_name) do |conn|
            sets = data.keys.each_with_index
              .map { |c, i| "#{conn.quote_ident(c.to_s)} = $#{i + 2}" }.join(", ")
            sql = "UPDATE #{conn.quote_ident(table_name)} SET #{sets} WHERE id = $1 RETURNING *"
            to_row(conn.exec_params(sql, [id, *data.values]))
          end
        end

        def delete(id)
          Monk::Persistence.checkout(db_name) do |conn|
            sql = "DELETE FROM #{conn.quote_ident(table_name)} WHERE id = $1"
            conn.exec_params(sql, [id]).cmd_tuples.positive?
          end
        end

        private

        def to_rows(result)
          result.map { |row| row.transform_keys(&:to_sym) }
        end

        def to_row(result)
          to_rows(result).first
        end
      end
    end
  end
end
