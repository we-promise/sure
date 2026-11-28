# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008150300_add_monte_carlo_to_retirement_plans")

# The migration owns two columns on retirement_plans and a check constraint on
# each. `down` must remove those and nothing else, `up` must put them back as
# they were, and `up` must not quietly adopt columns it did not create -- a
# rollback would then drop them and every plan's settings with them. The schema
# changes roll back with the test's transaction.
class AddMonteCarloToRetirementPlansMigrationTest < ActiveSupport::TestCase
  COLUMNS = %w[return_volatility success_target].freeze
  CONSTRAINTS = %w[chk_retirement_plans_return_volatility chk_retirement_plans_success_target].freeze

  test "down then up restores the columns, their defaults and their constraints" do
    before = shape

    migrate(:down)
    migrate(:up)

    assert_equal before, shape
    assert_equal [ "numeric(5,4)", "0.12", false ], before[:columns]["return_volatility"]
    assert_equal [ "numeric(5,4)", "0.9", false ], before[:columns]["success_target"]
    assert_equal %w[0 1], before[:constraints]["chk_retirement_plans_return_volatility"]
    assert_equal %w[0 1], before[:constraints]["chk_retirement_plans_success_target"]
  end

  test "down removes exactly the columns and constraints that up adds" do
    columns_up, constraints_up = column_names, constraint_names

    migrate(:down)
    columns_down, constraints_down = column_names, constraint_names

    migrate(:up)

    assert_equal COLUMNS, columns_up - columns_down
    assert_equal CONSTRAINTS, (constraints_up - constraints_down).sort
    assert_empty columns_down - columns_up
    assert_empty constraints_down - constraints_up
    assert_equal columns_up.sort, column_names.sort
    assert_equal constraints_up.sort, constraint_names.sort
  end

  test "up refuses columns it did not create rather than adopting them" do
    before = shape

    error = assert_raises(ActiveRecord::StatementInvalid) do
      ActiveRecord::Base.transaction(requires_new: true) { migrate(:up) }
    end

    assert_match(/DuplicateColumn: ERROR:  column "return_volatility" of relation "retirement_plans" already exists/,
      error.message)
    assert_equal before, shape
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddMonteCarloToRetirementPlans.new.migrate(direction) }
    end

    def column_names
      connection.columns(:retirement_plans).map(&:name)
    end

    def constraint_names
      connection.check_constraints(:retirement_plans).map(&:name)
    end

    # What this migration declares, read back from the catalog.
    def shape
      columns = connection.columns(:retirement_plans).select { |c| COLUMNS.include?(c.name) }
      {
        columns: columns.to_h { |c| [ c.name, [ c.sql_type, c.default, c.null ] ] }.sort.to_h,
        constraints: CONSTRAINTS.index_with { |name| constraint_literals(name) }.compact
      }
    end

    # The literals a check constraint compares against, in order. Compared
    # rather than the rendered predicate: a constraint loaded from schema.rb and
    # one created by `add_check_constraint` print the same check with different
    # casts.
    def constraint_literals(name)
      definition = connection.select_value(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " \
        "WHERE conname = #{connection.quote(name)} AND conrelid = 'retirement_plans'::regclass"
      )
      definition&.scan(/'([^']*)'|\b(\d+(?:\.\d+)?)\b/)&.map { |quoted, number| quoted || number }
    end
end
