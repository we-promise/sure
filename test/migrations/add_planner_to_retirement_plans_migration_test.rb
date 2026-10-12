# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008150200_add_planner_to_retirement_plans")

# A database can already carry the planner's columns and tables when this
# migration runs: one that built them from an earlier migration of its own
# records that version, not this one, so this one is still pending there. `up`
# must then leave the columns, the tables, their constraints and every saved
# plan, stream and linked account exactly as it found them. The schema changes
# roll back with the test's transaction.
class AddPlannerToRetirementPlansMigrationTest < ActiveSupport::TestCase
  TABLES = %i[retirement_plans retirement_plan_streams retirement_plan_accounts].freeze
  PLANNER_COLUMNS = %w[birth_year end_age inflation_rate mode streams_seeded_on].freeze
  PLANNER_CHECKS = %w[
    chk_retirement_plans_birth_year chk_retirement_plans_end_age
    chk_retirement_plans_inflation_rate chk_retirement_plans_mode
  ].freeze
  STREAM_CHECKS = %w[
    chk_retirement_plan_streams_amount chk_retirement_plan_streams_kind
    chk_retirement_plan_streams_source chk_retirement_plan_streams_years
  ].freeze

  test "up over existing planner columns and tables changes nothing and keeps every plan, stream and account" do
    plan_id = insert_plan_with_stream_and_account
    before = snapshot

    assert_nothing_raised { migrate(:up) }

    assert_equal before, snapshot
    assert_equal [ [ "1980", "95", "fire" ] ],
      connection.select_rows("SELECT birth_year::text, end_age::text, mode FROM retirement_plans WHERE id = #{connection.quote(plan_id)}")
    assert_equal 1, connection.select_value("SELECT count(*) FROM retirement_plan_streams WHERE retirement_plan_id = #{connection.quote(plan_id)}")
    assert_equal 1, connection.select_value("SELECT count(*) FROM retirement_plan_accounts WHERE retirement_plan_id = #{connection.quote(plan_id)}")
  end

  # `down` is the plain reversal, so it doubles as the way to reach a database
  # that never had the planner.
  test "down removes the planner, and up on a database without it adds it back" do
    plan_id = insert_plan_with_stream_and_account

    migrate(:down)
    assert_not connection.table_exists?(:retirement_plan_streams), "precondition: the streams table is gone"
    assert_not connection.table_exists?(:retirement_plan_accounts), "precondition: the accounts table is gone"
    assert_empty PLANNER_COLUMNS & connection.columns(:retirement_plans).map(&:name), "precondition: the columns are gone"
    assert_empty PLANNER_CHECKS & connection.check_constraints(:retirement_plans).map(&:name), "precondition: the checks are gone"

    migrate(:up)

    columns = connection.columns(:retirement_plans).index_by(&:name)
    assert_equal PLANNER_COLUMNS, PLANNER_COLUMNS & columns.keys
    assert_equal [ false, 90 ], [ columns["end_age"].null, columns["end_age"].default ]
    assert_equal [ false, "traditional" ], [ columns["mode"].null, columns["mode"].default ]
    assert_equal PLANNER_CHECKS, PLANNER_CHECKS & connection.check_constraints(:retirement_plans).map(&:name)
    assert_equal STREAM_CHECKS, connection.check_constraints(:retirement_plan_streams).map(&:name).sort
    assert connection.index_exists?(:retirement_plan_accounts, [ :retirement_plan_id, :account_id ],
                                    unique: true, name: "idx_retirement_plan_accounts_unique")
    # The plan itself survived the round trip, now with the new defaults.
    assert_equal [ [ "90", "traditional" ] ],
      connection.select_rows("SELECT end_age::text, mode FROM retirement_plans WHERE id = #{connection.quote(plan_id)}")
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddPlannerToRetirementPlans.new.migrate(direction) }
    end

    def insert_plan_with_stream_and_account
      user = users(:family_admin)
      account = accounts(:depository)
      connection.execute("DELETE FROM retirement_plans WHERE user_id = #{connection.quote(user.id)}")
      plan_id = connection.select_value(<<~SQL)
        INSERT INTO retirement_plans (user_id, birth_year, end_age, mode, created_at, updated_at)
        VALUES (#{connection.quote(user.id)}, 1980, 95, 'fire', now(), now())
        RETURNING id
      SQL
      connection.execute(<<~SQL)
        INSERT INTO retirement_plan_streams (retirement_plan_id, kind, name, annual_amount, source, created_at, updated_at)
        VALUES (#{connection.quote(plan_id)}, 'expense', 'Living costs', 40000, 'manual', now(), now());
        INSERT INTO retirement_plan_accounts (retirement_plan_id, account_id, created_at, updated_at)
        VALUES (#{connection.quote(plan_id)}, #{connection.quote(account.id)}, now(), now())
      SQL
      plan_id
    end

    # Each table's columns, indexes, foreign keys and check constraints, and
    # every row in it.
    def snapshot
      TABLES.index_with do |table|
        {
          columns: connection.columns(table).map { |c| [ c.name, c.sql_type, c.null, c.default ] },
          indexes: connection.indexes(table).map { |i| [ i.name, i.columns, i.unique ] },
          foreign_keys: connection.foreign_keys(table).map { |k| [ k.name, k.to_table, k.on_delete ] },
          check_constraints: connection.check_constraints(table).map { |c| [ c.name, c.expression ] },
          rows: connection.select_rows("SELECT * FROM #{table} ORDER BY id")
        }
      end
    end
end
