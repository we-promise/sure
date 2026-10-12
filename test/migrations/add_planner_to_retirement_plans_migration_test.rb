# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008150200_add_planner_to_retirement_plans")

# The migration owns five columns and four check constraints on
# retirement_plans, and the retirement_plan_streams and retirement_plan_accounts
# tables with their indexes, foreign keys and constraints. `down` must remove
# those and nothing else, `up` must put them back as they were, and `up` must
# not quietly adopt columns it did not create -- a rollback would then drop
# them, and every plan's streams and accounts with them. The schema changes
# roll back with the test's transaction.
class AddPlannerToRetirementPlansMigrationTest < ActiveSupport::TestCase
  PLAN_COLUMNS = %w[birth_year end_age inflation_rate mode streams_seeded_on].freeze
  PLAN_CONSTRAINTS = %w[
    chk_retirement_plans_birth_year chk_retirement_plans_end_age
    chk_retirement_plans_inflation_rate chk_retirement_plans_mode
  ].freeze
  TABLES = %w[retirement_plan_accounts retirement_plan_streams].freeze

  test "down then up restores the columns, the tables and their constraints" do
    before = shape

    migrate(:down)
    migrate(:up)

    assert_equal before, shape
    assert_equal [ "integer", 90, false ], before[:plan_columns]["end_age"]
    assert_equal [ "numeric(6,4)", BigDecimal("0.03"), false ], before[:plan_columns]["inflation_rate"]
    assert_equal [ "character varying", "traditional", false ], before[:plan_columns]["mode"]
    assert_equal %w[traditional fire], before[:plan_constraints]["chk_retirement_plans_mode"]
    assert_equal %w[expense income one_off],
      before[:tables]["retirement_plan_streams"][:constraints]["chk_retirement_plan_streams_kind"]
    assert_equal %w[seeded_living_costs seeded_loan manual],
      before[:tables]["retirement_plan_streams"][:constraints]["chk_retirement_plan_streams_source"]
    assert_includes before[:tables]["retirement_plan_accounts"][:indexes],
      [ "idx_retirement_plan_accounts_unique", %w[retirement_plan_id account_id], true ]
  end

  test "down removes exactly the columns, constraints and tables that up adds" do
    columns_up, constraints_up, tables_up = plan_column_names, plan_constraint_names, connection.tables

    migrate(:down)
    columns_down, constraints_down, tables_down = plan_column_names, plan_constraint_names, connection.tables

    migrate(:up)

    assert_equal PLAN_COLUMNS, columns_up - columns_down
    assert_equal PLAN_CONSTRAINTS, constraints_up - constraints_down
    assert_equal TABLES, (tables_up - tables_down).sort
    assert_empty columns_down - columns_up
    assert_empty constraints_down - constraints_up
    assert_empty tables_down - tables_up
    assert_equal columns_up.sort, plan_column_names.sort
    assert_equal constraints_up.sort, plan_constraint_names.sort
    assert_equal tables_up.sort, connection.tables.sort
  end

  test "up refuses columns it did not create rather than adopting them" do
    before = shape

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) { migrate(:up) }
    end

    assert_match(/DuplicateColumn: ERROR:  column "birth_year" of relation "retirement_plans" already exists/,
      error.message)
    assert_equal before, shape
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddPlannerToRetirementPlans.new.migrate(direction) }
    end

    def plan_column_names
      connection.columns(:retirement_plans).map(&:name)
    end

    def plan_constraint_names
      connection.check_constraints(:retirement_plans).map(&:name)
    end

    # What this migration declares, read back from the catalog.
    def shape
      plan_columns = connection.columns(:retirement_plans).select { |c| PLAN_COLUMNS.include?(c.name) }
      {
        plan_columns: column_shapes(plan_columns),
        plan_constraints: PLAN_CONSTRAINTS.index_with { |name| constraint_literals(:retirement_plans, name) }.compact,
        tables: TABLES.select { |table| connection.table_exists?(table) }.index_with { |table| table_shape(table) }
      }
    end

    def table_shape(table)
      {
        columns: column_shapes(connection.columns(table)),
        indexes: connection.indexes(table).map { |i| [ i.name, i.columns, i.unique ] }.sort,
        foreign_keys: connection.foreign_keys(table).map { |k| [ k.column, k.to_table, k.on_delete ] }.sort,
        constraints: connection.check_constraints(table).map(&:name).sort
                               .index_with { |name| constraint_literals(table, name) }
      }
    end

    def column_shapes(columns)
      columns.to_h { |c| [ c.name, [ c.sql_type, c.default || c.default_function, c.null ] ] }.sort.to_h
    end

    # The literals a check constraint compares against, in order. Compared
    # rather than the rendered predicate: a constraint loaded from schema.rb and
    # one created by `add_check_constraint` print the same check with different
    # casts.
    def constraint_literals(table, name)
      definition = connection.select_value(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " \
        "WHERE conname = #{connection.quote(name)} AND conrelid = #{connection.quote(table.to_s)}::regclass"
      )
      definition&.scan(/'([^']*)'|\b(\d+(?:\.\d+)?)\b/)&.map { |quoted, number| quoted || number }
    end
end
