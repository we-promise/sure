require "test_helper"
require Rails.root.join("db/migrate/20261127120000_add_original_quantity_to_holding_lots")

class AddOriginalQuantityToHoldingLotsMigrationTest < ActiveSupport::TestCase
  CONSTRAINT_NAME = AddOriginalQuantityToHoldingLots::CONSTRAINT_NAME

  test "adds original_quantity and original_quantity_as_of columns with a validated non-negative constraint" do
    connection = ActiveRecord::Base.connection

    assert connection.column_exists?(:holding_lots, :original_quantity)
    assert connection.column_exists?(:holding_lots, :original_quantity_as_of)

    constraint = fetch_constraint
    assert_not_nil constraint
    assert constraint["convalidated"], "expected #{CONSTRAINT_NAME} check constraint to be validated"
    assert_match(/original_quantity >= \(?0/, constraint["definition"])
  end

  test "up is idempotent when columns and validated constraint already exist" do
    assert_nothing_raised do
      ActiveRecord::Migration.suppress_messages { AddOriginalQuantityToHoldingLots.new.up }
    end

    assert fetch_constraint["convalidated"]
  end

  test "up validates an existing NOT VALID constraint without recreating it" do
    connection = ActiveRecord::Base.connection
    connection.execute("ALTER TABLE holding_lots DROP CONSTRAINT #{CONSTRAINT_NAME}")
    connection.execute("ALTER TABLE holding_lots ADD CONSTRAINT #{CONSTRAINT_NAME} CHECK (original_quantity >= 0) NOT VALID")

    refute fetch_constraint["convalidated"]

    ActiveRecord::Migration.suppress_messages { AddOriginalQuantityToHoldingLots.new.up }

    assert fetch_constraint["convalidated"]
  end

  test "down removes columns and constraint and up restores them cleanly" do
    connection = ActiveRecord::Base.connection

    ActiveRecord::Migration.suppress_messages { AddOriginalQuantityToHoldingLots.new.down }

    refute connection.column_exists?(:holding_lots, :original_quantity)
    refute connection.column_exists?(:holding_lots, :original_quantity_as_of)
    assert_nil fetch_constraint

    ActiveRecord::Migration.suppress_messages { AddOriginalQuantityToHoldingLots.new.up }

    assert connection.column_exists?(:holding_lots, :original_quantity)
    assert connection.column_exists?(:holding_lots, :original_quantity_as_of)
    assert fetch_constraint["convalidated"]
  end

  private
    def fetch_constraint
      ActiveRecord::Base.connection.select_one(<<~SQL.squish)
        SELECT c.convalidated, pg_get_constraintdef(c.oid) AS definition
        FROM pg_constraint c
        JOIN pg_class t ON t.oid = c.conrelid
        WHERE t.relname = 'holding_lots'
          AND c.conname = #{ActiveRecord::Base.connection.quote(CONSTRAINT_NAME)}
      SQL
    end
end
