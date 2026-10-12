# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008150100_create_user_retirement_plans")

# A database can already carry retirement_plans when this migration runs: one
# that built the table from an earlier migration of its own records that
# version, not this one, so this one is still pending there. `up` must then
# leave the table, its constraints and every saved plan exactly as it found
# them. The schema changes roll back with the test's transaction.
class CreateUserRetirementPlansMigrationTest < ActiveSupport::TestCase
  CONSTRAINTS = %w[
    chk_retirement_plans_safe_withdrawal_rate
    chk_retirement_plans_expected_annual_return
    chk_retirement_plans_savings_rate
  ].freeze

  test "up over an existing table changes nothing and keeps every saved plan" do
    user = users(:family_admin)
    connection.execute(<<~SQL)
      DELETE FROM retirement_plans WHERE user_id = #{connection.quote(user.id)};
      INSERT INTO retirement_plans (user_id, safe_withdrawal_rate, savings_rate, created_at, updated_at)
      VALUES (#{connection.quote(user.id)}, 0.035, 0.2, now(), now())
    SQL
    before = snapshot

    assert_nothing_raised { run_up }

    assert_equal before, snapshot
    assert_equal [ [ "0.0350", "0.2000" ] ],
      connection.select_rows("SELECT safe_withdrawal_rate::text, savings_rate::text FROM retirement_plans WHERE user_id = #{connection.quote(user.id)}")
  end

  test "up on a database without the table creates it with its index, foreign key and constraints" do
    # CASCADE: later migrations point other tables at this one.
    connection.drop_table :retirement_plans, force: :cascade
    assert_not connection.table_exists?(:retirement_plans), "precondition: the table is gone"

    run_up

    assert connection.table_exists?(:retirement_plans)
    assert connection.index_exists?(:retirement_plans, :user_id, unique: true)
    fk = connection.foreign_keys(:retirement_plans).find { |key| key.column == "user_id" }
    assert_equal [ "users", :cascade ], [ fk&.to_table, fk&.on_delete ]
    assert_equal CONSTRAINTS.sort, connection.check_constraints(:retirement_plans).map(&:name).sort
  end

  private
    def connection = ActiveRecord::Base.connection

    def run_up
      ActiveRecord::Migration.suppress_messages { CreateUserRetirementPlans.new.migrate(:up) }
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
