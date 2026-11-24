require "test_helper"
require Rails.root.join("db/migrate/20261014120000_add_cash_entry_total_to_valuations")

class AddCashEntryTotalToValuationsMigrationTest < ActiveSupport::TestCase
  test "refuses to roll back a baseline column that already exists" do
    valuation = Valuation.create!(kind: :cash_anchor, cash_entry_total: 25)
    migration = AddCashEntryTotalToValuations.new
    ActiveRecord::Migration.suppress_messages { migration.up }
    assert_raises(ActiveRecord::IrreversibleMigration) { migration.down }
    assert_equal 25, valuation.reload.cash_entry_total
  end
end
