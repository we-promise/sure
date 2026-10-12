# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008150300_add_monte_carlo_to_retirement_plans")

# A database can already carry the Monte Carlo settings when this migration
# runs: one that built them from an earlier migration of its own records that
# version, not this one, so this one is still pending there. `up` must then
# leave the columns, their constraints and every plan's settings exactly as it
# found them. The schema changes roll back with the test's transaction.
class AddMonteCarloToRetirementPlansMigrationTest < ActiveSupport::TestCase
  COLUMNS = %w[return_volatility success_target].freeze
  CHECKS = %w[chk_retirement_plans_return_volatility chk_retirement_plans_success_target].freeze

  test "up over existing settings changes nothing and keeps every plan's values" do
    plan_id = insert_plan
    before = snapshot

    assert_nothing_raised { migrate(:up) }

    assert_equal before, snapshot
    assert_equal [ [ "0.2000", "0.7500" ] ], settings_of(plan_id)
  end

  # `down` is the plain reversal, so it doubles as the way to reach a database
  # that never had the settings.
  test "down removes the settings, and up on a database without them adds them back" do
    plan_id = insert_plan

    migrate(:down)
    assert_empty COLUMNS & connection.columns(:retirement_plans).map(&:name), "precondition: the columns are gone"
    assert_empty CHECKS & connection.check_constraints(:retirement_plans).map(&:name), "precondition: the checks are gone"

    migrate(:up)

    columns = connection.columns(:retirement_plans).index_by(&:name)
    assert_equal [ false, BigDecimal("0.12") ], [ columns["return_volatility"].null, columns["return_volatility"].default ]
    assert_equal [ false, BigDecimal("0.9") ], [ columns["success_target"].null, columns["success_target"].default ]
    assert_equal CHECKS, CHECKS & connection.check_constraints(:retirement_plans).map(&:name)
    # The plan itself survived the round trip, now with the defaults.
    assert_equal [ [ "0.1200", "0.9000" ] ], settings_of(plan_id)
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddMonteCarloToRetirementPlans.new.migrate(direction) }
    end

    def insert_plan
      user = users(:family_admin)
      connection.execute("DELETE FROM retirement_plans WHERE user_id = #{connection.quote(user.id)}")
      connection.select_value(<<~SQL)
        INSERT INTO retirement_plans (user_id, return_volatility, success_target, created_at, updated_at)
        VALUES (#{connection.quote(user.id)}, 0.2, 0.75, now(), now())
        RETURNING id
      SQL
    end

    def settings_of(plan_id)
      connection.select_rows(
        "SELECT return_volatility::text, success_target::text FROM retirement_plans WHERE id = #{connection.quote(plan_id)}"
      )
    end

    # The table's columns, indexes, foreign keys and check constraints, and
    # every row in it.
    def snapshot
      {
        columns: connection.columns(:retirement_plans).map { |c| [ c.name, c.sql_type, c.null, c.default ] },
        indexes: connection.indexes(:retirement_plans).map { |i| [ i.name, i.columns, i.unique ] },
        foreign_keys: connection.foreign_keys(:retirement_plans).map { |k| [ k.name, k.to_table, k.on_delete ] },
        check_constraints: connection.check_constraints(:retirement_plans).map { |c| [ c.name, c.expression ] },
        rows: connection.select_rows("SELECT * FROM retirement_plans ORDER BY id")
      }
    end
end
