module Monk
  module Persistence
    # Deliberately not an ORM: no associations, no validations, no
    # callbacks, no dirty-tracking, no live row objects. Every method takes
    # or returns plain Hashes (Symbol-keyed), so nothing here has to cross
    # a Ractor boundary as anything but copyable data.
    class Model
      class << self
        attr_accessor :db_name, :table_name

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

        private

        def to_row(result)
          result.ntuples.zero? ? nil : result[0].transform_keys(&:to_sym)
        end
      end
    end
  end
end
