class AddInvestmentActivityLabelToTrades < ActiveRecord::Migration[7.2]
  def change
    # Add activity label to trades (matching Transaction)
    add_column :trades, :investment_activity_label, :string
    add_index :trades, :investment_activity_label

    # Backfill existing trades with basic labels based on quantity
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE trades
          SET investment_activity_label = CASE
            WHEN qty > 0 THEN 'Buy'
            WHEN qty < 0 THEN 'Sell'
            ELSE 'Other'
          END
          WHERE investment_activity_label IS NULL
        SQL
      end
    end
  end
end
