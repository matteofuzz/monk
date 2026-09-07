require_relative "../pg"
require_relative "../model"

module Monk
  module Persistence
    module Pg
      # Deliberately not an ORM: no associations, no validations, no
      # callbacks, no dirty-tracking, no live row objects. Every method
      # takes or returns plain Hashes (Symbol-keyed), so nothing here has
      # to cross a Ractor boundary as anything but copyable data.
      class Model < Monk::Persistence::Model
        # Maps a `where` comparison-operator key to its SQL operator.
        # Deliberately a small, closed set -- not a general expression DSL.
        COMPARISON_OPERATORS = {
          gt: ">",
          gte: ">=",
          lt: "<",
          lte: "<=",
          ne: "<>",
        }.freeze

        class << self
          def create(data)
            Monk::Persistence::Pg.checkout(db_name) do |conn|
              columns = data.keys.map { |c| conn.quote_ident(c.to_s) }
              placeholders = (1..data.size).map { |i| "$#{i}" }
              sql = "INSERT INTO #{conn.quote_ident(table_name)} (#{columns.join(", ")}) " \
                "VALUES (#{placeholders.join(", ")}) RETURNING *"
              to_row(conn.exec_params(sql, data.values))
            end
          end

          # One INSERT, one round trip, one implicit transaction (a single
          # SQL statement is atomic on its own -- all rows land or none
          # do). Every Hash must have the same set of keys; order within
          # each Hash doesn't matter, but a differing key set would mean
          # a differing column list per row, which a single VALUES clause
          # can't express -- raises rather than silently NULL-filling the
          # gap, which would mask a caller bug. Row order in the result
          # matches `rows`' order in every version of Postgres this has
          # been checked against, but that isn't a documented SQL-standard
          # guarantee for multi-row RETURNING -- don't rely on it holding
          # across an exotic BEFORE INSERT trigger.
          def create_all(rows)
            return [] if rows.empty?

            columns = rows.first.keys
            unless rows.all? { |row| row.keys.map(&:to_s).sort == columns.map(&:to_s).sort }
              raise ArgumentError, "create_all requires every row to have the same columns"
            end

            Monk::Persistence::Pg.checkout(db_name) do |conn|
              quoted_columns = columns.map { |c| conn.quote_ident(c.to_s) }
              values = []
              row_placeholders = rows.map do |row|
                placeholders = columns.map do |column|
                  values << row.fetch(column)
                  "$#{values.size}"
                end
                "(#{placeholders.join(", ")})"
              end

              sql = "INSERT INTO #{conn.quote_ident(table_name)} (#{quoted_columns.join(", ")}) " \
                "VALUES #{row_placeholders.join(", ")} RETURNING *"
              to_rows(conn.exec_params(sql, values))
            end
          end

          def find(id)
            Monk::Persistence::Pg.checkout(db_name) do |conn|
              sql = "SELECT * FROM #{conn.quote_ident(table_name)} WHERE id = $1"
              to_row(conn.exec_params(sql, [id]))
            end
          end

          # One round trip, positionally matched to `ids` -- same length,
          # same order, a `nil` in place of any id that doesn't exist
          # (mirrors `find`'s single-row "nil means missing" rather than
          # silently dropping the position, which would desync a caller
          # zipping the result back against `ids`). A duplicate id in the
          # input appears at every one of its positions in the output.
          def find_all(ids)
            return [] if ids.empty?

            rows = where(id: ids)
            by_id = rows.each_with_object({}) { |row, h| h[row[:id]] = row }
            ids.map { |id| by_id[id] }
          end

          # AND-only -- still no OR, no arbitrary boolean trees. A condition
          # value is either a scalar (equality), an Array (IN -- an empty
          # Array matches no rows rather than producing invalid SQL), or a
          # Hash of comparison-operator => operand (see
          # COMPARISON_OPERATORS; multiple keys on one column AND together,
          # e.g. `quantity: { gte: 1, lt: 10 }`). An empty conditions Hash
          # means no filter (all rows), not an error: the natural
          # degenerate case of zero AND'd conditions.
          #
          # `options[:order]` is a column Symbol/String (ascending) or a
          # Hash of column => :asc/:desc for more than one column.
          # `options[:limit]` is an Integer row cap. Both are optional and
          # independent of conditions.
          #
          # `options` is a plain trailing Hash, not `order:`/`limit:`
          # keyword parameters -- Ruby only lets a bare `where(col: val)`
          # call collapse into the `conditions` positional Hash (the
          # calling convention every existing caller uses) as long as
          # `where` declares no real keyword parameters of its own; adding
          # `order:`/`limit:` as keywords would make Ruby try to parse
          # `col: val` as keyword arguments instead and raise.
          def where(conditions, options = {})
            Monk::Persistence::Pg.checkout(db_name) do |conn|
              clause, values = where_clause(conn, conditions)

              sql = +"SELECT * FROM #{conn.quote_ident(table_name)}"
              sql << " WHERE #{clause}" if clause
              sql << order_clause(conn, options[:order]) if options[:order]
              if (limit = options[:limit])
                raise ArgumentError, "limit must be an Integer, got #{limit.inspect}" unless limit.is_a?(Integer)

                values << limit
                sql << " LIMIT $#{values.size}"
              end

              to_rows(conn.exec_params(sql, values))
            end
          end

          def update(id, data)
            Monk::Persistence::Pg.checkout(db_name) do |conn|
              sets = data.keys.each_with_index
                .map { |c, i| "#{conn.quote_ident(c.to_s)} = $#{i + 2}" }.join(", ")
              sql = "UPDATE #{conn.quote_ident(table_name)} SET #{sets} WHERE id = $1 RETURNING *"
              to_row(conn.exec_params(sql, [id, *data.values]))
            end
          end

          # Conditional UPDATE ... RETURNING * -- the row or nil, in one
          # atomic statement instead of read-then-update, so two concurrent
          # claims of the same row can't both succeed (see Model.update's
          # unconditional `WHERE id = $1`, which can't express this guard).
          # Equality + AND only, consistent with `where`: a `nil` condition
          # value maps to `IS NULL`, not to a bound `= NULL` (which would
          # never match, since SQL NULL comparisons aren't true/false).
          def claim(conditions, data)
            Monk::Persistence::Pg.checkout(db_name) do |conn|
              sets = data.keys.each_with_index
                .map { |c, i| "#{conn.quote_ident(c.to_s)} = $#{i + 1}" }.join(", ")

              bound, nil_conditions = conditions.partition { |_, v| !v.nil? }
              where_parts = bound.each_with_index.map { |(c, _), i| "#{conn.quote_ident(c.to_s)} = $#{data.size + i + 1}" }
              where_parts += nil_conditions.map { |c, _| "#{conn.quote_ident(c.to_s)} IS NULL" }

              sql = "UPDATE #{conn.quote_ident(table_name)} SET #{sets} " \
                "WHERE #{where_parts.join(" AND ")} RETURNING *"
              to_row(conn.exec_params(sql, data.values + bound.map(&:last)))
            end
          end

          def delete(id)
            Monk::Persistence::Pg.checkout(db_name) do |conn|
              sql = "DELETE FROM #{conn.quote_ident(table_name)} WHERE id = $1"
              conn.exec_params(sql, [id]).cmd_tuples.positive?
            end
          end

          private

          # Returns [clause_string_or_nil, bound_values]. Building the
          # values array alongside the clause (rather than a separate
          # pass) keeps each condition's placeholder index in lockstep
          # with where it lands in `values`, including the multi-operator
          # Hash case where one column contributes more than one param.
          def where_clause(conn, conditions)
            values = []
            parts = conditions.map do |column, condition|
              ident = conn.quote_ident(column.to_s)
              case condition
              when Hash
                condition.map { |op, operand| comparison(ident, op, operand, values) }.join(" AND ")
              when Array
                in_clause(ident, condition, values)
              else
                values << condition
                "#{ident} = $#{values.size}"
              end
            end
            [parts.empty? ? nil : parts.join(" AND "), values]
          end

          def comparison(ident, op, operand, values)
            operator = COMPARISON_OPERATORS.fetch(op) do
              raise ArgumentError, "unsupported where operator #{op.inspect}"
            end
            values << operand
            "#{ident} #{operator} $#{values.size}"
          end

          def in_clause(ident, list, values)
            return "1 = 0" if list.empty?

            placeholders = list.map do |item|
              values << item
              "$#{values.size}"
            end
            "#{ident} IN (#{placeholders.join(", ")})"
          end

          def order_clause(conn, order)
            columns = order.is_a?(Hash) ? order : { order => :asc }
            clause = columns.map do |column, direction|
              direction = direction.to_sym
              unless %i[asc desc].include?(direction)
                raise ArgumentError, "order direction must be :asc or :desc, got #{direction.inspect}"
              end

              "#{conn.quote_ident(column.to_s)} #{direction.to_s.upcase}"
            end.join(", ")
            " ORDER BY #{clause}"
          end

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
end
