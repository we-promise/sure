class RemoveDuplicateHoldingsIndex < ActiveRecord::Migration[7.2]
  def change
    remove_index :holdings, name: "index_holdings_on_account_and_external_id"
  end
end
