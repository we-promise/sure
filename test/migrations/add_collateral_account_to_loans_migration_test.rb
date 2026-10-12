# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008110000_add_collateral_account_to_loans")

# The migration owns one column with its index and its foreign key. `down` must
# remove those and nothing else, `up` must put them back as they were, and `up`
# must not quietly adopt a column it did not create -- a rollback would then
# drop that column and every loan's collateral link with it. The schema changes
# roll back with the test's transaction.
class AddCollateralAccountToLoansMigrationTest < ActiveSupport::TestCase
  COLUMN = "collateral_account_id"
  INDEX = "index_loans_on_collateral_account_id"

  teardown { Loan.reset_column_information }

  test "down then up restores the column, its index and its foreign key" do
    before = shape

    migrate(:down)
    migrate(:up)

    assert_equal before, shape
    assert_equal [ "uuid", nil, true ], before[:column]
    assert_equal [ [ INDEX, [ COLUMN ], false ] ], before[:indexes]
    assert_equal [ [ "accounts", "id", :nullify ] ], before[:foreign_keys]
  end

  test "down removes exactly the column, index and foreign key that up adds" do
    columns_up, indexes_up, foreign_keys_up = column_names, index_names, foreign_key_columns

    migrate(:down)
    columns_down, indexes_down, foreign_keys_down = column_names, index_names, foreign_key_columns

    migrate(:up)

    assert_equal [ COLUMN ], columns_up - columns_down
    assert_equal [ INDEX ], indexes_up - indexes_down
    assert_equal [ COLUMN ], foreign_keys_up - foreign_keys_down
    assert_empty columns_down - columns_up
    assert_empty indexes_down - indexes_up
    assert_empty foreign_keys_down - foreign_keys_up
    assert_equal columns_up.sort, column_names.sort
    assert_equal indexes_up.sort, index_names.sort
    assert_equal foreign_keys_up.sort, foreign_key_columns.sort
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
      ActiveRecord::Migration.suppress_messages { AddCollateralAccountToLoans.new.migrate(direction) }
      Loan.reset_column_information
    end

    def column_names
      connection.columns(:loans).map(&:name)
    end

    def index_names
      connection.indexes(:loans).map(&:name)
    end

    def foreign_key_columns
      connection.foreign_keys(:loans).map(&:column)
    end

    def shape
      column = connection.columns(:loans).find { |c| c.name == COLUMN }
      {
        column: column && [ column.sql_type, column.default, column.null ],
        indexes: connection.indexes(:loans).select { |i| i.columns == [ COLUMN ] }
                           .map { |i| [ i.name, i.columns, i.unique ] },
        foreign_keys: connection.foreign_keys(:loans).select { |k| k.column == COLUMN }
                                .map { |k| [ k.to_table, k.primary_key, k.on_delete ] }
      }
    end
end
