# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260918210000_add_day_count_convention_to_loans")

# The migration owns exactly one column and one check constraint. `down` must
# remove those and nothing else, `up` must put them back as they were, and `up`
# must not quietly adopt a column it did not create -- a rollback would then
# drop that column and every loan's basis with it. The schema changes roll back
# with the test's transaction.
class AddDayCountConventionToLoansMigrationTest < ActiveSupport::TestCase
  COLUMN = "day_count_convention"
  CONSTRAINT = AddDayCountConventionToLoans::CONSTRAINT

  teardown { Loan.reset_column_information }

  test "down then up restores the column, its default and its constraint" do
    before = shape

    migrate(:down)
    migrate(:up)

    assert_equal before, shape
    assert_equal "thirty_360", before[:default]
    assert_equal false, before[:null]
    assert_equal AddDayCountConventionToLoans::CONVENTIONS, before[:permitted]
  end

  test "down removes exactly the column and constraint that up adds" do
    columns_up = column_names
    constraints_up = constraint_names

    migrate(:down)
    columns_down = column_names
    constraints_down = constraint_names

    migrate(:up)

    assert_equal [ COLUMN ], columns_up - columns_down
    assert_equal [ CONSTRAINT ], constraints_up - constraints_down
    assert_empty columns_down - columns_up
    assert_empty constraints_down - constraints_up
    assert_equal columns_up.sort, column_names.sort
    assert_equal constraints_up.sort, constraint_names.sort
  end

  test "up refuses a column it did not create rather than adopting it" do
    before = shape

    error = assert_raises(ActiveRecord::StatementInvalid) do
      Loan.transaction(requires_new: true) { migrate(:up) }
    end

    assert_match(/column "#{COLUMN}" of relation "loans" already exists/, error.message)
    assert_equal before, shape
  end

  private
    def connection = ActiveRecord::Base.connection

    def migrate(direction)
      ActiveRecord::Migration.suppress_messages { AddDayCountConventionToLoans.new.migrate(direction) }
      Loan.reset_column_information
    end

    def column_names
      connection.columns(:loans).map(&:name)
    end

    def constraint_names
      connection.check_constraints(:loans).map(&:name)
    end

    def shape
      column = connection.columns(:loans).find { |c| c.name == COLUMN }
      {
        type: column&.sql_type,
        default: column&.default,
        null: column&.null,
        permitted: permitted_values
      }
    end

    # The values the constraint admits, read back from the catalog. Compared as
    # a list rather than as the rendered predicate: a constraint loaded from
    # schema.rb and one created by `add_check_constraint` print the same check
    # with different casts.
    def permitted_values
      definition = connection.select_value(
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint " \
        "WHERE conname = #{connection.quote(CONSTRAINT)}"
      )
      definition&.scan(/'([^']+)'/)&.flatten
    end
end
