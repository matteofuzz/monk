require_relative "test_helper"

# The test database is reachable with .env.test's settings, and migrated
# (SETUP.md, postgres).
class PersistenceTest < Minitest::Test
  def test_connects_to_the_test_database
    Monk::Persistence::Pg.checkout(:primary) do |conn|
      assert_equal 1, conn.exec("SELECT 1").getvalue(0, 0)
    end
  end
end
