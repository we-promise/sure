class AddCashEquivalentToHoldings < ActiveRecord::Migration[7.2]
  def up
    add_column :holdings, :cash_equivalent, :boolean, default: false, null: false

    say_with_time "Backfilling cash-equivalent holdings from stored provider snapshots" do
      Holding::CashEquivalentBackfill.run.total_holdings
    end
  end

  def down
    remove_column :holdings, :cash_equivalent
  end
end
