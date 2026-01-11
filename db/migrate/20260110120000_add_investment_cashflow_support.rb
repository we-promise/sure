class AddInvestmentCashflowSupport < ActiveRecord::Migration[7.2]
  def change
    # Flag for excluding from cashflow (user-controllable)
    # Used for internal investment activity like fund swaps
    add_column :entries, :exclude_from_cashflow, :boolean, default: false, null: false
    add_index :entries, :exclude_from_cashflow

    # Holdings snapshot for comparison (provider-agnostic)
    # Used to detect internal investment activity by comparing holdings between syncs
    add_column :accounts, :holdings_snapshot_data, :jsonb
    add_column :accounts, :holdings_snapshot_at, :datetime
  end
end
