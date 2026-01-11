class AddInvestmentActivityLabelToTransactions < ActiveRecord::Migration[7.2]
  def change
    # Label for investment activity type (Buy, Sell, Sweep In, Dividend, etc.)
    # Provides human-readable context for why a transaction is excluded from cashflow
    add_column :transactions, :investment_activity_label, :string
    add_index :transactions, :investment_activity_label
  end
end
