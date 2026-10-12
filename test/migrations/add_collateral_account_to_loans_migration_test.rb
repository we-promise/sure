# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261008110000_add_collateral_account_to_loans")

# A database can already carry loans.collateral_account_id when this migration
# runs: an installation that built the column from an earlier migration of its
# own records that one, not this version, so this one is still pending there.
# `up` must then leave the column, its index, its foreign key and every loan's
# link exactly as it found them. The schema changes roll back with the test's
# transaction.
class AddCollateralAccountToLoansMigrationTest < ActiveSupport::TestCase
  test "up over an existing collateral link changes nothing and keeps every loan's link" do
    loan = accounts(:loan).loan
    loan.update_column(:collateral_account_id, accounts(:property).id)
    before = snapshot

    assert_nothing_raised { run_up }

    assert_equal before, snapshot
    assert_equal accounts(:property).id, loan.reload.collateral_account_id
  end

  # `down` is the plain reversal, so it doubles as the way to reach a database
  # that never had the column.
  test "down removes the column, and up on a database without it adds it back with its index and foreign key" do
    ActiveRecord::Migration.suppress_messages { AddCollateralAccountToLoans.new.migrate(:down) }
    assert_not connection.column_exists?(:loans, :collateral_account_id), "precondition: the column is gone"

    run_up

    assert connection.column_exists?(:loans, :collateral_account_id, :uuid, null: true)
    assert connection.index_exists?(:loans, :collateral_account_id)
    fk = connection.foreign_keys(:loans).find { |key| key.column == "collateral_account_id" }
    assert_equal "accounts", fk&.to_table
    assert_equal :nullify, fk&.on_delete
  end

  private
    def connection = ActiveRecord::Base.connection

    def run_up
      ActiveRecord::Migration.suppress_messages { AddCollateralAccountToLoans.new.migrate(:up) }
    end

    # The column's shape, its index and foreign key, and every loan's link.
    def snapshot
      column = connection.columns(:loans).find { |c| c.name == "collateral_account_id" }
      {
        column: [ column.sql_type, column.null ],
        indexes: connection.indexes(:loans).select { |i| i.columns == [ "collateral_account_id" ] }.map(&:name),
        foreign_keys: connection.foreign_keys(:loans).select { |k| k.column == "collateral_account_id" }
                                .map { |k| [ k.name, k.to_table, k.on_delete ] },
        links: connection.select_rows("SELECT id, collateral_account_id FROM loans ORDER BY id")
      }
    end
end
